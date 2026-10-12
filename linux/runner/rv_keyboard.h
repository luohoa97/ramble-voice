// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <gtk/gtk.h>

#include "rv_engine.h"

G_BEGIN_DECLS

void rv_keyboard_init(RvEngine* engine);
// Takes a GDK key press/release event.  Returns TRUE when the event is
// consumed (the result is resolved asynchronously: framework first, then the
// input method).
gboolean rv_keyboard_handle(GdkEvent* event);
// Sends synthesized key-up events for everything still held (focus loss).
void rv_keyboard_release_all(void);

G_END_DECLS
