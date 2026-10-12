// SPDX-License-Identifier: GPL-3.0-or-later
//
// flutter/settings: text scale factor, 24h clock and platform brightness.
// Brightness comes from the org.freedesktop.appearance color-scheme portal
// setting (live updates through SettingChanged), falling back to GTK.
#include <gio/gio.h>
#include <gtk/gtk.h>
#include <string.h>

#include "rv_platform.h"

static RvEngine* g_engine;
static GDBusProxy* g_portal;
static GSettings* g_gnome;
static int g_scheme = 0;  // portal: 0 no preference, 1 dark, 2 light
static gboolean g_have_portal_value;

static gboolean fallback_dark(void) {
  GtkSettings* s = gtk_settings_get_default();
  if (!s) return FALSE;
  gboolean prefer = FALSE;
  g_autofree char* theme = NULL;
  g_object_get(s, "gtk-application-prefer-dark-theme", &prefer, "gtk-theme-name", &theme, NULL);
  if (prefer) return TRUE;
  return theme && (g_str_has_suffix(theme, "-dark") || g_str_has_suffix(theme, "-Dark") ||
                   strstr(theme, "dark") != NULL);
}

gboolean rv_settings_is_dark(void) {
  if (g_have_portal_value && g_scheme != 0) return g_scheme == 1;
  if (g_gnome) {
    g_autofree char* cs = g_settings_get_string(g_gnome, "color-scheme");
    if (cs && !strcmp(cs, "prefer-dark")) return TRUE;
    if (cs && !strcmp(cs, "prefer-light")) return FALSE;
  }
  return fallback_dark();
}

void rv_settings_send(void) {
  if (!rv_engine_is_running(g_engine)) return;
  double scale = 1.0;
  gboolean h24 = TRUE;
  if (g_gnome) {
    scale = g_settings_get_double(g_gnome, "text-scaling-factor");
    if (scale < 0.5 || scale > 3.0) scale = 1.0;
    g_autofree char* fmt = g_settings_get_string(g_gnome, "clock-format");
    h24 = !fmt || strcmp(fmt, "12h") != 0;
  }
  gboolean dark = rv_settings_is_dark();
  GtkSettings* gs = gtk_settings_get_default();
  if (gs) g_object_set(gs, "gtk-application-prefer-dark-theme", dark, NULL);
  GBytes* msg = rv_json_encode(rv_map("textScaleFactor", rv_dbl(scale), "alwaysUse24HourFormat", rv_bool(h24),
                                      "platformBrightness", rv_str(dark ? "dark" : "light"), NULL));
  rv_engine_send(g_engine, "flutter/settings", msg, NULL, NULL);
}

static GVariant* unwrap(GVariant* v) {
  GVariant* cur = g_variant_ref(v);
  while (g_variant_is_of_type(cur, G_VARIANT_TYPE_VARIANT)) {
    GVariant* next = g_variant_get_variant(cur);
    g_variant_unref(cur);
    cur = next;
  }
  return cur;
}

static void apply_scheme(GVariant* v) {
  g_autoptr(GVariant) u = unwrap(v);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_UINT32)) {
    g_scheme = g_variant_get_uint32(u);
    g_have_portal_value = TRUE;
  }
}

static void portal_signal_cb(GDBusProxy* proxy, const char* sender, const char* signal, GVariant* params, gpointer d) {
  (void)proxy;
  (void)sender;
  (void)d;
  if (strcmp(signal, "SettingChanged") != 0) return;
  const char *ns, *key;
  g_autoptr(GVariant) value = NULL;
  g_variant_get(params, "(&s&sv)", &ns, &key, &value);
  if (strcmp(ns, "org.freedesktop.appearance") != 0 || strcmp(key, "color-scheme") != 0) return;
  apply_scheme(value);
  rv_settings_send();
}

static void portal_read_cb(GObject* src, GAsyncResult* res, gpointer d) {
  (void)d;
  g_autoptr(GVariant) ret = g_dbus_proxy_call_finish(G_DBUS_PROXY(src), res, NULL);
  if (!ret) return;
  g_autoptr(GVariant) v = g_variant_get_child_value(ret, 0);
  apply_scheme(v);
  rv_settings_send();
}

static void portal_ready_cb(GObject* src, GAsyncResult* res, gpointer d) {
  (void)src;
  (void)d;
  g_portal = g_dbus_proxy_new_for_bus_finish(res, NULL);
  if (!g_portal) return;
  g_signal_connect(g_portal, "g-signal", G_CALLBACK(portal_signal_cb), NULL);
  g_dbus_proxy_call(g_portal, "Read", g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
                    G_DBUS_CALL_FLAGS_NONE, 2000, NULL, portal_read_cb, NULL);
}

static void gsettings_changed_cb(GSettings* s, const char* key, gpointer d) {
  (void)s;
  (void)key;
  (void)d;
  rv_settings_send();
}

static void gtk_theme_changed_cb(GObject* o, GParamSpec* p, gpointer d) {
  (void)o;
  (void)p;
  (void)d;
  if (!g_have_portal_value) rv_settings_send();
}

void rv_settings_init(RvEngine* engine) {
  g_engine = engine;
  GSettingsSchemaSource* src = g_settings_schema_source_get_default();
  if (src) {
    GSettingsSchema* schema = g_settings_schema_source_lookup(src, "org.gnome.desktop.interface", TRUE);
    if (schema) {
      g_gnome = g_settings_new("org.gnome.desktop.interface");
      g_signal_connect(g_gnome, "changed", G_CALLBACK(gsettings_changed_cb), NULL);
      g_settings_schema_unref(schema);
    }
  }
  GtkSettings* gs = gtk_settings_get_default();
  if (gs) g_signal_connect(gs, "notify::gtk-theme-name", G_CALLBACK(gtk_theme_changed_cb), NULL);
  g_dbus_proxy_new_for_bus(G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_NONE, NULL, "org.freedesktop.portal.Desktop",
                           "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", NULL,
                           portal_ready_cb, NULL);
}
