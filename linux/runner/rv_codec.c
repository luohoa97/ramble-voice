// SPDX-License-Identifier: GPL-3.0-or-later
#include "rv_codec.h"

#include <math.h>
#include <string.h>

// ---------------------------------------------------------------- builders

GVariant* rv_null(void) { return g_variant_new_tuple(NULL, 0); }
GVariant* rv_str(const char* s) { return g_variant_new_string(s ? s : ""); }
GVariant* rv_int(gint64 v) { return g_variant_new_int64(v); }
GVariant* rv_dbl(double v) { return g_variant_new_double(v); }
GVariant* rv_bool(gboolean v) { return g_variant_new_boolean(v); }

GVariant* rv_list_from_array(GPtrArray* items) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("av"));
  for (guint i = 0; i < items->len; i++)
    g_variant_builder_add_value(&b, g_variant_new_variant(g_ptr_array_index(items, i)));
  return g_variant_builder_end(&b);
}

GVariant* rv_list(GVariant* first, ...) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("av"));
  va_list ap;
  va_start(ap, first);
  for (GVariant* v = first; v; v = va_arg(ap, GVariant*))
    g_variant_builder_add_value(&b, g_variant_new_variant(v));
  va_end(ap);
  return g_variant_builder_end(&b);
}

GVariant* rv_map(const char* first_key, ...) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  va_list ap;
  va_start(ap, first_key);
  for (const char* k = first_key; k; k = va_arg(ap, const char*)) {
    GVariant* v = va_arg(ap, GVariant*);
    g_variant_builder_add(&b, "{sv}", k, v);
  }
  va_end(ap);
  return g_variant_builder_end(&b);
}

// --------------------------------------------------------------- accessors

static GVariant* unbox(GVariant* v) {
  // Returns a borrowed-or-new reference semantics-free helper: always new ref.
  if (!v) return NULL;
  if (g_variant_is_of_type(v, G_VARIANT_TYPE_VARIANT)) return g_variant_get_variant(v);
  return g_variant_ref(v);
}

gboolean rv_is_null(GVariant* v) {
  if (!v) return TRUE;
  g_autoptr(GVariant) u = unbox(v);
  return g_variant_is_of_type(u, G_VARIANT_TYPE_UNIT);
}

gboolean rv_is_map(GVariant* v) {
  if (!v) return FALSE;
  g_autoptr(GVariant) u = unbox(v);
  return g_variant_is_of_type(u, G_VARIANT_TYPE("a{sv}"));
}

gboolean rv_is_list(GVariant* v) {
  if (!v) return FALSE;
  g_autoptr(GVariant) u = unbox(v);
  return g_variant_is_of_type(u, G_VARIANT_TYPE("av")) ||
         g_variant_is_of_type(u, G_VARIANT_TYPE("ax")) ||
         g_variant_is_of_type(u, G_VARIANT_TYPE("ad"));
}

GVariant* rv_map_get(GVariant* map, const char* key) {
  if (!rv_is_map(map)) return NULL;
  g_autoptr(GVariant) m = unbox(map);
  GVariantIter it;
  g_variant_iter_init(&it, m);
  const char* k;
  GVariant* v;
  while (g_variant_iter_next(&it, "{&sv}", &k, &v)) {
    if (strcmp(k, key) == 0) return v;
    g_variant_unref(v);
  }
  return NULL;
}

gsize rv_list_len(GVariant* list) {
  if (!rv_is_list(list)) return 0;
  g_autoptr(GVariant) l = unbox(list);
  return g_variant_n_children(l);
}

GVariant* rv_list_get(GVariant* list, gsize index) {
  if (index >= rv_list_len(list)) return NULL;
  g_autoptr(GVariant) l = unbox(list);
  g_autoptr(GVariant) c = g_variant_get_child_value(l, index);
  if (g_variant_is_of_type(c, G_VARIANT_TYPE_VARIANT)) return g_variant_get_variant(c);
  return g_steal_pointer(&c);
}

