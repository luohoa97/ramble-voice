// SPDX-License-Identifier: GPL-3.0-or-later
//
// GTK4 widget that displays the Flutter frame and feeds pointer, scroll,
// keyboard and focus input to the engine.
#pragma once

#include <gtk/gtk.h>

#include "rv_engine.h"

G_BEGIN_DECLS

#define RV_TYPE_VIEW (rv_view_get_type())
G_DECLARE_FINAL_TYPE(RvView, rv_view, RV, VIEW, GtkWidget)

GtkWidget* rv_view_new(RvEngine* engine);
RvView* rv_view_get(void);  // the single view (may be NULL)
double rv_view_get_scale(RvView* view);
void rv_view_set_cursor(RvView* view, const char* css_name);

// Child widgets (accessibility proxies) positioned in view coordinates.
void rv_view_place_child(RvView* view, GtkWidget* child, int x, int y, int w, int h);
void rv_view_remove_child(RvView* view, GtkWidget* child);

G_END_DECLS
