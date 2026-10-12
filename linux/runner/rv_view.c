// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_view.h"

#include <math.h>

#include "rv_a11y.h"
#include "rv_app.h"
#include "rv_keyboard.h"
#include "rv_platform.h"
#include "rv_textinput.h"

#define kScrollWheelStep 53.0  // logical pixels per wheel notch (as Flutter GTK)
#define kTouchDeviceBase 100
#define kTrackpadDevice 99

typedef struct {
  int x, y, w, h;
} ChildRect;

struct _RvView {
  GtkWidget parent_instance;
  RvEngine* engine;
  GdkTexture* frame;
  int width, height;  // logical, last allocation
  double scale;
  // Pointer state (mouse)
  gboolean mouse_added;
  int64_t buttons;
  // Trackpad
  gboolean pan_active;
  double pan_x, pan_y;
  gboolean trackpad_added;
  double last_x, last_y;  // last pointer position, logical
  // Touch: GdkEventSequence* -> device id
  GHashTable* touches;
  int next_touch;
  GPtrArray* children;
  GtkWidget* window_for_active;
  gboolean engine_focused;
};

G_DEFINE_FINAL_TYPE(RvView, rv_view, GTK_TYPE_WIDGET)

static RvView* g_view;

RvView* rv_view_get(void) { return g_view; }
double rv_view_get_scale(RvView* v) { return v->scale; }

// ------------------------------------------------------------ pointer util

static void send_pointer(RvView* v, FlutterPointerPhase phase, double x, double y, int device,
                         FlutterPointerDeviceKind kind, int64_t buttons, FlutterPointerSignalKind signal,
                         double dx, double dy) {
  if (!rv_engine_is_running(v->engine)) return;
  FlutterPointerEvent ev = {0};
  ev.struct_size = sizeof ev;
  ev.phase = phase;
  ev.timestamp = rv_engine_now_us();
  ev.x = x * v->scale;
  ev.y = y * v->scale;
  ev.device = device;
  ev.device_kind = kind;
  ev.buttons = buttons;
  ev.signal_kind = signal;
  ev.scroll_delta_x = dx;
  ev.scroll_delta_y = dy;
  ev.view_id = 0;
  FlutterEngineSendPointerEvent(rv_engine_raw(v->engine), &ev, 1);
}

static void mouse_event(RvView* v, FlutterPointerPhase phase, double x, double y) {
  v->last_x = x;
  v->last_y = y;
  send_pointer(v, phase, x, y, 0, kFlutterPointerDeviceKindMouse, v->buttons,
               kFlutterPointerSignalKindNone, 0, 0);
}

static void ensure_mouse_added(RvView* v, double x, double y) {
  if (v->mouse_added) return;
  v->mouse_added = TRUE;
  mouse_event(v, kAdd, x, y);
}

static int64_t button_bit(guint button) {
  switch (button) {
    case GDK_BUTTON_PRIMARY: return kFlutterPointerButtonMousePrimary;
    case GDK_BUTTON_MIDDLE: return kFlutterPointerButtonMouseMiddle;
    case GDK_BUTTON_SECONDARY: return kFlutterPointerButtonMouseSecondary;
    case 8: return kFlutterPointerButtonMouseBack;
    case 9: return kFlutterPointerButtonMouseForward;
    default: return 0;
  }
}

static gboolean is_touch_gesture(GtkGesture* g) {
  GdkEvent* ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(g));
  if (!ev) return FALSE;
  GdkEventType t = gdk_event_get_event_type(ev);
  if (t == GDK_TOUCH_BEGIN || t == GDK_TOUCH_UPDATE || t == GDK_TOUCH_END || t == GDK_TOUCH_CANCEL)
    return TRUE;
  GdkDevice* d = gdk_event_get_device(ev);
  return d && gdk_device_get_source(d) == GDK_SOURCE_TOUCHSCREEN;
}

// ------------------------------------------------------------ mouse events

static void motion_enter_cb(GtkEventControllerMotion* c, double x, double y, RvView* v) {
  (void)c;
  ensure_mouse_added(v, x, y);
}

