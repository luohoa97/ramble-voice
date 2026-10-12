// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_engine.h"

#include <pthread.h>
#include <string.h>

typedef struct {
  RvMessageFn fn;
  gpointer data;
} Handler;

struct _RvEngine {
  FlutterEngine engine;
  FlutterEngineAOTData aot;
  RvRenderer* renderer;
  GHashTable* handlers;  // channel -> Handler*
  pthread_t main_thread;
  gboolean running;
  RvSemanticsFn semantics_fn;
  gpointer semantics_data;
  char* assets_path;
  char* icu_path;
  char* aot_path;
};

static RvEngine* g_engine;

RvEngine* rv_engine_get(void) { return g_engine; }
FlutterEngine rv_engine_raw(RvEngine* e) { return e->engine; }
RvRenderer* rv_engine_renderer(RvEngine* e) { return e->renderer; }
gboolean rv_engine_is_running(RvEngine* e) { return e && e->running; }
guint64 rv_engine_now_us(void) { return FlutterEngineGetCurrentTime() / 1000; }

RvEngine* rv_engine_new(void) {
  RvEngine* e = g_new0(RvEngine, 1);
  e->handlers = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
  e->main_thread = pthread_self();
  g_engine = e;
  return e;
}

void rv_engine_add_handler(RvEngine* e, const char* channel, RvMessageFn fn, gpointer user_data) {
  Handler* h = g_new0(Handler, 1);
  h->fn = fn;
  h->data = user_data;
  g_hash_table_replace(e->handlers, g_strdup(channel), h);
}

// ------------------------------------------------------------ task runner

typedef struct {
  RvEngine* engine;
  FlutterTask task;
} TaskData;

static gboolean run_task_cb(gpointer data) {
  TaskData* t = data;
  if (t->engine->engine) FlutterEngineRunTask(t->engine->engine, &t->task);
  g_free(t);
  return G_SOURCE_REMOVE;
}

static bool runs_task_on_current_thread(void* user_data) {
  RvEngine* e = user_data;
  return pthread_equal(pthread_self(), e->main_thread);
}

static void post_task(FlutterTask task, uint64_t target_time_nanos, void* user_data) {
  RvEngine* e = user_data;
  TaskData* t = g_new0(TaskData, 1);
  t->engine = e;
  t->task = task;
  uint64_t now = FlutterEngineGetCurrentTime();
  gint64 delay_us = target_time_nanos > now ? (gint64)((target_time_nanos - now) / 1000) : 0;
  GSource* s = g_timeout_source_new(0);
  g_source_set_priority(s, G_PRIORITY_DEFAULT);
  g_source_set_callback(s, run_task_cb, t, NULL);
  g_source_set_ready_time(s, delay_us ? g_get_monotonic_time() + delay_us : 0);
  g_source_attach(s, NULL);
  g_source_unref(s);
}

// ------------------------------------------------------ platform messages

typedef struct {
  RvEngine* engine;
  char* channel;
  GBytes* message;
  const FlutterPlatformMessageResponseHandle* handle;
} MessageData;

static gboolean dispatch_message_cb(gpointer data) {
  MessageData* m = data;
  Handler* h = g_hash_table_lookup(m->engine->handlers, m->channel);
  if (h)
    h->fn(m->engine, m->message, m->handle, h->data);
  else
    rv_engine_respond_empty(m->engine, m->handle);
  g_bytes_unref(m->message);
  g_free(m->channel);
  g_free(m);
  return G_SOURCE_REMOVE;
}

static void platform_message_cb(const FlutterPlatformMessage* msg, void* user_data) {
  RvEngine* e = user_data;
  MessageData* m = g_new0(MessageData, 1);
  m->engine = e;
  m->channel = g_strdup(msg->channel);
  m->message = g_bytes_new(msg->message, msg->message_size);
  m->handle = msg->response_handle;
  if (pthread_equal(pthread_self(), e->main_thread))
    dispatch_message_cb(m);
  else
    g_idle_add(dispatch_message_cb, m);
}

void rv_engine_respond(RvEngine* e, const FlutterPlatformMessageResponseHandle* handle, GBytes* reply) {
  if (!handle) return;
  if (reply) {
    gsize len;
    const guint8* d = g_bytes_get_data(reply, &len);
    FlutterEngineSendPlatformMessageResponse(e->engine, handle, d, len);
    g_bytes_unref(reply);
  } else {
    FlutterEngineSendPlatformMessageResponse(e->engine, handle, NULL, 0);
  }
}

void rv_engine_respond_empty(RvEngine* e, const FlutterPlatformMessageResponseHandle* handle) {
  rv_engine_respond(e, handle, NULL);
}

typedef struct {
  RvReplyFn cb;
  gpointer data;
} ReplyData;