const char* rv_as_str(GVariant* v, const char* def) {
  // The string pointer stays valid as long as the (possibly boxed) variant
  // that owns it; unboxing returns a view into the same storage.
  if (!v) return def;
  GVariant* u = v;
  g_autoptr(GVariant) holder = NULL;
  if (g_variant_is_of_type(v, G_VARIANT_TYPE_VARIANT)) {
    holder = g_variant_get_variant(v);
    u = holder;
  }
  if (!g_variant_is_of_type(u, G_VARIANT_TYPE_STRING)) return def;
  return g_variant_get_string(u, NULL);
}

gint64 rv_as_int(GVariant* v, gint64 def) {
  g_autoptr(GVariant) u = unbox(v);
  if (!u) return def;
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT64)) return g_variant_get_int64(u);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT32)) return g_variant_get_int32(u);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_DOUBLE)) return (gint64)g_variant_get_double(u);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_BOOLEAN)) return g_variant_get_boolean(u);
  return def;
}

double rv_as_double(GVariant* v, double def) {
  g_autoptr(GVariant) u = unbox(v);
  if (!u) return def;
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_DOUBLE)) return g_variant_get_double(u);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT64)) return (double)g_variant_get_int64(u);
  if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT32)) return g_variant_get_int32(u);
  return def;
}

gboolean rv_as_bool(GVariant* v, gboolean def) {
  g_autoptr(GVariant) u = unbox(v);
  if (!u || !g_variant_is_of_type(u, G_VARIANT_TYPE_BOOLEAN)) return def;
  return g_variant_get_boolean(u);
}

// The string accessor needs the value to outlive the call; the returned
// pointer references storage owned by the parent map, which the caller holds.
const char* rv_map_str(GVariant* map, const char* key, const char* def) {
  if (!rv_is_map(map)) return def;
  g_autoptr(GVariant) m = unbox(map);
  GVariantIter it;
  g_variant_iter_init(&it, m);
  GVariant* kv;
  while ((kv = g_variant_iter_next_value(&it))) {
    g_autoptr(GVariant) k = g_variant_get_child_value(kv, 0);
    if (strcmp(g_variant_get_string(k, NULL), key) == 0) {
      g_autoptr(GVariant) v = g_variant_get_child_value(kv, 1);
      g_autoptr(GVariant) vv = unbox(v);
      const char* s = g_variant_is_of_type(vv, G_VARIANT_TYPE_STRING)
                          ? g_variant_get_string(vv, NULL) : def;
      g_variant_unref(kv);
      return s;  // storage is owned by the caller's map
    }
    g_variant_unref(kv);
  }
  return def;
}

gint64 rv_map_int(GVariant* map, const char* key, gint64 def) {
  g_autoptr(GVariant) v = rv_map_get(map, key);
  return rv_as_int(v, def);
}
double rv_map_double(GVariant* map, const char* key, double def) {
  g_autoptr(GVariant) v = rv_map_get(map, key);
  return rv_as_double(v, def);
}
gboolean rv_map_bool(GVariant* map, const char* key, gboolean def) {
  g_autoptr(GVariant) v = rv_map_get(map, key);
  return rv_as_bool(v, def);
}

// --------------------------------------------------------------- standard

static void put_size(GByteArray* a, gsize n) {
  if (n < 254) {
    guint8 b = n;
    g_byte_array_append(a, &b, 1);
  } else if (n <= 0xffff) {
    guint8 b[3] = {254, n & 0xff, (n >> 8) & 0xff};
    g_byte_array_append(a, b, 3);
  } else {
    guint8 b[5] = {255, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff};
    g_byte_array_append(a, b, 5);
  }
}

static void align_to(GByteArray* a, guint n) {
  while (a->len % n) {
    guint8 z = 0;
    g_byte_array_append(a, &z, 1);
  }
}

