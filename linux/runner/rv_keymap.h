// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef struct {
  guint32 from;
  guint64 to;
} RvKeyPair;

// XKB (GDK hardware) keycode -> USB HID physical key id as used by Flutter.
guint64 rv_keymap_physical(guint keycode);
// GDK keyval -> Flutter logical key id.
guint64 rv_keymap_logical(guint keyval);

G_END_DECLS