static void motion_cb(GtkEventControllerMotion* c, double x, double y, RvView* v) {
  GdkEvent* ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(c));
  GdkDevice* d = ev ? gdk_event_get_device(ev) : NULL;
  if (d && gdk_device_get_source(d) == GDK_SOURCE_TOUCHSCREEN) return;
  ensure_mouse_added(v, x, y);
  mouse_event(v, v->buttons ? kMove : kHover, x, y);
}

static void motion_leave_cb(GtkEventControllerMotion* c, RvView* v) {
  (void)c;
  if (!v->mouse_added || v->buttons) return;  // keep tracking while dragging
  v->mouse_added = FALSE;
  mouse_event(v, kRemove, v->last_x, v->last_y);
}

static void click_pressed_cb(GtkGestureClick* g, int n_press, double x, double y, RvView* v) {
  (void)n_press;
  if (is_touch_gesture(GTK_GESTURE(g))) return;
  guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g));
  int64_t bit = button_bit(button);
  if (!bit) return;
  gtk_widget_grab_focus(GTK_WIDGET(v));
  ensure_mouse_added(v, x, y);
  FlutterPointerPhase phase = v->buttons ? kMove : kDown;
  v->buttons |= bit;
  mouse_event(v, phase, x, y);
}

static void click_released_cb(GtkGestureClick* g, int n_press, double x, double y, RvView* v) {
  (void)n_press;
  if (is_touch_gesture(GTK_GESTURE(g))) return;
  guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g));
  int64_t bit = button_bit(button);
  if (!bit || !(v->buttons & bit)) return;
  v->buttons &= ~bit;
  mouse_event(v, v->buttons ? kMove : kUp, x, y);
}

static void click_stopped_cb(GtkGestureClick* g, RvView* v) {
  (void)g;
  (void)v;
}

// ------------------------------------------------------------ touch events

static int touch_id(RvView* v, GtkGesture* g, gboolean create) {
  GdkEventSequence* seq = gtk_gesture_get_last_updated_sequence(g);
  gpointer val = g_hash_table_lookup(v->touches, seq);
  if (val) return GPOINTER_TO_INT(val);
  if (!create) return -1;
  int id = kTouchDeviceBase + (v->next_touch++ % 10);
  g_hash_table_insert(v->touches, seq, GINT_TO_POINTER(id));
  return id;
}

