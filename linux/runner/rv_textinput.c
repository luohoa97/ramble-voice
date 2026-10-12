// SPDX-License-Identifier: GPL-3.0-or-later
//
// `flutter/textinput` (JSONMethodCodec) on top of GtkIMContextMulticontext.
// The editing model (UTF-16 text, selection, composing region) and the
// key/commit/preedit handling follow Flutter's GTK shell
// (fl_text_input_handler.cc, text_input_model.cc; BSD-3-Clause, see
// linux/THIRD_PARTY.md).
#include "rv_textinput.h"

#include <string.h>

#include "rv_view.h"

#define kNoClient (-1)

typedef struct {
  GArray* text;  // guint16 (UTF-16 code units)
  int sel_base, sel_extent;
  gboolean composing;
  int comp_start, comp_len;
} Model;

static struct {
  RvEngine* engine;
  GtkIMContext* im;
  GtkWidget* view;
  Model m;
  gint64 client;
  char* action;
  gboolean multiline;
  gboolean shown;
  gboolean window_focused;
  gboolean im_focused;
  double transform[16];
  double rect_x, rect_y, rect_w, rect_h;
} S = {.client = kNoClient};

// ---------------------------------------------------------------- model

static int sel_start(void) { return MIN(S.m.sel_base, S.m.sel_extent); }
static int sel_end(void) { return MAX(S.m.sel_base, S.m.sel_extent); }
static int text_len(void) { return S.m.text->len; }

static void model_set_utf8(const char* utf8) {
  glong n = 0;
  g_autofree gunichar2* u16 = g_utf8_to_utf16(utf8 ? utf8 : "", -1, NULL, &n, NULL);
  g_array_set_size(S.m.text, 0);
  if (u16) g_array_append_vals(S.m.text, u16, n);
}

static char* model_utf8(void) {
  char* s = g_utf16_to_utf8((gunichar2*)S.m.text->data, S.m.text->len, NULL, NULL, NULL);
  return s ? s : g_strdup("");
}

static void model_replace(int start, int end, const char* utf8) {
  glong n = 0;
  g_autofree gunichar2* u16 = g_utf8_to_utf16(utf8 ? utf8 : "", -1, NULL, &n, NULL);
  start = CLAMP(start, 0, text_len());
  end = CLAMP(end, start, text_len());
  g_array_remove_range(S.m.text, start, end - start);
  if (u16 && n) g_array_insert_vals(S.m.text, start, u16, n);
}

static int utf16_len(const char* utf8) {
  glong n = 0;
  g_autofree gunichar2* u16 = g_utf8_to_utf16(utf8, -1, NULL, &n, NULL);
  return u16 ? (int)n : 0;
}

static void delete_selected(void) {
  int s = sel_start(), e = sel_end();
  if (s == e) return;
  model_replace(s, e, "");
  if (S.m.composing && S.m.comp_start >= e) S.m.comp_start -= e - s;
  S.m.sel_base = S.m.sel_extent = s;
}

// Insert at the selection (replacing it) or over the composing region.
static void model_add_text(const char* utf8) {
  if (S.m.composing) {
    model_replace(S.m.comp_start, S.m.comp_start + S.m.comp_len, utf8);
    S.m.sel_base = S.m.sel_extent = S.m.comp_start + utf16_len(utf8);
    S.m.composing = FALSE;
    S.m.comp_len = 0;
    return;
  }
  delete_selected();
  int at = sel_start();
  model_replace(at, at, utf8);
  S.m.sel_base = S.m.sel_extent = at + utf16_len(utf8);
}

// ------------------------------------------------------------ to Dart

static void send_editing_state(void) {
  if (S.client == kNoClient) return;
  g_autofree char* text = model_utf8();
  int cb = -1, ce = -1;
  if (S.m.composing && S.m.comp_len > 0) {
    cb = S.m.comp_start;
    ce = S.m.comp_start + S.m.comp_len;
  }
  GVariant* state = rv_map("text", rv_str(text), "selectionBase", rv_int(S.m.sel_base), "selectionExtent",
                           rv_int(S.m.sel_extent), "selectionAffinity", rv_str("TextAffinity.downstream"),
                           "selectionIsDirectional", rv_bool(FALSE), "composingBase", rv_int(cb),
                           "composingExtent", rv_int(ce), NULL);
  rv_engine_send(S.engine, "flutter/textinput",
                 rv_json_method_call("TextInputClient.updateEditingState", rv_list(rv_int(S.client), state, NULL)),
                 NULL, NULL);
}

