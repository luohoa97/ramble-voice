// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dictation indicator: a small GTK/Cairo pill shown above everything else
// without taking focus.  Wayland compositors with wlr-layer-shell only.
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef enum {
  RV_OVERLAY_IDLE,
  RV_OVERLAY_LISTENING,
  RV_OVERLAY_PROCESSING,
  RV_OVERLAY_ERROR,
} RvOverlayState;

// Returns FALSE when no focus-less overlay can be shown on this session.
gboolean rv_overlay_set_state(RvOverlayState state, double level, const char* text);
void rv_overlay_destroy(void);

G_END_DECLS