static void std_write(GByteArray* a, GVariant* v) {
  g_autoptr(GVariant) u = unbox(v);
  guint8 tag;
  if (!u || g_variant_is_of_type(u, G_VARIANT_TYPE_UNIT)) {
    tag = 0;
    g_byte_array_append(a, &tag, 1);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_BOOLEAN)) {
    tag = g_variant_get_boolean(u) ? 1 : 2;
    g_byte_array_append(a, &tag, 1);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT32) ||
             g_variant_is_of_type(u, G_VARIANT_TYPE_INT64)) {
    gint64 n = rv_as_int(u, 0);
    if (n >= G_MININT32 && n <= G_MAXINT32) {
      tag = 3;
      g_byte_array_append(a, &tag, 1);
      gint32 i = (gint32)n;
      i = GINT32_TO_LE(i);
      g_byte_array_append(a, (guint8*)&i, 4);
    } else {
      tag = 4;
      g_byte_array_append(a, &tag, 1);
      n = GINT64_TO_LE(n);
      g_byte_array_append(a, (guint8*)&n, 8);
    }
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_DOUBLE)) {
    tag = 6;  // Float64 in the standard codec
    g_byte_array_append(a, &tag, 1);
    align_to(a, 8);
    double d = g_variant_get_double(u);
    g_byte_array_append(a, (guint8*)&d, 8);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_STRING)) {
    tag = 7;
    g_byte_array_append(a, &tag, 1);
    const char* s = g_variant_get_string(u, NULL);
    put_size(a, strlen(s));
    g_byte_array_append(a, (const guint8*)s, strlen(s));
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("ay"))) {
    tag = 8;
    g_byte_array_append(a, &tag, 1);
    gsize n;
    const guint8* d = g_variant_get_fixed_array(u, &n, 1);
    put_size(a, n);
    g_byte_array_append(a, d, n);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("av"))) {
    tag = 12;
    g_byte_array_append(a, &tag, 1);
    gsize n = g_variant_n_children(u);
    put_size(a, n);
    for (gsize i = 0; i < n; i++) {
      g_autoptr(GVariant) c = g_variant_get_child_value(u, i);
      std_write(a, c);
    }
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("ax"))) {
    tag = 10;
    g_byte_array_append(a, &tag, 1);
    gsize n;
    const gint64* d = g_variant_get_fixed_array(u, &n, 8);
    put_size(a, n);
    align_to(a, 8);
    g_byte_array_append(a, (const guint8*)d, n * 8);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("ad"))) {
    tag = 11;
    g_byte_array_append(a, &tag, 1);
    gsize n;
    const double* d = g_variant_get_fixed_array(u, &n, 8);
    put_size(a, n);
    align_to(a, 8);
    g_byte_array_append(a, (const guint8*)d, n * 8);
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("a{sv}"))) {
    tag = 13;
    g_byte_array_append(a, &tag, 1);
    gsize n = g_variant_n_children(u);
    put_size(a, n);
    for (gsize i = 0; i < n; i++) {
      g_autoptr(GVariant) e = g_variant_get_child_value(u, i);
      g_autoptr(GVariant) k = g_variant_get_child_value(e, 0);
      g_autoptr(GVariant) val = g_variant_get_child_value(e, 1);
      std_write(a, k);  // keys are strings
      std_write(a, val);
    }
  } else {
    tag = 0;
    g_byte_array_append(a, &tag, 1);
  }
}

GBytes* rv_std_encode(GVariant* value) {
  g_autoptr(GVariant) v = value ? g_variant_ref_sink(value) : NULL;
  GByteArray* a = g_byte_array_new();
  std_write(a, v ? v : g_variant_new_tuple(NULL, 0));
  return g_byte_array_free_to_bytes(a);
}

typedef struct {
  const guint8* d;
  gsize len, pos;
  gboolean bad;
} Reader;

static gboolean need(Reader* r, gsize n) {
  if (r->bad || r->pos + n > r->len) {
    r->bad = TRUE;
    return FALSE;
  }
  return TRUE;
}

static gsize get_size(Reader* r) {
  if (!need(r, 1)) return 0;
  guint8 b = r->d[r->pos++];
  if (b < 254) return b;
  if (b == 254) {
    if (!need(r, 2)) return 0;
    gsize n = r->d[r->pos] | (r->d[r->pos + 1] << 8);
    r->pos += 2;
    return n;
  }
  if (!need(r, 4)) return 0;
  gsize n = r->d[r->pos] | (r->d[r->pos + 1] << 8) | (r->d[r->pos + 2] << 16) |
            ((gsize)r->d[r->pos + 3] << 24);
  r->pos += 4;
  return n;
}

