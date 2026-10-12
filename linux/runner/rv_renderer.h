// SPDX-License-Identifier: GPL-3.0-or-later
//
// OpenGL renderer glue between the Flutter engine (raster thread) and GTK
// (main thread).  Flutter renders into pooled FBOs owned by a GdkGLContext
// that is shared with the display; finished frames are handed to the main
// thread as GdkGLTextures.
#pragma once

#include <gtk/gtk.h>

#include "engine/flutter_embedder.h"

G_BEGIN_DECLS

typedef struct _RvRenderer RvRenderer;
typedef void (*RvFrameFn)(gpointer user_data);

RvRenderer* rv_renderer_new(GdkDisplay* display, GError** error);
void rv_renderer_free(RvRenderer* r);
void rv_renderer_fill_config(RvRenderer* r, FlutterRendererConfig* config);
// Called on the main thread (idle) whenever a new frame is pending.
void rv_renderer_set_frame_fn(RvRenderer* r, RvFrameFn fn, gpointer user_data);
// Main thread: returns the newest frame as a texture (full ref) or NULL.
GdkTexture* rv_renderer_take_frame(RvRenderer* r);

G_END_DECLS
