// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_app.h"

#include <glib-unix.h>
#include <signal.h>
#include <string.h>

#include "rv_a11y.h"
#include "rv_engine.h"
#include "rv_overlay.h"
#include "rv_platform.h"
#include "rv_textinput.h"
#include "rv_view.h"

#ifndef APPLICATION_ID
#define APPLICATION_ID "io.github.luohoa97.RambleVoice"
#endif

#define kDefaultWidth 1100
#define kDefaultHeight 760
#define kMinWidth 420
#define kMinHeight 560

static GtkApplication* g_app;
static GtkWidget* g_window;
static RvEngine* g_engine;
static gboolean g_close_to_background = TRUE;
static gboolean g_cli_ready;
static gboolean g_frame_seen;
static GQueue g_pending = G_QUEUE_INIT;  // of char* commands for Dart

static gboolean g_opt_toggle, g_opt_start, g_opt_stop, g_opt_show, g_opt_background;

// ------------------------------------------------------------ CLI -> Dart

static void flush_commands(void) {
  if (!g_cli_ready || !rv_engine_is_running(g_engine)) return;
  char* cmd;
  while ((cmd = g_queue_pop_head(&g_pending))) {
    rv_engine_send(g_engine, "ramble/cli", rv_std_method_call("command", rv_str(cmd)), NULL, NULL);
    g_free(cmd);
  }
}

static void queue_command(const char* cmd) {
  g_queue_push_tail(&g_pending, g_strdup(cmd));
  flush_commands();
}

void rv_app_notify_frame(void) {
  if (g_frame_seen) return;
  g_frame_seen = TRUE;
  // Dart's main() has built a frame: its ramble/cli handler is (almost
  // certainly) installed.  A `ready` call from Dart flushes earlier.
  g_cli_ready = TRUE;
  flush_commands();
}

// ------------------------------------------------------------------ window

static void window_show(void) {
  if (!g_window) return;
  gtk_window_present(GTK_WINDOW(g_window));
}

static void window_hide(void) {
  if (g_window) gtk_widget_set_visible(g_window, FALSE);
}

void rv_app_quit(void) {
  if (g_app) g_application_quit(G_APPLICATION(g_app));
}

void rv_app_navigator_pop(void) {
  if (g_close_to_background) window_hide();
  else rv_app_quit();
}

void rv_app_set_title(const char* title) {
  if (g_window && title && *title) gtk_window_set_title(GTK_WINDOW(g_window), title);
}

static gboolean close_request_cb(GtkWindow* w, gpointer d) {
  (void)w;
  (void)d;
  if (g_close_to_background) {
    window_hide();
    return TRUE;
  }
  rv_app_quit();
  return TRUE;
}

static void create_window(GtkApplication* app) {
  g_window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(g_window), "Ramble Voice");
  gtk_window_set_default_size(GTK_WINDOW(g_window), kDefaultWidth, kDefaultHeight);
  gtk_window_set_icon_name(GTK_WINDOW(g_window), APPLICATION_ID);
  GtkWidget* view = rv_view_new(g_engine);
  gtk_widget_set_size_request(view, kMinWidth, kMinHeight);
  gtk_window_set_child(GTK_WINDOW(g_window), view);
  g_signal_connect(g_window, "close-request", G_CALLBACK(close_request_cb), NULL);
}

// ---------------------------------------------------------------- channels

static void window_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_std_decode_call(msg, &method, &args)) {
    rv_engine_respond_empty(e, h);
    return;
  }
  GVariant* result = NULL;
  if (!strcmp(method, "show") || !strcmp(method, "present")) {
    window_show();
  } else if (!strcmp(method, "hide")) {
    window_hide();
  } else if (!strcmp(method, "quit")) {
    rv_engine_respond(e, h, rv_std_success(NULL));
    rv_app_quit();
    return;
  } else if (!strcmp(method, "isVisible")) {
    result = rv_bool(g_window && gtk_widget_get_visible(g_window));
  } else if (!strcmp(method, "setCloseToBackground")) {
    g_close_to_background = rv_as_bool(args, TRUE);
  } else if (!strcmp(method, "setTitle")) {
    rv_app_set_title(rv_as_str(args, NULL));
  } else {
    rv_engine_respond_empty(e, h);
    return;
  }
  rv_engine_respond(e, h, rv_std_success(result));
}