static void send_action(void) {
  if (S.client == kNoClient || !S.action) return;
  rv_engine_send(S.engine, "flutter/textinput",
                 rv_json_method_call("TextInputClient.performAction",
                                     rv_list(rv_int(S.client), rv_str(S.action), NULL)),
                 NULL, NULL);
}

// ------------------------------------------------------------ IM signals

static void update_im_focus(void) {
  gboolean want = S.client != kNoClient && S.shown && S.window_focused;
  if (want == S.im_focused) return;
  S.im_focused = want;
  if (want) gtk_im_context_focus_in(S.im);
  else gtk_im_context_focus_out(S.im);
}

static void im_preedit_start_cb(GtkIMContext* im, gpointer d) {
  (void)im;
  (void)d;
  S.m.composing = TRUE;
  S.m.comp_start = sel_start();
  S.m.comp_len = 0;
}

static void im_preedit_changed_cb(GtkIMContext* im, gpointer d) {
  (void)d;
  g_autofree char* preedit = NULL;
  int cursor = 0;
  gtk_im_context_get_preedit_string(im, &preedit, NULL, &cursor);
  if (!S.m.composing) im_preedit_start_cb(im, NULL);
  delete_selected();
  model_replace(S.m.comp_start, S.m.comp_start + S.m.comp_len, preedit);
  S.m.comp_len = utf16_len(preedit);
  S.m.sel_base = S.m.sel_extent = S.m.comp_start + MIN(cursor, S.m.comp_len);
  send_editing_state();
}

static void im_preedit_end_cb(GtkIMContext* im, gpointer d) {
  (void)im;
  (void)d;
  S.m.composing = FALSE;
  S.m.comp_len = 0;
  send_editing_state();
}

static void im_commit_cb(GtkIMContext* im, const char* text, gpointer d) {
  (void)im;
  (void)d;
  model_add_text(text);
  send_editing_state();
}

static gboolean im_retrieve_surrounding_cb(GtkIMContext* im, gpointer d) {
  (void)d;
  g_autofree char* text = model_utf8();
  g_autofree char* head = g_utf16_to_utf8((gunichar2*)S.m.text->data, MIN(S.m.sel_extent, text_len()), NULL, NULL, NULL);
  int cur = head ? (int)strlen(head) : 0;
  gtk_im_context_set_surrounding_with_selection(im, text, -1, cur, cur);
  return TRUE;
}

static gboolean im_delete_surrounding_cb(GtkIMContext* im, int offset, int n_chars, gpointer d) {
  (void)im;
  (void)d;
  g_autofree char* text = model_utf8();
  g_autofree char* head = g_utf16_to_utf8((gunichar2*)S.m.text->data, MIN(S.m.sel_extent, text_len()), NULL, NULL, NULL);
  glong cursor = head ? g_utf8_strlen(head, -1) : 0;
  glong total = g_utf8_strlen(text, -1);
  glong from = CLAMP(cursor + offset, 0, total);
  glong to = CLAMP(from + n_chars, from, total);
  char* a = g_utf8_offset_to_pointer(text, from);
  char* b = g_utf8_offset_to_pointer(text, to);
  g_autofree char* out = g_strdup_printf("%.*s%s", (int)(a - text), text, b);
  g_autofree char* new_head = g_strndup(out, a - text);
  model_set_utf8(out);
  S.m.sel_base = S.m.sel_extent = utf16_len(new_head);
  send_editing_state();
  return TRUE;
}

// ------------------------------------------------------- cursor location

static void update_im_cursor(void) {
  if (!S.im || !S.view || S.client == kNoClient) return;
  const double* t = S.transform;
  GdkRectangle r;
  r.x = S.rect_x * t[0] + S.rect_y * t[4] + t[12] + S.rect_w;
  r.y = S.rect_x * t[1] + S.rect_y * t[5] + t[13];
  r.width = 1;
  r.height = MAX(1, (int)S.rect_h);
  gtk_im_context_set_cursor_location(S.im, &r);
}