static void drag_begin_cb(GtkGestureDrag* g, double x, double y, RvView* v) {
  int id = touch_id(v, GTK_GESTURE(g), TRUE);
  gtk_widget_grab_focus(GTK_WIDGET(v));
  send_pointer(v, kAdd, x, y, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
  send_pointer(v, kDown, x, y, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
}

static void drag_update_cb(GtkGestureDrag* g, double ox, double oy, RvView* v) {
  int id = touch_id(v, GTK_GESTURE(g), FALSE);
  if (id < 0) return;
  double sx, sy;
  gtk_gesture_drag_get_start_point(g, &sx, &sy);
  send_pointer(v, kMove, sx + ox, sy + oy, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
}

static void drag_end_cb(GtkGestureDrag* g, double ox, double oy, RvView* v) {
  int id = touch_id(v, GTK_GESTURE(g), FALSE);
  if (id < 0) return;
  double sx, sy;
  gtk_gesture_drag_get_start_point(g, &sx, &sy);
  send_pointer(v, kUp, sx + ox, sy + oy, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
  send_pointer(v, kRemove, sx + ox, sy + oy, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
  g_hash_table_remove(v->touches, gtk_gesture_get_last_updated_sequence(GTK_GESTURE(g)));
}

static void drag_cancel_cb(GtkGesture* g, GdkEventSequence* seq, RvView* v) {
  (void)g;
  gpointer val = g_hash_table_lookup(v->touches, seq);
  if (!val) return;
  int id = GPOINTER_TO_INT(val);
  send_pointer(v, kCancel, v->last_x, v->last_y, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
  send_pointer(v, kRemove, v->last_x, v->last_y, id, kFlutterPointerDeviceKindTouch, 0, kFlutterPointerSignalKindNone, 0, 0);
  g_hash_table_remove(v->touches, seq);
}

// ------------------------------------------------------------------ scroll

static void scroll_begin_cb(GtkEventControllerScroll* c, RvView* v) {
  (void)c;
  (void)v;
}

static gboolean scroll_cb(GtkEventControllerScroll* c, double dx, double dy, RvView* v) {
  if (!rv_engine_is_running(v->engine)) return FALSE;
  GdkScrollUnit unit = gtk_event_controller_scroll_get_unit(c);
  GdkEvent* ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(c));
  GdkDevice* dev = ev ? gdk_event_get_device(ev) : NULL;
  gboolean touchpad = dev && gdk_device_get_source(dev) == GDK_SOURCE_TOUCHPAD;
  if (unit == GDK_SCROLL_UNIT_SURFACE && touchpad) {
    // Touchpad two-finger scroll: pan/zoom so Flutter applies its own fling.
    if (!v->trackpad_added) {
      v->trackpad_added = TRUE;
      send_pointer(v, kAdd, v->last_x, v->last_y, kTrackpadDevice, kFlutterPointerDeviceKindTrackpad, 0,
                   kFlutterPointerSignalKindNone, 0, 0);
    }
    if (!v->pan_active) {
      v->pan_active = TRUE;
      v->pan_x = v->pan_y = 0;
      send_pointer(v, kPanZoomStart, v->last_x, v->last_y, kTrackpadDevice, kFlutterPointerDeviceKindTrackpad, 0,
                   kFlutterPointerSignalKindNone, 0, 0);
    }
    v->pan_x -= dx * v->scale;
    v->pan_y -= dy * v->scale;
    FlutterPointerEvent pe = {0};
    pe.struct_size = sizeof pe;
    pe.phase = kPanZoomUpdate;
    pe.timestamp = rv_engine_now_us();
    pe.x = v->last_x * v->scale;
    pe.y = v->last_y * v->scale;
    pe.device = kTrackpadDevice;
    pe.device_kind = kFlutterPointerDeviceKindTrackpad;
    pe.pan_x = v->pan_x;
    pe.pan_y = v->pan_y;
    pe.scale = 1.0;
    pe.rotation = 0;
    FlutterEngineSendPointerEvent(rv_engine_raw(v->engine), &pe, 1);
    return TRUE;
  }
  double mul = (unit == GDK_SCROLL_UNIT_WHEEL ? kScrollWheelStep : 1.0) * v->scale;
  ensure_mouse_added(v, v->last_x, v->last_y);
  send_pointer(v, v->buttons ? kMove : kHover, v->last_x, v->last_y, 0, kFlutterPointerDeviceKindMouse, v->buttons,
               kFlutterPointerSignalKindScroll, dx * mul, dy * mul);
  return TRUE;
}

static void scroll_end_cb(GtkEventControllerScroll* c, RvView* v) {
  (void)c;
  if (!v->pan_active) return;
  v->pan_active = FALSE;
  send_pointer(v, kPanZoomEnd, v->last_x, v->last_y, kTrackpadDevice, kFlutterPointerDeviceKindTrackpad, 0,
               kFlutterPointerSignalKindNone, 0, 0);
}

// ---------------------------------------------------------------- keyboard

static gboolean key_pressed_cb(GtkEventControllerKey* c, guint keyval, guint keycode, GdkModifierType state, RvView* v) {
  (void)keyval;
  (void)keycode;
  (void)state;
  GdkEvent* ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(c));
  if (!ev || !rv_engine_is_running(v->engine)) return FALSE;
  return rv_keyboard_handle(ev);
}

static void key_released_cb(GtkEventControllerKey* c, guint keyval, guint keycode, GdkModifierType state, RvView* v) {
  (void)keyval;
  (void)keycode;
  (void)state;
  GdkEvent* ev = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(c));
  if (ev && rv_engine_is_running(v->engine)) rv_keyboard_handle(ev);
}

// ------------------------------------------------------------------- focus

static void send_view_focus(RvView* v, gboolean focused) {
  if (!rv_engine_is_running(v->engine) || v->engine_focused == focused) return;
  v->engine_focused = focused;
  FlutterViewFocusEvent ev = {0};
  ev.struct_size = sizeof ev;
  ev.view_id = 0;
  ev.state = focused ? kFocused : kUnfocused;
  ev.direction = kUndefined;
  FlutterEngineSendViewFocusEvent(rv_engine_raw(v->engine), &ev);
}

static void focus_enter_cb(GtkEventControllerFocus* c, RvView* v) {
  (void)c;
  send_view_focus(v, TRUE);
  rv_textinput_window_focus(TRUE);
}

static void focus_leave_cb(GtkEventControllerFocus* c, RvView* v) {
  (void)c;
  send_view_focus(v, FALSE);
  rv_keyboard_release_all();
  rv_textinput_window_focus(FALSE);
}

static void window_active_cb(GObject* window, GParamSpec* pspec, RvView* v) {
  (void)pspec;
  gboolean active = gtk_window_is_active(GTK_WINDOW(window));
  rv_platform_set_lifecycle(active ? RV_LIFECYCLE_RESUMED : RV_LIFECYCLE_INACTIVE);
  if (active) gtk_widget_grab_focus(GTK_WIDGET(v));
}

static void root_changed_cb(GObject* obj, GParamSpec* pspec, RvView* v) {
  (void)pspec;
  GtkRoot* root = gtk_widget_get_root(GTK_WIDGET(obj));
  if (v->window_for_active) {
    g_signal_handlers_disconnect_by_func(v->window_for_active, window_active_cb, v);
    v->window_for_active = NULL;
  }
  if (root && GTK_IS_WINDOW(root)) {
    v->window_for_active = GTK_WIDGET(root);
    g_signal_connect(root, "notify::is-active", G_CALLBACK(window_active_cb), v);
  }
}

// ----------------------------------------------------------------- metrics

static double current_scale(RvView* v) {
  GtkNative* native = gtk_widget_get_native(GTK_WIDGET(v));
  GdkSurface* surface = native ? gtk_native_get_surface(native) : NULL;
  if (surface) return gdk_surface_get_scale(surface);
  return gtk_widget_get_scale_factor(GTK_WIDGET(v));
}

static void send_metrics(RvView* v) {
  if (v->width <= 0 || v->height <= 0) return;
  v->scale = current_scale(v);
  rv_engine_send_metrics(v->engine, (size_t)lround(v->width * v->scale), (size_t)lround(v->height * v->scale),
                         v->scale);
}

static void scale_changed_cb(GObject* obj, GParamSpec* pspec, RvView* v) {
  (void)obj;
  (void)pspec;
  double s = current_scale(v);
  if (s != v->scale) send_metrics(v);
  gtk_widget_queue_draw(GTK_WIDGET(v));
}

static void send_display(RvView* v) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(v));
  GtkNative* native = gtk_widget_get_native(GTK_WIDGET(v));
  GdkSurface* surface = native ? gtk_native_get_surface(native) : NULL;
  GdkMonitor* mon = surface ? gdk_display_get_monitor_at_surface(display, surface) : NULL;
  double hz = 60;
  GdkRectangle geo = {0, 0, 1920, 1080};
  if (mon) {
    hz = gdk_monitor_get_refresh_rate(mon) / 1000.0;
    gdk_monitor_get_geometry(mon, &geo);
  }
  rv_engine_send_display(v->engine, hz, (size_t)(geo.width * v->scale), (size_t)(geo.height * v->scale), v->scale);
}

// ---------------------------------------------------------------- frames

static void frame_ready(gpointer data) {
  RvView* v = data;
  GdkTexture* t = rv_renderer_take_frame(rv_engine_renderer(v->engine));
  if (!t) return;
  g_clear_object(&v->frame);
  v->frame = t;
  gtk_widget_queue_draw(GTK_WIDGET(v));
  rv_app_notify_frame();
}

// ------------------------------------------------------------ widget class

static void rv_view_measure(GtkWidget* w, GtkOrientation o, int for_size, int* min, int* nat, int* min_b, int* nat_b) {
  (void)w;
  (void)o;
  (void)for_size;
  *min = 1;
  *nat = 1;
  *min_b = *nat_b = -1;
}

static void rv_view_size_allocate(GtkWidget* widget, int width, int height, int baseline) {
  (void)baseline;
  RvView* v = RV_VIEW(widget);
  gboolean changed = width != v->width || height != v->height;
  v->width = width;
  v->height = height;
  if (changed) send_metrics(v);
  for (guint i = 0; i < v->children->len; i++) {
    GtkWidget* c = g_ptr_array_index(v->children, i);
    ChildRect* r = g_object_get_data(G_OBJECT(c), "rv-rect");
    if (!r || !gtk_widget_should_layout(c)) continue;
    GskTransform* t = gsk_transform_translate(NULL, &GRAPHENE_POINT_INIT(r->x, r->y));
    gtk_widget_allocate(c, MAX(1, r->w), MAX(1, r->h), -1, t);
  }
}

static void rv_view_snapshot(GtkWidget* widget, GtkSnapshot* snapshot) {
  RvView* v = RV_VIEW(widget);
  float w = gtk_widget_get_width(widget), h = gtk_widget_get_height(widget);
  graphene_rect_t rect = GRAPHENE_RECT_INIT(0, 0, w, h);
  if (v->frame) {
    gtk_snapshot_save(snapshot);
#ifdef RV_FLIP_Y
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(0, h));
    gtk_snapshot_scale(snapshot, 1, -1);
#endif
    gtk_snapshot_append_texture(snapshot, v->frame, &rect);
    gtk_snapshot_restore(snapshot);
  } else {
    GdkRGBA bg = {0.118f, 0.110f, 0.102f, 1};
    gtk_snapshot_append_color(snapshot, &bg, &rect);
  }
  for (guint i = 0; i < v->children->len; i++)
    gtk_widget_snapshot_child(widget, g_ptr_array_index(v->children, i), snapshot);
}