static void overlay_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_std_decode_call(msg, &method, &args) || strcmp(method, "setState") != 0) {
    rv_engine_respond_empty(e, h);
    return;
  }
  const char* st = rv_map_str(args, "state", "idle");
  RvOverlayState state = RV_OVERLAY_IDLE;
  if (!strcmp(st, "listening")) state = RV_OVERLAY_LISTENING;
  else if (!strcmp(st, "processing")) state = RV_OVERLAY_PROCESSING;
  else if (!strcmp(st, "error")) state = RV_OVERLAY_ERROR;
  double level = rv_map_double(args, "level", 0);
  const char* text = rv_map_str(args, "text", NULL);
  gboolean ok = rv_overlay_set_state(state, level, text);
  rv_engine_respond(e, h, rv_std_success(rv_bool(ok)));
}

static void cli_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_std_decode_call(msg, &method, &args)) {
    rv_engine_respond_empty(e, h);
    return;
  }
  if (!strcmp(method, "ready")) {
    g_cli_ready = TRUE;
    flush_commands();
    rv_engine_respond(e, h, rv_std_success(NULL));
  } else {
    rv_engine_respond_empty(e, h);
  }
}

// Debug aid: RV_DEBUG_SCREENSHOT=/path.png saves the window contents after
// RV_DEBUG_SCREENSHOT_DELAY seconds (default 4) then keeps running.
static gboolean debug_screenshot_cb(gpointer path) {
  GtkWidget* w = g_window;
  GtkNative* native = w ? gtk_widget_get_native(w) : NULL;
  GskRenderer* renderer = native ? gtk_native_get_renderer(native) : NULL;
  if (!renderer) return G_SOURCE_REMOVE;
  GdkPaintable* p = gtk_widget_paintable_new(w);
  GtkSnapshot* snap = gtk_snapshot_new();
  gdk_paintable_snapshot(p, snap, gtk_widget_get_width(w), gtk_widget_get_height(w));
  GskRenderNode* node = gtk_snapshot_free_to_node(snap);
  if (node) {
    GdkTexture* tex = gsk_renderer_render_texture(renderer, node, NULL);
    gdk_texture_save_to_png(tex, path);
    g_object_unref(tex);
    gsk_render_node_unref(node);
    g_printerr("ramble_voice: screenshot saved to %s\n", (char*)path);
  }
  g_object_unref(p);
  return G_SOURCE_REMOVE;
}

// ------------------------------------------------------------ app signals

static gboolean on_signal(gpointer d) {
  (void)d;
  rv_app_quit();
  return G_SOURCE_REMOVE;
}

