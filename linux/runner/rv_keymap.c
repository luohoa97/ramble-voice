// SPDX-License-Identifier: GPL-3.0-or-later
//
// Key tables and lookup rules ported from Flutter's GTK shell
// (shell/platform/linux/fl_key_mapping.g.cc, fl_key_embedder_responder.cc).
// Copyright 2013 The Flutter Authors. BSD-3-Clause; see linux/THIRD_PARTY.md.
#include "rv_keymap.h"

#include <stdlib.h>

#include "rv_keymap_tables.inc"

static const guint64 kValueMask = 0x000ffffffffULL;
static const guint64 kUnicodePlane = 0x00000000000ULL;
static const guint64 kGtkPlane = 0x01500000000ULL;

static int cmp(const void* a, const void* b) {
  guint32 k = *(const guint32*)a;
  const RvKeyPair* p = b;
  return k < p->from ? -1 : (k > p->from ? 1 : 0);
}

static const RvKeyPair* find(const RvKeyPair* table, size_t n, guint32 key) {
  return bsearch(&key, table, n, sizeof(RvKeyPair), cmp);
}

guint64 rv_keymap_physical(guint keycode) {
  const RvKeyPair* p = find(rv_xkb_to_physical, G_N_ELEMENTS(rv_xkb_to_physical), keycode);
  if (p) return p->to;
  return ((guint64)keycode & kValueMask) | kGtkPlane;
}

guint64 rv_keymap_logical(guint keyval) {
  const RvKeyPair* p = find(rv_keyval_to_logical, G_N_ELEMENTS(rv_keyval_to_logical), keyval);
  if (p) return p->to;
  if (keyval < 256) {
    guint lower = (keyval >= 'A' && keyval <= 'Z') ? keyval + 32 : keyval;
    return ((guint64)lower & kValueMask) | kUnicodePlane;
  }
  return ((guint64)keyval & kValueMask) | kGtkPlane;
}
