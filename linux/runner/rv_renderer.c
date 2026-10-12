// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_renderer.h"

#include <dlfcn.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>

typedef struct {
  guint tex;
  guint fbo;
  int width, height;
  gboolean busy;  // referenced by Flutter, a pending slot or a GdkTexture
} Buf;

static struct _RvRenderer* g_renderer;  // engine callbacks carry the engine as user data

struct _RvRenderer {
  GdkGLContext* render_ctx;    // current on the raster thread only
  GdkGLContext* resource_ctx;  // current on the engine's resource thread only
  GdkGLContext* texture_ctx;   // context GdkGLTextures are tagged with
  GMutex lock;
  GPtrArray* bufs;
  Buf* back;           // being rendered by Flutter
  Buf* pending;        // finished, waiting for the main thread
  GLsync pending_sync;
  RvFrameFn frame_fn;
  gpointer frame_data;
  gboolean idle_queued;
};

static GdkGLContext* make_context(GdkDisplay* display, GError** error) {
  GdkGLContext* ctx = gdk_display_create_gl_context(display, error);
  if (!ctx) return NULL;
  // The engine's GL backend targets OpenGL ES. On a desktop GL core profile
  // its single-channel glyph atlas formats differ, which garbles all text, so
  // ask GDK for GLES (falls back to desktop GL only if GLES is unavailable).
  const char* api = g_getenv("RAMBLE_GL_API");
  if (!api || g_strcmp0(api, "gl") != 0) {
    gdk_gl_context_set_allowed_apis(ctx, GDK_GL_API_GLES);
  }
  if (!gdk_gl_context_realize(ctx, error)) {
    g_object_unref(ctx);
    return NULL;
  }
  gdk_gl_context_clear_current();
  return ctx;
}

RvRenderer* rv_renderer_new(GdkDisplay* display, GError** error) {
  RvRenderer* r = g_new0(RvRenderer, 1);
  g_renderer = r;
  g_mutex_init(&r->lock);
  r->bufs = g_ptr_array_new();
  r->render_ctx = make_context(display, error);
  if (r->render_ctx) r->resource_ctx = make_context(display, error);
  if (r->resource_ctx) r->texture_ctx = make_context(display, error);
  if (!r->texture_ctx) {
    rv_renderer_free(r);
    return NULL;
  }
  return r;
}

static void destroy_buf(Buf* b) {
  if (b->fbo) glDeleteFramebuffers(1, &b->fbo);
  if (b->tex) glDeleteTextures(1, &b->tex);
  g_free(b);
}

void rv_renderer_free(RvRenderer* r) {
  if (!r) return;
  if (r->render_ctx) {
    gdk_gl_context_make_current(r->render_ctx);
    if (r->pending_sync) glDeleteSync(r->pending_sync);
    for (guint i = 0; i < r->bufs->len; i++) destroy_buf(g_ptr_array_index(r->bufs, i));
    gdk_gl_context_clear_current();
  }
  g_ptr_array_free(r->bufs, TRUE);
  g_clear_object(&r->render_ctx);
  g_clear_object(&r->resource_ctx);
  g_clear_object(&r->texture_ctx);
  g_mutex_clear(&r->lock);
  if (g_renderer == r) g_renderer = NULL;
  g_free(r);
}

// ------------------------------------------------------- engine callbacks

static bool make_current(void* data) {
  RvRenderer* r = g_renderer;
  gdk_gl_context_make_current(r->render_ctx);
  return gdk_gl_context_get_current() == r->render_ctx;
}

static bool clear_current(void* data) {
  (void)data;
  gdk_gl_context_clear_current();
  return true;
}

static bool make_resource_current(void* data) {
  RvRenderer* r = g_renderer;
  gdk_gl_context_make_current(r->resource_ctx);
  return gdk_gl_context_get_current() == r->resource_ctx;
}

static Buf* acquire_buf(RvRenderer* r, int w, int h) {
  g_mutex_lock(&r->lock);
  Buf* found = NULL;
  for (guint i = 0; i < r->bufs->len;) {
    Buf* b = g_ptr_array_index(r->bufs, i);
    if (!b->busy && (b->width != w || b->height != h)) {
      g_ptr_array_remove_index_fast(r->bufs, i);
      destroy_buf(b);  // stale size (GL context is current on this thread)
      continue;
    }
    if (!b->busy && !found) found = b;
    i++;
  }
  if (!found) {
    found = g_new0(Buf, 1);
    found->width = w;
    found->height = h;
    glGenTextures(1, &found->tex);
    glBindTexture(GL_TEXTURE_2D, found->tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &found->fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, found->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, found->tex, 0);
    g_ptr_array_add(r->bufs, found);
  }
  found->busy = TRUE;
  g_mutex_unlock(&r->lock);
  return found;
}

