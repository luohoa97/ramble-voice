// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_overlay.h"

#include <math.h>
#include <pango/pangocairo.h>

#ifdef HAVE_LAYER_SHELL
#include <gtk4-layer-shell.h>
#endif

#define kWidth 220
#define kHeight 56
#define kBars 7

static struct {
  GtkWidget* window;
  GtkWidget* area;
  RvOverlayState state;
  double level;       // target
  double shown;       // smoothed
  char* text;
  guint tick;
  gint64 started_us;
  double bars[kBars];
} O;

static void rounded_rect(cairo_t* cr, double x, double y, double w, double h, double r) {
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
  cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
  cairo_close_path(cr);
}

static void draw_cb(GtkDrawingArea* area, cairo_t* cr, int w, int h, gpointer data) {
  (void)area;
  (void)data;
  double t = (g_get_monotonic_time() - O.started_us) / 1e6;

  // Graphite surface with a hairline border.
  rounded_rect(cr, 0.5, 0.5, w - 1, h - 1, (h - 1) / 2.0);
  cairo_set_source_rgba(cr, 0x1e / 255.0, 0x1c / 255.0, 0x1a / 255.0, 0.96);
  cairo_fill_preserve(cr);
  cairo_set_source_rgba(cr, 1, 1, 1, 0.09);
  cairo_set_line_width(cr, 1);
  cairo_stroke(cr);

  // Accent per state.
  double ar = 0xe5 / 255.0, ag = 0x48 / 255.0, ab = 0x2d / 255.0;  // vermilion
  const char* label = O.text && *O.text ? O.text : "";
  if (O.state == RV_OVERLAY_LISTENING) {
    if (!*label) label = "Listening";
  } else if (O.state == RV_OVERLAY_PROCESSING) {
    ar = 0.86; ag = 0.80; ab = 0.70;
    if (!*label) label = "Cleaning up";
  } else if (O.state == RV_OVERLAY_ERROR) {
    ar = 1.0; ag = 0.42; ab = 0.38;
    if (!*label) label = "Something went wrong";
  }

  // Status dot (pulses while listening/processing).
  double pulse = O.state == RV_OVERLAY_ERROR ? 1.0 : 0.65 + 0.35 * sin(t * (O.state == RV_OVERLAY_PROCESSING ? 6.0 : 3.5));
  cairo_set_source_rgba(cr, ar, ag, ab, 0.25 * pulse);
  cairo_arc(cr, 26, h / 2.0, 9, 0, 2 * G_PI);
  cairo_fill(cr);
  cairo_set_source_rgba(cr, ar, ag, ab, 1);
  cairo_arc(cr, 26, h / 2.0, 5, 0, 2 * G_PI);
  cairo_fill(cr);

  // Label.
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* fd = pango_font_description_from_string("Sans 11");
  pango_layout_set_font_description(layout, fd);
  pango_font_description_free(fd);
  pango_layout_set_text(layout, label, -1);
  int meter_w = O.state == RV_OVERLAY_LISTENING ? 44 : 0;
  pango_layout_set_width(layout, (w - 48 - meter_w - 18) * PANGO_SCALE);
  pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  int tw, th;
  pango_layout_get_pixel_size(layout, &tw, &th);
  cairo_set_source_rgba(cr, 0.95, 0.94, 0.92, 1);
  cairo_move_to(cr, 44, (h - th) / 2.0);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);

  // Level meter.
  if (O.state == RV_OVERLAY_LISTENING) {
    double x0 = w - 18 - meter_w, bw = 4, gap = 2;
    for (int i = 0; i < kBars; i++) {
      double bh = 4 + O.bars[i] * (h - 24);
      cairo_set_source_rgba(cr, ar, ag, ab, 0.55 + 0.45 * O.bars[i]);
      rounded_rect(cr, x0 + i * (bw + gap), (h - bh) / 2.0, bw, bh, 2);
      cairo_fill(cr);
    }
  }
}