static void r_align(Reader* r, gsize n) {
  while (r->pos % n) r->pos++;
}

static GVariant* std_read(Reader* r, int depth) {
  if (depth > 64 || !need(r, 1)) {
    r->bad = TRUE;
    return NULL;
  }
  guint8 tag = r->d[r->pos++];
  switch (tag) {
    case 0: return rv_null();
    case 1: return rv_bool(TRUE);
    case 2: return rv_bool(FALSE);
    case 3: {
      if (!need(r, 4)) return NULL;
      gint32 i;
      memcpy(&i, r->d + r->pos, 4);
      r->pos += 4;
      return rv_int(GINT32_FROM_LE(i));
    }
    case 4: {
      if (!need(r, 8)) return NULL;
      gint64 i;
      memcpy(&i, r->d + r->pos, 8);
      r->pos += 8;
      return rv_int(GINT64_FROM_LE(i));
    }
    case 6: {
      r_align(r, 8);
      if (!need(r, 8)) return NULL;
      double d;
      memcpy(&d, r->d + r->pos, 8);
      r->pos += 8;
      return rv_dbl(d);
    }
    case 5:  // large int as string
    case 7: {
      gsize n = get_size(r);
      if (!need(r, n)) return NULL;
      g_autofree char* s = g_strndup((const char*)r->d + r->pos, n);
      r->pos += n;
      return rv_str(s);
    }
    case 8: {
      gsize n = get_size(r);
      if (!need(r, n)) return NULL;
      GVariant* v = g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, r->d + r->pos, n, 1);
      r->pos += n;
      return v;
    }
    case 9: {  // int32 list -> ax
      gsize n = get_size(r);
      r_align(r, 4);
      if (!need(r, n * 4)) return NULL;
      GVariantBuilder b;
      g_variant_builder_init(&b, G_VARIANT_TYPE("ax"));
      for (gsize i = 0; i < n; i++) {
        gint32 x;
        memcpy(&x, r->d + r->pos + i * 4, 4);
        g_variant_builder_add(&b, "x", (gint64)GINT32_FROM_LE(x));
      }
      r->pos += n * 4;
      return g_variant_builder_end(&b);
    }
    case 10: {
      gsize n = get_size(r);
      r_align(r, 8);
      if (!need(r, n * 8)) return NULL;
      GVariant* v = g_variant_new_fixed_array(G_VARIANT_TYPE_INT64, r->d + r->pos, n, 8);
      r->pos += n * 8;
      return v;
    }
    case 11: {
      gsize n = get_size(r);
      r_align(r, 8);
      if (!need(r, n * 8)) return NULL;
      GVariant* v = g_variant_new_fixed_array(G_VARIANT_TYPE_DOUBLE, r->d + r->pos, n, 8);
      r->pos += n * 8;
      return v;
    }
    case 14: {  // float32 list -> ad
      gsize n = get_size(r);
      r_align(r, 4);
      if (!need(r, n * 4)) return NULL;
      GVariantBuilder b;
      g_variant_builder_init(&b, G_VARIANT_TYPE("ad"));
      for (gsize i = 0; i < n; i++) {
        float x;
        memcpy(&x, r->d + r->pos + i * 4, 4);
        g_variant_builder_add(&b, "d", (double)x);
      }
      r->pos += n * 4;
      return g_variant_builder_end(&b);
    }
    case 12: {
      gsize n = get_size(r);
      GPtrArray* items = g_ptr_array_new();
      for (gsize i = 0; i < n && !r->bad; i++) {
        GVariant* c = std_read(r, depth + 1);
        if (!c) break;
        g_ptr_array_add(items, c);
      }
      GVariant* out;
      if (r->bad) {
        for (guint i = 0; i < items->len; i++) g_variant_unref(g_variant_ref_sink(g_ptr_array_index(items, i)));
        out = NULL;
      } else {
        out = rv_list_from_array(items);
      }
      g_ptr_array_free(items, TRUE);
      return out;
    }
    case 13: {
      gsize n = get_size(r);
      GVariantBuilder b;
      g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
      for (gsize i = 0; i < n && !r->bad; i++) {
        GVariant* k = std_read(r, depth + 1);
        GVariant* v = k ? std_read(r, depth + 1) : NULL;
        if (!k || !v) {
          if (k) g_variant_unref(g_variant_ref_sink(k));
          r->bad = TRUE;
          break;
        }
        g_variant_ref_sink(k);
        g_autofree char* key = g_variant_is_of_type(k, G_VARIANT_TYPE_STRING)
                                   ? g_strdup(g_variant_get_string(k, NULL))
                                   : g_strdup_printf("%" G_GINT64_FORMAT, rv_as_int(k, 0));
        g_variant_unref(k);
        g_variant_builder_add(&b, "{sv}", key, v);
      }
      if (r->bad) {
        g_variant_builder_clear(&b);
        return NULL;
      }
      return g_variant_builder_end(&b);
    }
    default:
      r->bad = TRUE;
      return NULL;
  }
}