static void rv_view_realize(GtkWidget* widget) {
  GTK_WIDGET_CLASS(rv_view_parent_class)->realize(widget);
  RvView* v = RV_VIEW(widget);
  GtkNative* native = gtk_widget_get_native(widget);
  GdkSurface* surface = native ? gtk_native_get_surface(native) : NULL;
  if (surface) g_signal_connect(surface, "notify::scale", G_CALLBACK(scale_changed_cb), v);
  v->scale = current_scale(v);
}

static void rv_view_map(GtkWidget* widget) {
  GTK_WIDGET_CLASS(rv_view_parent_class)->map(widget);
  RvView* v = RV_VIEW(widget);
  v->scale = current_scale(v);
  send_display(v);
  send_metrics(v);
  gtk_widget_grab_focus(widget);
  rv_platform_set_lifecycle(RV_LIFECYCLE_RESUMED);
}

static void rv_view_unmap(GtkWidget* widget) {
  rv_platform_set_lifecycle(RV_LIFECYCLE_HIDDEN);
  GTK_WIDGET_CLASS(rv_view_parent_class)->unmap(widget);
}

static void rv_view_dispose(GObject* object) {
  RvView* v = RV_VIEW(object);
  if (v->children) {
    for (guint i = 0; i < v->children->len; i++) gtk_widget_unparent(g_ptr_array_index(v->children, i));
    g_ptr_array_free(v->children, TRUE);
    v->children = NULL;
  }
  g_clear_object(&v->frame);
  g_clear_pointer(&v->touches, g_hash_table_destroy);
  if (g_view == v) g_view = NULL;
  G_OBJECT_CLASS(rv_view_parent_class)->dispose(object);
}