typedef struct {
  ReplyData* r;
  GBytes* bytes;
} ReplyDispatch;

static gboolean reply_idle_cb(gpointer data) {
  ReplyDispatch* d = data;
  if (d->r->cb) d->r->cb(d->bytes, d->r->data);
  if (d->bytes) g_bytes_unref(d->bytes);
  g_free(d->r);
  g_free(d);
  return G_SOURCE_REMOVE;
}

static void reply_cb(const uint8_t* data, size_t size, void* user_data) {
  ReplyDispatch* d = g_new0(ReplyDispatch, 1);
  d->r = user_data;
  d->bytes = size ? g_bytes_new(data, size) : NULL;
  g_idle_add(reply_idle_cb, d);
}

void rv_engine_send(RvEngine* e, const char* channel, GBytes* message, RvReplyFn cb, gpointer user_data) {
  if (!e || !e->running) {
    if (message) g_bytes_unref(message);
    return;
  }
  FlutterPlatformMessage msg = {0};
  msg.struct_size = sizeof msg;
  msg.channel = channel;
  gsize len = 0;
  msg.message = message ? g_bytes_get_data(message, &len) : NULL;
  msg.message_size = len;
  FlutterPlatformMessageResponseHandle* handle = NULL;
  if (cb) {
    ReplyData* r = g_new0(ReplyData, 1);
    r->cb = cb;
    r->data = user_data;
    FlutterPlatformMessageCreateResponseHandle(e->engine, reply_cb, r, &handle);
  }
  msg.response_handle = handle;
  FlutterEngineSendPlatformMessage(e->engine, &msg);
  if (handle) FlutterPlatformMessageReleaseResponseHandle(e->engine, handle);
  if (message) g_bytes_unref(message);
}

// --------------------------------------------------------------- semantics

void rv_engine_set_semantics_fn(RvEngine* e, RvSemanticsFn fn, gpointer user_data) {
  e->semantics_fn = fn;
  e->semantics_data = user_data;
}

static void semantics_cb(const FlutterSemanticsUpdate2* update, void* user_data) {
  RvEngine* e = user_data;
  if (e->semantics_fn) e->semantics_fn(update, e->semantics_data);
}

// ----------------------------------------------------------------- metrics

void rv_engine_send_metrics(RvEngine* e, size_t width_px, size_t height_px, double pixel_ratio) {
  if (!e || !e->running) return;
  FlutterWindowMetricsEvent ev = {0};
  ev.struct_size = sizeof ev;
  ev.width = width_px;
  ev.height = height_px;
  ev.pixel_ratio = pixel_ratio;
  ev.view_id = 0;
  FlutterEngineSendWindowMetricsEvent(e->engine, &ev);
}

void rv_engine_send_display(RvEngine* e, double refresh_hz, size_t width_px, size_t height_px, double pixel_ratio) {
  if (!e || !e->running) return;
  FlutterEngineDisplay d = {0};
  d.struct_size = sizeof d;
  d.display_id = 0;
  d.single_display = true;
  d.refresh_rate = refresh_hz > 1 ? refresh_hz : 60.0;
  d.width = width_px;
  d.height = height_px;
  d.device_pixel_ratio = pixel_ratio;
  FlutterEngineNotifyDisplayUpdate(e->engine, kFlutterEngineDisplaysUpdateTypeStartup, &d, 1);
}

void rv_engine_update_locales(RvEngine* e) {
  if (!e || !e->running) return;
  const char* const* names = g_get_language_names();
  GPtrArray* strings = g_ptr_array_new_with_free_func(g_free);  // owns all text
  GArray* locales = g_array_new(FALSE, TRUE, sizeof(FlutterLocale));
  g_autoptr(GHashTable) seen = g_hash_table_new(g_str_hash, g_str_equal);
  for (int i = 0; names[i]; i++) {
    if (!strcmp(names[i], "C") || !strcmp(names[i], "POSIX")) continue;
    char* tmp = g_strdup(names[i]);
    char* at = strchr(tmp, '@');
    if (at) *at = 0;
    char* dot = strchr(tmp, '.');
    if (dot) *dot = 0;
    char* country = NULL;
    char* us = strchr(tmp, '_');
    if (us) {
      *us = 0;
      country = us + 1;
    }
    char* key = g_strdup_printf("%s_%s", tmp, country ? country : "");
    if (!*tmp || g_hash_table_contains(seen, key)) {
      g_free(key);
      g_free(tmp);
      continue;
    }
    g_ptr_array_add(strings, key);
    g_hash_table_add(seen, key);
    FlutterLocale loc = {0};
    loc.struct_size = sizeof loc;
    loc.language_code = g_strdup(tmp);
    g_ptr_array_add(strings, (gpointer)loc.language_code);
    if (country && *country) {
      loc.country_code = g_strdup(country);
      g_ptr_array_add(strings, (gpointer)loc.country_code);
    }
    g_array_append_val(locales, loc);
    g_free(tmp);
  }
  if (locales->len == 0) {
    FlutterLocale loc = {0};
    loc.struct_size = sizeof loc;
    loc.language_code = "en";
    loc.country_code = "US";
    g_array_append_val(locales, loc);
  }
  const FlutterLocale** arr = g_new0(const FlutterLocale*, locales->len);
  for (guint i = 0; i < locales->len; i++) arr[i] = &g_array_index(locales, FlutterLocale, i);
  FlutterEngineUpdateLocales(e->engine, arr, locales->len);
  g_free(arr);
  g_array_free(locales, TRUE);
  g_ptr_array_free(strings, TRUE);
}