GVariant* rv_std_decode(const guint8* data, gsize len) {
  Reader r = {data, len, 0, FALSE};
  GVariant* v = std_read(&r, 0);
  return r.bad ? NULL : v;
}

gboolean rv_std_decode_call(GBytes* msg, char** method, GVariant** args) {
  gsize len;
  const guint8* d = g_bytes_get_data(msg, &len);
  Reader r = {d, len, 0, FALSE};
  g_autoptr(GVariant) m = g_variant_ref_sink(std_read(&r, 0) ?: rv_null());
  if (r.bad || !g_variant_is_of_type(m, G_VARIANT_TYPE_STRING)) return FALSE;
  GVariant* a = std_read(&r, 0);
  if (r.bad) return FALSE;
  *method = g_strdup(g_variant_get_string(m, NULL));
  *args = a ? g_variant_ref_sink(a) : g_variant_ref_sink(rv_null());
  return TRUE;
}

GBytes* rv_std_success(GVariant* result) {
  GByteArray* a = g_byte_array_new();
  guint8 z = 0;
  g_byte_array_append(a, &z, 1);
  g_autoptr(GVariant) r = result ? g_variant_ref_sink(result) : NULL;
  std_write(a, r ? r : g_variant_new_tuple(NULL, 0));
  return g_byte_array_free_to_bytes(a);
}

GBytes* rv_std_method_call(const char* method, GVariant* args) {
  GByteArray* a = g_byte_array_new();
  g_autoptr(GVariant) m = g_variant_ref_sink(rv_str(method));
  g_autoptr(GVariant) v = g_variant_ref_sink(args ? args : rv_null());
  std_write(a, m);
  std_write(a, v);
  return g_byte_array_free_to_bytes(a);
}

GBytes* rv_std_error(const char* code, const char* message) {
  GByteArray* a = g_byte_array_new();
  guint8 one = 1;
  g_byte_array_append(a, &one, 1);
  g_autoptr(GVariant) c = g_variant_ref_sink(rv_str(code));
  g_autoptr(GVariant) m = g_variant_ref_sink(rv_str(message));
  g_autoptr(GVariant) n = g_variant_ref_sink(rv_null());
  std_write(a, c);
  std_write(a, m);
  std_write(a, n);
  return g_byte_array_free_to_bytes(a);
}

// ------------------------------------------------------------------ JSON

static void json_write_string(GString* s, const char* str) {
  g_string_append_c(s, '"');
  for (const guchar* p = (const guchar*)str; *p; p++) {
    switch (*p) {
      case '"': g_string_append(s, "\\\""); break;
      case '\\': g_string_append(s, "\\\\"); break;
      case '\n': g_string_append(s, "\\n"); break;
      case '\r': g_string_append(s, "\\r"); break;
      case '\t': g_string_append(s, "\\t"); break;
      default:
        if (*p < 0x20) g_string_append_printf(s, "\\u%04x", *p);
        else g_string_append_c(s, *p);
    }
  }
  g_string_append_c(s, '"');
}

