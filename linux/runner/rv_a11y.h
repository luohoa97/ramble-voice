// SPDX-License-Identifier: GPL-3.0-or-later
//
// Flutter semantics -> GTK accessibility.  Every semantics node with
// something to expose gets an invisible proxy widget inside the view so the
// AT-SPI bridge of GTK publishes names, roles and states; actions on the
// proxy are forwarded to FlutterEngineDispatchSemanticsAction.
#pragma once

#include "rv_engine.h"
#include "rv_view.h"

G_BEGIN_DECLS

void rv_a11y_init(RvEngine* engine);
void rv_a11y_attach(RvView* view);
void rv_a11y_engine_started(void);

G_END_DECLS
