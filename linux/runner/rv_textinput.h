// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <gtk/gtk.h>

#include "rv_engine.h"

G_BEGIN_DECLS

// Registers the `flutter/textinput` channel and creates the input method.
void rv_textinput_init(RvEngine* engine);
// Binds the input method to the view widget.
void rv_textinput_attach(GtkWidget* view);
// Key events the framework did not handle: input method first, then Enter,
// Home and End.  Returns TRUE if consumed.
gboolean rv_textinput_filter_key(GdkEvent* event);
void rv_textinput_window_focus(gboolean focused);

G_END_DECLS
