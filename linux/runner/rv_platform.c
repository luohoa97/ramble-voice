// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_platform.h"

#include <string.h>

#include "rv_app.h"
#include "rv_view.h"

static RvEngine* g_engine;
static RvLifecycle g_lifecycle = RV_LIFECYCLE_HIDDEN;
static RvLifecycle g_sent_lifecycle = (RvLifecycle)-1;

// -------------------------------------------------------------- lifecycle

static void flush_lifecycle(void) {
  if (!rv_engine_is_running(g_engine) || g_sent_lifecycle == g_lifecycle) return;
  g_sent_lifecycle = g_lifecycle;
  const char* s = g_lifecycle == RV_LIFECYCLE_RESUMED   ? "AppLifecycleState.resumed"
                  : g_lifecycle == RV_LIFECYCLE_INACTIVE ? "AppLifecycleState.inactive"
                                                         : "AppLifecycleState.hidden";
  rv_engine_send(g_engine, "flutter/lifecycle", rv_string_bytes(s), NULL, NULL);
}

void rv_platform_set_lifecycle(RvLifecycle state) {
  g_lifecycle = state;
  flush_lifecycle();
}

void rv_platform_engine_started(void) {
  flush_lifecycle();
  rv_settings_send();
}

// --------------------------------------------------------- flutter/platform

typedef struct {
  RvEngine* engine;
  const FlutterPlatformMessageResponseHandle* handle;
} ClipboardReq;

static void clipboard_text_cb(GObject* src, GAsyncResult* res, gpointer data) {
  ClipboardReq* r = data;
  g_autofree char* text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
  if (text)
    rv_engine_respond(r->engine, r->handle, rv_json_success(rv_map("text", rv_str(text), NULL)));
  else
    rv_engine_respond(r->engine, r->handle, rv_json_success(NULL));
  g_free(r);
}

static void platform_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_json_decode_call(msg, &method, &args)) {
    rv_engine_respond_empty(e, h);
    return;
  }
  GdkClipboard* clip = gdk_display_get_clipboard(gdk_display_get_default());

  if (!strcmp(method, "Clipboard.setData")) {
    const char* text = rv_map_str(args, "text", NULL);
    if (text) gdk_clipboard_set_text(clip, text);
    rv_engine_respond(e, h, rv_json_success(NULL));
  } else if (!strcmp(method, "Clipboard.getData")) {
    const char* fmt = rv_as_str(args, "");
    if (strcmp(fmt, "text/plain") != 0) {
      rv_engine_respond(e, h, rv_json_success(NULL));
      return;
    }
    ClipboardReq* r = g_new0(ClipboardReq, 1);
    r->engine = e;
    r->handle = h;
    gdk_clipboard_read_text_async(clip, NULL, clipboard_text_cb, r);
  } else if (!strcmp(method, "Clipboard.hasStrings")) {
    GdkContentFormats* f = gdk_clipboard_get_formats(clip);
    gboolean has = gdk_content_formats_contain_gtype(f, G_TYPE_STRING);
    rv_engine_respond(e, h, rv_json_success(rv_map("value", rv_bool(has), NULL)));
  } else if (!strcmp(method, "SystemNavigator.pop")) {
    rv_engine_respond(e, h, rv_json_success(NULL));
    rv_app_navigator_pop();
  } else if (!strcmp(method, "SystemSound.play")) {
    gdk_display_beep(gdk_display_get_default());
    rv_engine_respond(e, h, rv_json_success(NULL));
  } else if (!strcmp(method, "SystemChrome.setApplicationSwitcherDescription")) {
    rv_app_set_title(rv_map_str(args, "label", NULL));
    rv_engine_respond(e, h, rv_json_success(NULL));
  } else if (!strcmp(method, "System.exitApplication")) {
    rv_engine_respond(e, h, rv_json_success(rv_map("response", rv_str("exit"), NULL)));
    rv_app_quit();
  } else if (!strcmp(method, "HapticFeedback.vibrate") || g_str_has_prefix(method, "SystemChrome.") ||
             !strcmp(method, "Platform.initializationComplete") || !strcmp(method, "System.initializationComplete") ||
             !strcmp(method, "TextInput.finishAutofillContext")) {
    rv_engine_respond(e, h, rv_json_success(NULL));
  } else {
    rv_engine_respond_empty(e, h);  // not implemented
  }
}

// ------------------------------------------------------- flutter/mousecursor

static const char* cursor_name(const char* kind) {
  static const struct {
    const char *kind, *css;
  } map[] = {
      {"basic", "default"},     {"click", "pointer"},          {"text", "text"},
      {"forbidden", "not-allowed"}, {"grab", "grab"},          {"grabbing", "grabbing"},
      {"help", "help"},         {"none", "none"},              {"progress", "progress"},
      {"contextMenu", "context-menu"}, {"alias", "alias"},     {"cell", "cell"},
      {"copy", "copy"},         {"move", "move"},              {"noDrop", "no-drop"},
      {"wait", "wait"},         {"verticalText", "vertical-text"}, {"allScroll", "all-scroll"},
      {"zoomIn", "zoom-in"},    {"zoomOut", "zoom-out"},       {"resizeColumn", "col-resize"},
      {"resizeRow", "row-resize"}, {"resizeUp", "n-resize"},   {"resizeDown", "s-resize"},
      {"resizeLeft", "w-resize"}, {"resizeRight", "e-resize"}, {"resizeUpLeft", "nw-resize"},
      {"resizeUpRight", "ne-resize"}, {"resizeDownLeft", "sw-resize"}, {"resizeDownRight", "se-resize"},
      {"resizeUpDown", "ns-resize"}, {"resizeLeftRight", "ew-resize"},
      {"resizeUpLeftDownRight", "nwse-resize"}, {"resizeUpRightDownLeft", "nesw-resize"},
  };
  for (gsize i = 0; i < G_N_ELEMENTS(map); i++)
    if (!strcmp(map[i].kind, kind)) return map[i].css;
  return "default";
}

static void mousecursor_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_std_decode_call(msg, &method, &args)) {
    rv_engine_respond_empty(e, h);
    return;
  }
  if (!strcmp(method, "activateSystemCursor")) {
    RvView* v = rv_view_get();
    if (v) rv_view_set_cursor(v, cursor_name(rv_map_str(args, "kind", "basic")));
    rv_engine_respond(e, h, rv_std_success(NULL));
  } else {
    rv_engine_respond_empty(e, h);
  }
}

// --------------------------------------------------------------------- init

static void navigation_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)msg;
  (void)ud;
  rv_engine_respond(e, h, rv_json_success(NULL));  // routeUpdated & friends
}

void rv_platform_init(RvEngine* engine) {
  g_engine = engine;
  rv_engine_add_handler(engine, "flutter/platform", platform_message, NULL);
  rv_engine_add_handler(engine, "flutter/mousecursor", mousecursor_message, NULL);
  rv_engine_add_handler(engine, "flutter/navigation", navigation_message, NULL);
  rv_settings_init(engine);
}