static void json_write(GString* s, GVariant* v) {
  g_autoptr(GVariant) u = unbox(v);
  if (!u || g_variant_is_of_type(u, G_VARIANT_TYPE_UNIT)) {
    g_string_append(s, "null");
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_BOOLEAN)) {
    g_string_append(s, g_variant_get_boolean(u) ? "true" : "false");
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_INT64) ||
             g_variant_is_of_type(u, G_VARIANT_TYPE_INT32)) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, rv_as_int(u, 0));
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_DOUBLE)) {
    double d = g_variant_get_double(u);
    if (!isfinite(d)) {
      g_string_append(s, "null");
    } else {
      char buf[G_ASCII_DTOSTR_BUF_SIZE];
      g_ascii_dtostr(buf, sizeof buf, d);
      g_string_append(s, buf);
    }
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE_STRING)) {
    json_write_string(s, g_variant_get_string(u, NULL));
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("av"))) {
    g_string_append_c(s, '[');
    for (gsize i = 0; i < g_variant_n_children(u); i++) {
      if (i) g_string_append_c(s, ',');
      g_autoptr(GVariant) c = g_variant_get_child_value(u, i);
      json_write(s, c);
    }
    g_string_append_c(s, ']');
  } else if (g_variant_is_of_type(u, G_VARIANT_TYPE("a{sv}"))) {
    g_string_append_c(s, '{');
    for (gsize i = 0; i < g_variant_n_children(u); i++) {
      if (i) g_string_append_c(s, ',');
      g_autoptr(GVariant) e = g_variant_get_child_value(u, i);
      g_autoptr(GVariant) k = g_variant_get_child_value(e, 0);
      g_autoptr(GVariant) val = g_variant_get_child_value(e, 1);
      json_write_string(s, g_variant_get_string(k, NULL));
      g_string_append_c(s, ':');
      json_write(s, val);
    }
    g_string_append_c(s, '}');
  } else {
    g_string_append(s, "null");
  }
}

GBytes* rv_json_encode(GVariant* value) {
  g_autoptr(GVariant) v = value ? g_variant_ref_sink(value) : NULL;
  GString* s = g_string_new(NULL);
  json_write(s, v);
  return g_string_free_to_bytes(s);
}

typedef struct {
  const char* p;
  const char* end;
  gboolean bad;
} JP;

static void jskip(JP* j) {
  while (j->p < j->end && g_ascii_isspace(*j->p)) j->p++;
}

static GVariant* jparse(JP* j, int depth);

static char* jstring(JP* j) {
  // Assumes *p == '"'.
  j->p++;
  GString* s = g_string_new(NULL);
  while (j->p < j->end && *j->p != '"') {
    if (*j->p == '\\' && j->p + 1 < j->end) {
      j->p++;
      switch (*j->p) {
        case 'n': g_string_append_c(s, '\n'); break;
        case 'r': g_string_append_c(s, '\r'); break;
        case 't': g_string_append_c(s, '\t'); break;
        case 'b': g_string_append_c(s, '\b'); break;
        case 'f': g_string_append_c(s, '\f'); break;
        case 'u': {
          if (j->p + 4 >= j->end) { j->bad = TRUE; break; }
          char hex[5] = {j->p[1], j->p[2], j->p[3], j->p[4], 0};
          gunichar c = g_ascii_strtoull(hex, NULL, 16);
          j->p += 4;
          if (c >= 0xd800 && c < 0xdc00 && j->p + 6 < j->end && j->p[1] == '\\' && j->p[2] == 'u') {
            char h2[5] = {j->p[3], j->p[4], j->p[5], j->p[6], 0};
            gunichar lo = g_ascii_strtoull(h2, NULL, 16);
            if (lo >= 0xdc00 && lo < 0xe000) {
              c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
              j->p += 6;
            }
          }
          g_string_append_unichar(s, c);
          break;
        }
        default: g_string_append_c(s, *j->p);
      }
      j->p++;
    } else {
      g_string_append_c(s, *j->p++);
    }
  }
  if (j->p >= j->end) j->bad = TRUE;
  else j->p++;
  return g_string_free(s, FALSE);
}

