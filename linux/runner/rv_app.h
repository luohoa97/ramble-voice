// SPDX-License-Identifier: GPL-3.0-or-later
//
// GtkApplication: single instance, command line forwarding, window, and the
// ramble/window, ramble/overlay and ramble/cli channels.
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

GtkApplication* rv_app_new(void);
void rv_app_navigator_pop(void);        // SystemNavigator.pop
void rv_app_set_title(const char* title);
void rv_app_quit(void);
void rv_app_notify_frame(void);         // a frame reached the view

G_END_DECLS
