// SPDX-License-Identifier: GPL-3.0-or-later
//
// Framework-facing platform channels: flutter/platform, flutter/mousecursor,
// flutter/lifecycle and flutter/settings.
#pragma once

#include <gtk/gtk.h>

#include "rv_engine.h"

G_BEGIN_DECLS

typedef enum {
  RV_LIFECYCLE_HIDDEN,
  RV_LIFECYCLE_INACTIVE,
  RV_LIFECYCLE_RESUMED,
} RvLifecycle;

void rv_platform_init(RvEngine* engine);
// Remembers the state and sends it (if the engine runs).
void rv_platform_set_lifecycle(RvLifecycle state);
// Called once the engine is running: flushes lifecycle and settings.
void rv_platform_engine_started(void);

// flutter/settings: text scale, 24h clock, portal color scheme.
void rv_settings_init(RvEngine* engine);
void rv_settings_send(void);
gboolean rv_settings_is_dark(void);

G_END_DECLS