static void rv_view_class_init(RvViewClass* klass) {
  GtkWidgetClass* wc = GTK_WIDGET_CLASS(klass);
  wc->measure = rv_view_measure;
  wc->size_allocate = rv_view_size_allocate;
  wc->snapshot = rv_view_snapshot;
  wc->realize = rv_view_realize;
  wc->map = rv_view_map;
  wc->unmap = rv_view_unmap;
  G_OBJECT_CLASS(klass)->dispose = rv_view_dispose;
  gtk_widget_class_set_accessible_role(wc, GTK_ACCESSIBLE_ROLE_GROUP);
  gtk_widget_class_set_css_name(wc, "rv-view");
}

static void rv_view_init(RvView* v) {
  GtkWidget* w = GTK_WIDGET(v);
  v->scale = 1.0;
  v->children = g_ptr_array_new();
  v->touches = g_hash_table_new(g_direct_hash, g_direct_equal);
  gtk_widget_set_focusable(w, TRUE);
  gtk_widget_set_can_focus(w, TRUE);
  gtk_widget_set_hexpand(w, TRUE);
  gtk_widget_set_vexpand(w, TRUE);
  gtk_widget_set_overflow(w, GTK_OVERFLOW_HIDDEN);

  GtkEventController* motion = gtk_event_controller_motion_new();
  g_signal_connect(motion, "enter", G_CALLBACK(motion_enter_cb), v);
  g_signal_connect(motion, "motion", G_CALLBACK(motion_cb), v);
  g_signal_connect(motion, "leave", G_CALLBACK(motion_leave_cb), v);
  gtk_widget_add_controller(w, motion);

  GtkGesture* click = gtk_gesture_click_new();
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
  g_signal_connect(click, "pressed", G_CALLBACK(click_pressed_cb), v);
  g_signal_connect(click, "released", G_CALLBACK(click_released_cb), v);
  g_signal_connect(click, "stopped", G_CALLBACK(click_stopped_cb), v);
  gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(click));

  GtkGesture* drag = gtk_gesture_drag_new();
  gtk_gesture_single_set_touch_only(GTK_GESTURE_SINGLE(drag), TRUE);
  g_signal_connect(drag, "drag-begin", G_CALLBACK(drag_begin_cb), v);
  g_signal_connect(drag, "drag-update", G_CALLBACK(drag_update_cb), v);
  g_signal_connect(drag, "drag-end", G_CALLBACK(drag_end_cb), v);
  g_signal_connect(drag, "cancel", G_CALLBACK(drag_cancel_cb), v);
  gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(drag));

  GtkEventController* scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect(scroll, "scroll-begin", G_CALLBACK(scroll_begin_cb), v);
  g_signal_connect(scroll, "scroll", G_CALLBACK(scroll_cb), v);
  g_signal_connect(scroll, "scroll-end", G_CALLBACK(scroll_end_cb), v);
  gtk_widget_add_controller(w, scroll);

  GtkEventController* key = gtk_event_controller_key_new();
  g_signal_connect(key, "key-pressed", G_CALLBACK(key_pressed_cb), v);
  g_signal_connect(key, "key-released", G_CALLBACK(key_released_cb), v);
  gtk_widget_add_controller(w, key);

  GtkEventController* focus = gtk_event_controller_focus_new();
  g_signal_connect(focus, "enter", G_CALLBACK(focus_enter_cb), v);
  g_signal_connect(focus, "leave", G_CALLBACK(focus_leave_cb), v);
  gtk_widget_add_controller(w, focus);

  g_signal_connect(v, "notify::root", G_CALLBACK(root_changed_cb), v);
  g_signal_connect(v, "notify::scale-factor", G_CALLBACK(scale_changed_cb), v);
}