static void on_startup(GApplication* app, gpointer d) {
  (void)d;
  g_application_hold(app);  // keep running with the window hidden
  g_close_to_background = !g_getenv("RAMBLE_QUIT_ON_CLOSE");
  g_unix_signal_add(SIGINT, on_signal, NULL);
  g_unix_signal_add(SIGTERM, on_signal, NULL);

  g_engine = rv_engine_new();
  rv_platform_init(g_engine);
  rv_textinput_init(g_engine);
  rv_a11y_init(g_engine);
  rv_engine_add_handler(g_engine, "ramble/window", window_message, NULL);
  rv_engine_add_handler(g_engine, "ramble/overlay", overlay_message, NULL);
  rv_engine_add_handler(g_engine, "ramble/cli", cli_message, NULL);

  g_autoptr(GError) error = NULL;
  if (!rv_engine_run(g_engine, &error)) {
    g_printerr("ramble_voice: cannot start the Flutter engine: %s\n", error->message);
    exit(1);
  }
  create_window(GTK_APPLICATION(app));
  const char* shot = g_getenv("RV_DEBUG_SCREENSHOT");
  if (shot) {
    const char* delay = g_getenv("RV_DEBUG_SCREENSHOT_DELAY");
    g_timeout_add_seconds(delay ? atoi(delay) : 4, debug_screenshot_cb, g_strdup(shot));
  }

  // Metrics for the hidden window so Dart can lay out and run in the background.
  double scale = 1.0;
  GListModel* mons = gdk_display_get_monitors(gdk_display_get_default());
  GdkMonitor* mon = g_list_model_get_n_items(mons) ? g_list_model_get_item(mons, 0) : NULL;
  if (mon) {
    scale = gdk_monitor_get_scale(mon);
    rv_engine_send_display(g_engine, gdk_monitor_get_refresh_rate(mon) / 1000.0, 0, 0, scale);
    g_object_unref(mon);
  }
  rv_engine_send_metrics(g_engine, (size_t)(kDefaultWidth * scale), (size_t)(kDefaultHeight * scale), scale);
  rv_platform_engine_started();
  rv_a11y_engine_started();
}

static void on_shutdown(GApplication* app, gpointer d) {
  (void)app;
  (void)d;
  rv_overlay_destroy();
  rv_engine_shutdown(g_engine);
}

static int on_command_line(GApplication* app, GApplicationCommandLine* cl, gpointer d) {
  (void)d;
  GVariantDict* opts = g_application_command_line_get_options_dict(cl);
  gboolean toggle = g_variant_dict_contains(opts, "toggle");
  gboolean start = g_variant_dict_contains(opts, "start");
  gboolean stop = g_variant_dict_contains(opts, "stop");
  gboolean show = g_variant_dict_contains(opts, "show");
  gboolean background = g_variant_dict_contains(opts, "background");
  gboolean primary_launch = !g_application_command_line_get_is_remote(cl);

  if (toggle) queue_command("toggle");
  if (start) queue_command("start");
  if (stop) queue_command("stop");
  if (show) {
    window_show();
    queue_command("show");
  }
  if (primary_launch) {
    // A fresh launch shows the window unless asked not to or driven by a
    // dictation command (hotkey bindings start us hidden in the background).
    if (!background && !toggle && !start && !stop) window_show();
  } else if (!toggle && !start && !stop && !show) {
    window_show();  // plain re-launch: bring the app up
  }
  (void)app;
  return 0;
}

GtkApplication* rv_app_new(void) {
  g_app = gtk_application_new(APPLICATION_ID, G_APPLICATION_HANDLES_COMMAND_LINE);
  const GOptionEntry entries[] = {
      {"toggle", 0, 0, G_OPTION_ARG_NONE, &g_opt_toggle, "Toggle dictation", NULL},
      {"start", 0, 0, G_OPTION_ARG_NONE, &g_opt_start, "Start dictation", NULL},
      {"stop", 0, 0, G_OPTION_ARG_NONE, &g_opt_stop, "Stop dictation", NULL},
      {"show", 0, 0, G_OPTION_ARG_NONE, &g_opt_show, "Show the main window", NULL},
      {"background", 0, 0, G_OPTION_ARG_NONE, &g_opt_background, "Start hidden in the background", NULL},
      {NULL},
  };
  g_application_add_main_option_entries(G_APPLICATION(g_app), entries);
  g_signal_connect(g_app, "startup", G_CALLBACK(on_startup), NULL);
  g_signal_connect(g_app, "shutdown", G_CALLBACK(on_shutdown), NULL);
  g_signal_connect(g_app, "command-line", G_CALLBACK(on_command_line), NULL);
  return g_app;
}
