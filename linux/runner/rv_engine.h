// SPDX-License-Identifier: GPL-3.0-or-later
//
// Flutter embedder engine wrapper: lifecycle, GLib-main-loop platform task
// runner, platform message routing, window metrics, locales.
#pragma once

#include <gtk/gtk.h>

#include "engine/flutter_embedder.h"
#include "rv_codec.h"
#include "rv_renderer.h"

G_BEGIN_DECLS

typedef struct _RvEngine RvEngine;

typedef void (*RvMessageFn)(RvEngine* engine, GBytes* message,
                            const FlutterPlatformMessageResponseHandle* handle,
                            gpointer user_data);
typedef void (*RvReplyFn)(GBytes* reply, gpointer user_data);  // reply may be NULL
typedef void (*RvSemanticsFn)(const FlutterSemanticsUpdate2* update, gpointer user_data);

RvEngine* rv_engine_new(void);
// Handlers must be registered before rv_engine_run.
void rv_engine_add_handler(RvEngine* e, const char* channel, RvMessageFn fn, gpointer user_data);
// Creates the renderer, starts the engine and sends initial metrics/locales.
gboolean rv_engine_run(RvEngine* e, GError** error);
void rv_engine_shutdown(RvEngine* e);

RvEngine* rv_engine_get(void);  // the process-wide instance (may be NULL)
FlutterEngine rv_engine_raw(RvEngine* e);
RvRenderer* rv_engine_renderer(RvEngine* e);
gboolean rv_engine_is_running(RvEngine* e);

void rv_engine_respond(RvEngine* e, const FlutterPlatformMessageResponseHandle* handle, GBytes* reply);
void rv_engine_respond_empty(RvEngine* e, const FlutterPlatformMessageResponseHandle* handle);
// Sends a message; `cb` (optional) receives the reply on the main thread.
void rv_engine_send(RvEngine* e, const char* channel, GBytes* message, RvReplyFn cb, gpointer user_data);

void rv_engine_set_semantics_fn(RvEngine* e, RvSemanticsFn fn, gpointer user_data);
void rv_engine_send_metrics(RvEngine* e, size_t width_px, size_t height_px, double pixel_ratio);
void rv_engine_send_display(RvEngine* e, double refresh_hz, size_t width_px, size_t height_px, double pixel_ratio);
void rv_engine_update_locales(RvEngine* e);
guint64 rv_engine_now_us(void);

G_END_DECLS