GtkWidget* rv_view_new(RvEngine* engine) {
  RvView* v = g_object_new(RV_TYPE_VIEW, NULL);
  v->engine = engine;
  g_view = v;
  rv_renderer_set_frame_fn(rv_engine_renderer(engine), frame_ready, v);
  rv_keyboard_init(engine);
  rv_textinput_attach(GTK_WIDGET(v));
  rv_a11y_attach(v);
  return GTK_WIDGET(v);
}

void rv_view_set_cursor(RvView* v, const char* css_name) {
  gtk_widget_set_cursor_from_name(GTK_WIDGET(v), css_name);
}

void rv_view_place_child(RvView* v, GtkWidget* child, int x, int y, int w, int h) {
  ChildRect* r = g_object_get_data(G_OBJECT(child), "rv-rect");
  if (!r) {
    r = g_new0(ChildRect, 1);
    g_object_set_data_full(G_OBJECT(child), "rv-rect", r, g_free);
    gtk_widget_set_parent(child, GTK_WIDGET(v));
    g_ptr_array_add(v->children, child);
  }
  r->x = x;
  r->y = y;
  r->w = w;
  r->h = h;
  gtk_widget_queue_allocate(GTK_WIDGET(v));
}

void rv_view_remove_child(RvView* v, GtkWidget* child) {
  if (g_ptr_array_remove(v->children, child)) gtk_widget_unparent(child);
}