static GVariant* jparse(JP* j, int depth) {
  jskip(j);
  if (j->p >= j->end || depth > 64) { j->bad = TRUE; return NULL; }
  char c = *j->p;
  if (c == '{') {
    j->p++;
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    jskip(j);
    if (j->p < j->end && *j->p == '}') { j->p++; return g_variant_builder_end(&b); }
    while (!j->bad) {
      jskip(j);
      if (j->p >= j->end || *j->p != '"') { j->bad = TRUE; break; }
      g_autofree char* k = jstring(j);
      jskip(j);
      if (j->p >= j->end || *j->p != ':') { j->bad = TRUE; break; }
      j->p++;
      GVariant* v = jparse(j, depth + 1);
      if (!v) break;
      g_variant_builder_add(&b, "{sv}", k, v);
      jskip(j);
      if (j->p < j->end && *j->p == ',') { j->p++; continue; }
      if (j->p < j->end && *j->p == '}') { j->p++; return g_variant_builder_end(&b); }
      j->bad = TRUE;
    }
    g_variant_builder_clear(&b);
    return NULL;
  }
  if (c == '[') {
    j->p++;
    GPtrArray* items = g_ptr_array_new();
    jskip(j);
    gboolean done = FALSE;
    if (j->p < j->end && *j->p == ']') { j->p++; done = TRUE; }
    while (!done && !j->bad) {
      GVariant* v = jparse(j, depth + 1);
      if (!v) break;
      g_ptr_array_add(items, v);
      jskip(j);
      if (j->p < j->end && *j->p == ',') { j->p++; continue; }
      if (j->p < j->end && *j->p == ']') { j->p++; done = TRUE; break; }
      j->bad = TRUE;
    }
    GVariant* out = NULL;
    if (done && !j->bad) out = rv_list_from_array(items);
    else for (guint i = 0; i < items->len; i++) g_variant_unref(g_variant_ref_sink(g_ptr_array_index(items, i)));
    g_ptr_array_free(items, TRUE);
    return out;
  }
  if (c == '"') {
    g_autofree char* s = jstring(j);
    return j->bad ? NULL : rv_str(s);
  }
  if (!strncmp(j->p, "true", 4)) { j->p += 4; return rv_bool(TRUE); }
  if (!strncmp(j->p, "false", 5)) { j->p += 5; return rv_bool(FALSE); }
  if (!strncmp(j->p, "null", 4)) { j->p += 4; return rv_null(); }
  // number
  const char* start = j->p;
  gboolean is_float = FALSE;
  while (j->p < j->end && (g_ascii_isdigit(*j->p) || strchr("+-.eE", *j->p))) {
    if (strchr(".eE", *j->p)) is_float = TRUE;
    j->p++;
  }
  if (j->p == start) { j->bad = TRUE; return NULL; }
  g_autofree char* num = g_strndup(start, j->p - start);
  if (is_float) return rv_dbl(g_ascii_strtod(num, NULL));
  return rv_int(g_ascii_strtoll(num, NULL, 10));
}

GVariant* rv_json_decode(const guint8* data, gsize len) {
  JP j = {(const char*)data, (const char*)data + len, FALSE};
  GVariant* v = jparse(&j, 0);
  if (j.bad) {
    if (v) g_variant_unref(g_variant_ref_sink(v));
    return NULL;
  }
  return v;
}

gboolean rv_json_decode_call(GBytes* msg, char** method, GVariant** args) {
  gsize len;
  const guint8* d = g_bytes_get_data(msg, &len);
  g_autoptr(GVariant) v = rv_json_decode(d, len);
  if (!v) return FALSE;
  g_variant_ref_sink(v);
  const char* m = rv_map_str(v, "method", NULL);
  if (!m) return FALSE;
  *method = g_strdup(m);
  GVariant* a = rv_map_get(v, "args");
  *args = a ? a : g_variant_ref_sink(rv_null());
  return TRUE;
}

GBytes* rv_json_success(GVariant* result) {
  return rv_json_encode(rv_list(result ? result : rv_null(), NULL));
}

GBytes* rv_json_error(const char* code, const char* message) {
  return rv_json_encode(rv_list(rv_str(code), rv_str(message), rv_null(), NULL));
}

GBytes* rv_json_method_call(const char* method, GVariant* args) {
  return rv_json_encode(rv_map("method", rv_str(method), "args", args ? args : rv_null(), NULL));
}

GBytes* rv_string_bytes(const char* s) {
  return g_bytes_new(s, strlen(s));
}