static uint32_t fbo_with_frame_info(void* data, const FlutterFrameInfo* info) {
  RvRenderer* r = g_renderer;
  int w = MAX(1, (int)info->size.width), h = MAX(1, (int)info->size.height);
  if (r->back && r->back->width == w && r->back->height == h) return r->back->fbo;
  if (r->back) {  // size changed before present: drop the unused buffer
    g_mutex_lock(&r->lock);
    r->back->busy = FALSE;
    g_mutex_unlock(&r->lock);
  }
  r->back = acquire_buf(r, w, h);
  return r->back->fbo;
}

static gboolean frame_idle_cb(gpointer data) {
  RvRenderer* r = data;
  g_mutex_lock(&r->lock);
  r->idle_queued = FALSE;
  g_mutex_unlock(&r->lock);
  if (r->frame_fn) r->frame_fn(r->frame_data);
  return G_SOURCE_REMOVE;
}

static bool present_with_info(void* data, const FlutterPresentInfo* info) {
  (void)info;
  RvRenderer* r = g_renderer;
  if (!r->back) return false;
  GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  glFlush();

  g_mutex_lock(&r->lock);
  if (r->pending) {  // superseded before the main thread picked it up
    r->pending->busy = FALSE;
    if (r->pending_sync) glDeleteSync(r->pending_sync);
  }
  r->pending = r->back;
  r->pending_sync = sync;
  r->back = NULL;
  gboolean queue = !r->idle_queued;
  r->idle_queued = TRUE;
  g_mutex_unlock(&r->lock);
  if (queue) g_idle_add_full(G_PRIORITY_HIGH_IDLE, frame_idle_cb, r, NULL);
  return true;
}

static void* gl_proc_resolver(void* data, const char* name) {
  (void)data;
  void* p = (void*)eglGetProcAddress(name);
  // libepoxy exports the GL entry points itself (valid for GL, GLES and GLX).
  return p ? p : dlsym(RTLD_DEFAULT, name);
}

void rv_renderer_fill_config(RvRenderer* r, FlutterRendererConfig* config) {
  (void)r;
  config->type = kOpenGL;
  FlutterOpenGLRendererConfig* gl = &config->open_gl;
  gl->struct_size = sizeof(*gl);
  gl->make_current = make_current;
  gl->clear_current = clear_current;
  gl->make_resource_current = make_resource_current;
  gl->fbo_with_frame_info_callback = fbo_with_frame_info;
  gl->present_with_info = present_with_info;
  gl->gl_proc_resolver = gl_proc_resolver;
  gl->fbo_reset_after_present = true;
}

// ------------------------------------------------------------ main thread

void rv_renderer_set_frame_fn(RvRenderer* r, RvFrameFn fn, gpointer user_data) {
  r->frame_fn = fn;
  r->frame_data = user_data;
}

typedef struct {
  RvRenderer* r;
  Buf* buf;
} TexRef;

static void texture_released(gpointer data) {
  TexRef* t = data;
  g_mutex_lock(&t->r->lock);
  t->buf->busy = FALSE;
  g_mutex_unlock(&t->r->lock);
  g_free(t);
}

GdkTexture* rv_renderer_take_frame(RvRenderer* r) {
  g_mutex_lock(&r->lock);
  Buf* b = r->pending;
  GLsync sync = r->pending_sync;
  r->pending = NULL;
  r->pending_sync = NULL;
  g_mutex_unlock(&r->lock);
  if (!b) return NULL;

  GdkGLTextureBuilder* builder = gdk_gl_texture_builder_new();
  gdk_gl_texture_builder_set_context(builder, r->texture_ctx);
  gdk_gl_texture_builder_set_id(builder, b->tex);
  gdk_gl_texture_builder_set_width(builder, b->width);
  gdk_gl_texture_builder_set_height(builder, b->height);
  gdk_gl_texture_builder_set_format(builder, GDK_MEMORY_R8G8B8A8_PREMULTIPLIED);
  gdk_gl_texture_builder_set_sync(builder, sync);
  TexRef* t = g_new0(TexRef, 1);
  t->r = r;
  t->buf = b;
  GdkTexture* tex = gdk_gl_texture_builder_build(builder, texture_released, t);
  g_object_unref(builder);
  return tex;
}