// --------------------------------------------------------------- channel

static void apply_config(GVariant* config) {
  g_autoptr(GVariant) type = rv_map_get(config, "inputType");
  const char* name = rv_map_str(type, "name", "TextInputType.text");
  GtkInputPurpose purpose = GTK_INPUT_PURPOSE_FREE_FORM;
  GtkInputHints hints = GTK_INPUT_HINT_NONE;
  S.multiline = FALSE;
  gboolean none = FALSE;
  if (!strcmp(name, "TextInputType.multiline")) {
    hints = GTK_INPUT_HINT_SPELLCHECK | GTK_INPUT_HINT_UPPERCASE_SENTENCES;
    S.multiline = TRUE;
  } else if (!strcmp(name, "TextInputType.number")) purpose = GTK_INPUT_PURPOSE_NUMBER;
  else if (!strcmp(name, "TextInputType.phone")) purpose = GTK_INPUT_PURPOSE_PHONE;
  else if (!strcmp(name, "TextInputType.emailAddress")) purpose = GTK_INPUT_PURPOSE_EMAIL;
  else if (!strcmp(name, "TextInputType.url")) purpose = GTK_INPUT_PURPOSE_URL;
  else if (!strcmp(name, "TextInputType.visiblePassword")) purpose = GTK_INPUT_PURPOSE_PASSWORD;
  else if (!strcmp(name, "TextInputType.name")) {
    purpose = GTK_INPUT_PURPOSE_NAME;
    hints = GTK_INPUT_HINT_UPPERCASE_WORDS;
  } else if (!strcmp(name, "TextInputType.none")) none = TRUE;
  if (rv_map_bool(config, "obscureText", FALSE)) purpose = GTK_INPUT_PURPOSE_PASSWORD;
  g_object_set(S.im, "input-purpose", purpose, "input-hints", hints, NULL);

  g_free(S.action);
  S.action = g_strdup(rv_map_str(config, "inputAction", "TextInputAction.done"));
  if (none) S.shown = FALSE;
}

static void textinput_message(RvEngine* e, GBytes* msg, const FlutterPlatformMessageResponseHandle* h, gpointer ud) {
  (void)ud;
  g_autofree char* method = NULL;
  g_autoptr(GVariant) args = NULL;
  if (!rv_json_decode_call(msg, &method, &args)) {
    rv_engine_respond_empty(e, h);
    return;
  }
  if (!strcmp(method, "TextInput.setClient")) {
    g_autoptr(GVariant) id = rv_list_get(args, 0);
    g_autoptr(GVariant) cfg = rv_list_get(args, 1);
    S.client = rv_as_int(id, kNoClient);
    S.shown = FALSE;
    S.m.composing = FALSE;
    apply_config(cfg);
    S.shown = FALSE;  // an explicit TextInput.show follows
    update_im_focus();
  } else if (!strcmp(method, "TextInput.updateConfig")) {
    apply_config(args);
  } else if (!strcmp(method, "TextInput.show")) {
    S.shown = TRUE;
    update_im_focus();
    update_im_cursor();
  } else if (!strcmp(method, "TextInput.hide")) {
    S.shown = FALSE;
    update_im_focus();
  } else if (!strcmp(method, "TextInput.clearClient")) {
    S.client = kNoClient;
    S.shown = FALSE;
    S.m.composing = FALSE;
    gtk_im_context_reset(S.im);
    update_im_focus();
  } else if (!strcmp(method, "TextInput.setEditingState")) {
    model_set_utf8(rv_map_str(args, "text", ""));
    int base = (int)rv_map_int(args, "selectionBase", 0);
    int ext = (int)rv_map_int(args, "selectionExtent", 0);
    if (base < 0 && ext < 0) base = ext = 0;
    S.m.sel_base = CLAMP(base, 0, text_len());
    S.m.sel_extent = CLAMP(ext, 0, text_len());
    int cb = (int)rv_map_int(args, "composingBase", -1);
    int ce = (int)rv_map_int(args, "composingExtent", -1);
    if (cb < 0 && ce < 0) {
      S.m.composing = FALSE;
      S.m.comp_len = 0;
    } else {
      S.m.composing = TRUE;
      S.m.comp_start = CLAMP(MIN(cb, ce), 0, text_len());
      S.m.comp_len = CLAMP(MAX(cb, ce), 0, text_len()) - S.m.comp_start;
    }
  } else if (!strcmp(method, "TextInput.setEditableSizeAndTransform")) {
    g_autoptr(GVariant) tr = rv_map_get(args, "transform");
    for (int i = 0; i < 16 && (gsize)i < rv_list_len(tr); i++) {
      g_autoptr(GVariant) c = rv_list_get(tr, i);
      S.transform[i] = rv_as_double(c, i % 5 == 0 ? 1.0 : 0.0);
    }
    update_im_cursor();
  } else if (!strcmp(method, "TextInput.setMarkedTextRect")) {
    S.rect_x = rv_map_double(args, "x", 0);
    S.rect_y = rv_map_double(args, "y", 0);
    S.rect_w = rv_map_double(args, "width", 0);
    S.rect_h = rv_map_double(args, "height", 0);
    update_im_cursor();
  }
  // Everything else (setStyle, requestAutofill, finishAutofillContext,
  // setCaretRect, ...) is accepted and ignored.
  rv_engine_respond(e, h, rv_json_success(NULL));
}

