// SPDX-License-Identifier: GPL-3.0-or-later
//
// Flutter message codecs (standard + JSON) over GVariant.
//
// Dynamic values are plain GVariants: null is the unit tuple "()", bool "b",
// integers "x", doubles "d", strings "s", byte lists "ay", int/double lists
// "ax"/"ad", lists "av" and maps "a{sv}".  Containers hold boxed children.
#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

// Constructors (return floating references).
GVariant* rv_null(void);
GVariant* rv_str(const char* s);
GVariant* rv_int(gint64 v);
GVariant* rv_dbl(double v);
GVariant* rv_bool(gboolean v);
// rv_list(a, b, ..., NULL): takes ownership of the (floating) arguments.
GVariant* rv_list(GVariant* first, ...) G_GNUC_NULL_TERMINATED;
// rv_map("k", v, "k2", v2, ..., NULL)
GVariant* rv_map(const char* first_key, ...) G_GNUC_NULL_TERMINATED;
GVariant* rv_list_from_array(GPtrArray* items);  // consumes the floating items

// Accessors.  All tolerate NULL and return a default on type mismatch.
gboolean rv_is_null(GVariant* v);
gboolean rv_is_map(GVariant* v);
gboolean rv_is_list(GVariant* v);
GVariant* rv_map_get(GVariant* map, const char* key);  // new ref or NULL
GVariant* rv_list_get(GVariant* list, gsize index);    // new ref or NULL
gsize rv_list_len(GVariant* list);
const char* rv_as_str(GVariant* v, const char* def);  // valid while v is alive
gint64 rv_as_int(GVariant* v, gint64 def);
double rv_as_double(GVariant* v, double def);
gboolean rv_as_bool(GVariant* v, gboolean def);

// Convenience: look up a key and convert.
const char* rv_map_str(GVariant* map, const char* key, const char* def);
gint64 rv_map_int(GVariant* map, const char* key, gint64 def);
double rv_map_double(GVariant* map, const char* key, double def);
gboolean rv_map_bool(GVariant* map, const char* key, gboolean def);

// Standard codecs.
GBytes* rv_std_encode(GVariant* value);
GVariant* rv_std_decode(const guint8* data, gsize len);  // floating, or NULL
// Method calls: *method is newly allocated, *args a new ref (never NULL).
gboolean rv_std_decode_call(GBytes* msg, char** method, GVariant** args);
GBytes* rv_std_success(GVariant* result);  // result may be NULL (= null)
GBytes* rv_std_error(const char* code, const char* message);
GBytes* rv_std_method_call(const char* method, GVariant* args);  // args may be NULL

// JSON codecs.
GBytes* rv_json_encode(GVariant* value);
GVariant* rv_json_decode(const guint8* data, gsize len);  // floating, or NULL
gboolean rv_json_decode_call(GBytes* msg, char** method, GVariant** args);
GBytes* rv_json_success(GVariant* result);
GBytes* rv_json_error(const char* code, const char* message);
GBytes* rv_json_method_call(const char* method, GVariant* args);

// Raw strings (flutter/lifecycle and similar).
GBytes* rv_string_bytes(const char* s);

G_END_DECLS
