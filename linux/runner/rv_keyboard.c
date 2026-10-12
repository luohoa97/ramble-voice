// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboard: GDK key events -> FlutterEngineSendKeyEvent (new key data API)
// plus the legacy `flutter/keyevent` JSON channel.  Events neither of them
// handle fall through to the input method (rv_textinput).
//
// The mapping and event regularisation follow Flutter's GTK shell
// (fl_key_embedder_responder.cc, BSD-3-Clause; see linux/THIRD_PARTY.md),
// without the lock-key/modifier resynchronisation.
#include "rv_keyboard.h"

#include "rv_keymap.h"
#include "rv_textinput.h"

#define RV_MOD2_MASK (1 << 4)  // num lock

static RvEngine* g_engine;
static GThread* g_main_thread;
static GHashTable* g_pressed;  // physical key (guint64*) -> logical key (guint64*)

typedef struct {
  GdkEvent* event;
  int pending;
  gboolean handled;
} Pending;

void rv_keyboard_init(RvEngine* engine) {
  g_engine = engine;
  g_main_thread = g_thread_self();
  if (!g_pressed) g_pressed = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, g_free);
}

static void resolve(Pending* p) {
  if (--p->pending > 0) return;
  if (!p->handled) rv_textinput_filter_key(p->event);
  g_object_unref(p->event);
  g_free(p);
}

static gboolean embedder_done_idle(gpointer data) {
  resolve(data);
  return G_SOURCE_REMOVE;
}

static void embedder_done(bool handled, void* user_data) {
  Pending* p = user_data;
  if (handled) p->handled = TRUE;
  // Normally invoked on the platform (main) thread; marshal otherwise.
  if (g_thread_self() == g_main_thread)
    resolve(p);
  else
    g_idle_add(embedder_done_idle, p);
}

static void channel_done(GBytes* reply, gpointer user_data) {
  Pending* p = user_data;
  if (reply) {
    gsize len;
    const guint8* d = g_bytes_get_data(reply, &len);
    g_autoptr(GVariant) v = rv_json_decode(d, len);
    if (v) {
      g_variant_ref_sink(v);
      if (rv_map_bool(v, "handled", FALSE)) p->handled = TRUE;
    }
  }
  resolve(p);
}

static char* event_character(guint keyval) {
  gunichar c = gdk_keyval_to_unicode(keyval);
  if (!c) return NULL;
  char buf[8];
  int n = g_unichar_to_utf8(c, buf);
  return g_strndup(buf, n);
}

static void send_synth(guint64 physical, guint64 logical) {
  FlutterKeyEvent ev = {0};
  ev.struct_size = sizeof ev;
  ev.timestamp = (double)rv_engine_now_us();
  ev.type = kFlutterKeyEventTypeUp;
  ev.physical = physical;
  ev.logical = logical;
  ev.synthesized = true;
  ev.device_type = kFlutterKeyEventDeviceTypeKeyboard;
  FlutterEngineSendKeyEvent(rv_engine_raw(g_engine), &ev, NULL, NULL);
}

void rv_keyboard_release_all(void) {
  if (!g_pressed || !rv_engine_is_running(g_engine)) return;
  GHashTableIter it;
  gpointer k, v;
  g_hash_table_iter_init(&it, g_pressed);
  while (g_hash_table_iter_next(&it, &k, &v)) send_synth(*(guint64*)k, *(guint64*)v);
  g_hash_table_remove_all(g_pressed);
}

gboolean rv_keyboard_handle(GdkEvent* event) {
  GdkEventType type = gdk_event_get_event_type(event);
  if (type != GDK_KEY_PRESS && type != GDK_KEY_RELEASE) return FALSE;
  gboolean down = type == GDK_KEY_PRESS;
  guint keyval = gdk_key_event_get_keyval(event);
  guint keycode = gdk_key_event_get_keycode(event);
  guint state = gdk_event_get_modifier_state(event);
  guint64 physical = rv_keymap_physical(keycode);
  guint64 logical = rv_keymap_logical(keyval);

  guint64* recorded = g_hash_table_lookup(g_pressed, &physical);
  FlutterKeyEventType ftype;
  if (down) {
    ftype = recorded ? kFlutterKeyEventTypeRepeat : kFlutterKeyEventTypeDown;
    if (recorded) {
      logical = *recorded;
    } else {
      guint64* pk = g_new(guint64, 1);
      guint64* lk = g_new(guint64, 1);
      *pk = physical;
      *lk = logical;
      g_hash_table_insert(g_pressed, pk, lk);
    }
  } else {
    if (!recorded) return TRUE;  // release of a key we never saw go down
    logical = *recorded;
    ftype = kFlutterKeyEventTypeUp;
  }

  Pending* p = g_new0(Pending, 1);
  p->event = g_object_ref(event);
  p->pending = 2;

  g_autofree char* character = down ? event_character(keyval) : NULL;
  FlutterKeyEvent ev = {0};
  ev.struct_size = sizeof ev;
  ev.timestamp = (double)gdk_event_get_time(event) * 1000.0;
  ev.type = ftype;
  ev.physical = physical;
  ev.logical = logical;
  ev.character = character;
  ev.synthesized = false;
  ev.device_type = kFlutterKeyEventDeviceTypeKeyboard;

  // Legacy channel message first: it is queued behind nothing and carries a
  // copy of all data it needs.
  guint chan_state = state & ~(GDK_LOCK_MASK | RV_MOD2_MASK);
  GBytes* msg = rv_json_encode(rv_map("type", rv_str(down ? "keydown" : "keyup"), "keymap", rv_str("linux"),
                                      "scanCode", rv_int(keycode), "toolkit", rv_str("gtk"), "keyCode",
                                      rv_int(keyval), "modifiers", rv_int(chan_state), "unicodeScalarValues",
                                      rv_int(gdk_keyval_to_unicode(keyval)), NULL));
  rv_engine_send(g_engine, "flutter/keyevent", msg, channel_done, p);
  FlutterEngineSendKeyEvent(rv_engine_raw(g_engine), &ev, embedder_done, p);

  if (!down) g_hash_table_remove(g_pressed, &physical);
  return TRUE;
}