void rv_textinput_init(RvEngine* engine) {
  S.engine = engine;
  S.m.text = g_array_new(FALSE, FALSE, sizeof(guint16));
  for (int i = 0; i < 16; i++) S.transform[i] = i % 5 == 0 ? 1.0 : 0.0;
  S.im = gtk_im_multicontext_new();
  g_signal_connect(S.im, "preedit-start", G_CALLBACK(im_preedit_start_cb), NULL);
  g_signal_connect(S.im, "preedit-changed", G_CALLBACK(im_preedit_changed_cb), NULL);
  g_signal_connect(S.im, "preedit-end", G_CALLBACK(im_preedit_end_cb), NULL);
  g_signal_connect(S.im, "commit", G_CALLBACK(im_commit_cb), NULL);
  g_signal_connect(S.im, "retrieve-surrounding", G_CALLBACK(im_retrieve_surrounding_cb), NULL);
  g_signal_connect(S.im, "delete-surrounding", G_CALLBACK(im_delete_surrounding_cb), NULL);
  rv_engine_add_handler(engine, "flutter/textinput", textinput_message, NULL);
}

void rv_textinput_attach(GtkWidget* view) {
  S.view = view;
  gtk_im_context_set_client_widget(S.im, view);
}

void rv_textinput_window_focus(gboolean focused) {
  S.window_focused = focused;
  update_im_focus();
}

gboolean rv_textinput_filter_key(GdkEvent* event) {
  if (S.client == kNoClient || !S.im_focused) return FALSE;
  if (gtk_im_context_filter_keypress(S.im, event)) return TRUE;
  if (gdk_event_get_event_type(event) != GDK_KEY_PRESS) return FALSE;

  guint keyval = gdk_key_event_get_keyval(event);
  GdkModifierType state = gdk_event_get_modifier_state(event);
  gboolean shift = state & GDK_SHIFT_MASK;
  switch (keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
    case GDK_KEY_ISO_Enter:
      if (S.multiline && S.action && !strcmp(S.action, "TextInputAction.newline")) {
        model_add_text("\n");
        send_editing_state();
      }
      send_action();
      return TRUE;
    case GDK_KEY_Home:
    case GDK_KEY_KP_Home:
      S.m.sel_extent = 0;
      if (!shift) S.m.sel_base = 0;
      send_editing_state();
      return TRUE;
    case GDK_KEY_End:
    case GDK_KEY_KP_End:
      S.m.sel_extent = text_len();
      if (!shift) S.m.sel_base = text_len();
      send_editing_state();
      return TRUE;
    default:
      return FALSE;  // arrows, backspace, delete: handled by the framework
  }
}