// --------------------------------------------------------------------- run

static char* exe_dir(void) {
  g_autofree char* exe = g_file_read_link("/proc/self/exe", NULL);
  return exe ? g_path_get_dirname(exe) : g_strdup(".");
}

// `flutter run` passes engine switches through the environment.
static char** collect_switches(int* argc) {
  GPtrArray* a = g_ptr_array_new();
  g_ptr_array_add(a, g_strdup("ramble_voice"));
  const char* count = g_getenv("FLUTTER_ENGINE_SWITCHES");
  int n = count ? atoi(count) : 0;
  for (int i = 1; i <= n; i++) {
    g_autofree char* name = g_strdup_printf("FLUTTER_ENGINE_SWITCH_%d", i);
    const char* v = g_getenv(name);
    if (v) g_ptr_array_add(a, g_strdup_printf("--%s", v));
  }
  *argc = a->len;
  g_ptr_array_add(a, NULL);
  return (char**)g_ptr_array_free(a, FALSE);
}

gboolean rv_engine_run(RvEngine* e, GError** error) {
  g_autofree char* dir = exe_dir();
  e->assets_path = g_build_filename(dir, "data", "flutter_assets", NULL);
  e->icu_path = g_build_filename(dir, "data", "icudtl.dat", NULL);
  e->aot_path = g_build_filename(dir, "lib", "libapp.so", NULL);

  e->renderer = rv_renderer_new(gdk_display_get_default(), error);
  if (!e->renderer) return FALSE;

  FlutterRendererConfig config = {0};
  rv_renderer_fill_config(e->renderer, &config);

  FlutterTaskRunnerDescription platform_runner = {0};
  platform_runner.struct_size = sizeof platform_runner;
  platform_runner.user_data = e;
  platform_runner.runs_task_on_current_thread_callback = runs_task_on_current_thread;
  platform_runner.post_task_callback = post_task;
  platform_runner.identifier = 1;
  FlutterCustomTaskRunners runners = {0};
  runners.struct_size = sizeof runners;
  runners.platform_task_runner = &platform_runner;

  int argc;
  char** argv = collect_switches(&argc);

  FlutterProjectArgs args = {0};
  args.struct_size = sizeof args;
  args.assets_path = e->assets_path;
  args.icu_data_path = e->icu_path;
  args.command_line_argc = argc;
  args.command_line_argv = (const char* const*)argv;
  args.platform_message_callback = platform_message_cb;
  args.custom_task_runners = &runners;
  args.update_semantics_callback2 = semantics_cb;
  args.log_tag = "flutter";

  if (FlutterEngineRunsAOTCompiledDartCode()) {
    FlutterEngineAOTDataSource src = {0};
    src.type = kFlutterEngineAOTDataSourceTypeElfPath;
    src.elf_path = e->aot_path;
    if (FlutterEngineCreateAOTData(&src, &e->aot) != kSuccess) {
      g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "cannot load AOT snapshot %s", e->aot_path);
      g_strfreev(argv);
      return FALSE;
    }
    args.aot_data = e->aot;
  }

  // The handlers may fire before Run returns; mark running first.
  e->running = TRUE;
  FlutterEngineResult r = FlutterEngineRun(FLUTTER_ENGINE_VERSION, &config, &args, e, &e->engine);
  g_strfreev(argv);
  if (r != kSuccess) {
    e->running = FALSE;
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "FlutterEngineRun failed (%d)", r);
    return FALSE;
  }
  rv_engine_update_locales(e);
  return TRUE;
}

void rv_engine_shutdown(RvEngine* e) {
  if (!e || !e->engine) return;
  e->running = FALSE;
  FlutterEngineShutdown(e->engine);
  e->engine = NULL;
  if (e->aot) FlutterEngineCollectAOTData(e->aot);
  rv_renderer_free(e->renderer);
  e->renderer = NULL;
}