static gboolean tick_cb(GtkWidget* w, GdkFrameClock* clock, gpointer data) {
  (void)clock;
  (void)data;
  O.shown += (O.level - O.shown) * 0.35;
  double t = (g_get_monotonic_time() - O.started_us) / 1e6;
  for (int i = 0; i < kBars; i++) {
    double wobble = 0.5 + 0.5 * sin(t * (5.0 + i * 1.3) + i);
    double target = O.state == RV_OVERLAY_LISTENING ? CLAMP(O.shown * (0.35 + 0.65 * wobble), 0, 1) : 0;
    O.bars[i] += (target - O.bars[i]) * 0.4;
  }
  gtk_widget_queue_draw(w);
  return G_SOURCE_CONTINUE;
}

G_GNUC_UNUSED static gboolean rv_is_wayland(GdkDisplay* d) {
  return g_str_has_prefix(G_OBJECT_TYPE_NAME(d), "GdkWayland");
}

static gboolean can_show(void) {
#ifdef HAVE_LAYER_SHELL
  GdkDisplay* d = gdk_display_get_default();
  return d && rv_is_wayland(d) && gtk_layer_is_supported();
#else
  return FALSE;
#endif
}

static void ensure_window(void) {
#ifdef HAVE_LAYER_SHELL
  if (O.window) return;
  O.window = gtk_window_new();
  gtk_window_set_decorated(GTK_WINDOW(O.window), FALSE);
  gtk_window_set_resizable(GTK_WINDOW(O.window), FALSE);
  gtk_window_set_default_size(GTK_WINDOW(O.window), kWidth, kHeight);
  gtk_widget_set_focusable(O.window, FALSE);
  gtk_widget_set_can_target(O.window, FALSE);
  gtk_widget_add_css_class(O.window, "rv-overlay");
  static GtkCssProvider* css;
  if (!css) {
    css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, "window.rv-overlay { background: transparent; box-shadow: none; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }
  gtk_layer_init_for_window(GTK_WINDOW(O.window));
  gtk_layer_set_namespace(GTK_WINDOW(O.window), "ramble-voice-overlay");
  gtk_layer_set_layer(GTK_WINDOW(O.window), GTK_LAYER_SHELL_LAYER_OVERLAY);
  gtk_layer_set_anchor(GTK_WINDOW(O.window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
  gtk_layer_set_margin(GTK_WINDOW(O.window), GTK_LAYER_SHELL_EDGE_BOTTOM, 48);
  gtk_layer_set_keyboard_mode(GTK_WINDOW(O.window), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
  gtk_layer_set_exclusive_zone(GTK_WINDOW(O.window), -1);

  O.area = gtk_drawing_area_new();
  gtk_widget_set_size_request(O.area, kWidth, kHeight);
  gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(O.area), kWidth);
  gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(O.area), kHeight);
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(O.area), draw_cb, NULL, NULL);
  gtk_window_set_child(GTK_WINDOW(O.window), O.area);
#endif
}

gboolean rv_overlay_set_state(RvOverlayState state, double level, const char* text) {
  if (state == RV_OVERLAY_IDLE) {
    if (O.window) {
      if (O.tick) gtk_widget_remove_tick_callback(O.area, O.tick);
      O.tick = 0;
      gtk_widget_set_visible(O.window, FALSE);
    }
    O.state = state;
    return can_show();
  }
  if (!can_show()) return FALSE;
  ensure_window();
  if (!O.window) return FALSE;
  gboolean changed = O.state != state;
  O.state = state;
  O.level = CLAMP(level, 0, 1);
  if (changed || g_strcmp0(O.text, text) != 0) {
    g_free(O.text);
    O.text = g_strdup(text);
  }
  if (!gtk_widget_get_visible(O.window)) {
    O.started_us = g_get_monotonic_time();
    gtk_window_present(GTK_WINDOW(O.window));
  }
  if (!O.tick) O.tick = gtk_widget_add_tick_callback(O.area, tick_cb, NULL, NULL);
  gtk_widget_queue_draw(O.area);
  return TRUE;
}

void rv_overlay_destroy(void) {
  if (O.window) gtk_window_destroy(GTK_WINDOW(O.window));
  O.window = NULL;
  O.area = NULL;
  O.tick = 0;
}
