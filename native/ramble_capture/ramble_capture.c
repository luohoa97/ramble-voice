/* SPDX-License-Identifier: GPL-3.0-or-later */

#define _GNU_SOURCE
#include "ramble_capture.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Types and inline helpers only; every function is resolved with dlsym. */
#include <pulse/error.h>
#include <pulse/simple.h>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

#define RING_BYTES (RC_SAMPLE_RATE * RC_BYTES_PER_SAMPLE * 10) /* ~10 s */
#define RING_CAP 524288 /* power of two >= RING_BYTES */
#define RING_MASK (RING_CAP - 1)
#define PA_CHUNK_BYTES (RC_SAMPLE_RATE * RC_BYTES_PER_SAMPLE / 50) /* 20 ms */
#define CONNECT_TIMEOUT_SEC 3

_Static_assert(RING_CAP >= RING_BYTES, "ring too small");
_Static_assert((RING_CAP & (RING_CAP - 1)) == 0, "ring must be a power of two");

/* ---- ring buffer: single producer (audio thread), single consumer (Dart) -- */

static uint8_t g_ring[RING_CAP];
static atomic_uint_fast64_t g_write; /* total bytes written */
static atomic_uint_fast64_t g_read;  /* total bytes consumed */

static void ring_write(const uint8_t *data, size_t len) {
  uint64_t w = atomic_load_explicit(&g_write, memory_order_relaxed);
  uint64_t r = atomic_load_explicit(&g_read, memory_order_acquire);
  size_t room = RING_CAP - (size_t)(w - r);
  if (len > room) len = room; /* overflow: drop the newest, consumer is behind */
  for (size_t i = 0; i < len; i++) g_ring[(w + i) & RING_MASK] = data[i];
  atomic_store_explicit(&g_write, w + len, memory_order_release);
}

/* ---- state -------------------------------------------------------------- */

enum backend { BACKEND_NONE, BACKEND_PIPEWIRE, BACKEND_PULSE };

static char g_error[256];
static int g_opened;
static enum backend g_backend = BACKEND_NONE;
static atomic_int g_capturing;
static atomic_int g_failed;

static void set_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_error(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_error, sizeof g_error, fmt, ap);
  va_end(ap);
}

/* ---- PipeWire (dlopen) ---------------------------------------------------- */

static struct {
  void *lib;
  void (*init)(int *, char ***);
  struct pw_thread_loop *(*thread_loop_new)(const char *, const struct spa_dict *);
  int (*thread_loop_start)(struct pw_thread_loop *);
  void (*thread_loop_stop)(struct pw_thread_loop *);
  void (*thread_loop_destroy)(struct pw_thread_loop *);
  void (*thread_loop_lock)(struct pw_thread_loop *);
  void (*thread_loop_unlock)(struct pw_thread_loop *);
  int (*thread_loop_timed_wait)(struct pw_thread_loop *, int);
  void (*thread_loop_signal)(struct pw_thread_loop *, bool);
  struct pw_loop *(*thread_loop_get_loop)(struct pw_thread_loop *);
  struct pw_properties *(*properties_new)(const char *, ...);
  struct pw_stream *(*stream_new_simple)(struct pw_loop *, const char *, struct pw_properties *,
                                         const struct pw_stream_events *, void *);
  int (*stream_connect)(struct pw_stream *, enum pw_direction, uint32_t, enum pw_stream_flags,
                        const struct spa_pod **, uint32_t);
  int (*stream_disconnect)(struct pw_stream *);
  void (*stream_destroy)(struct pw_stream *);
  struct pw_buffer *(*stream_dequeue_buffer)(struct pw_stream *);
  int (*stream_queue_buffer)(struct pw_stream *, struct pw_buffer *);
} pw;

static struct pw_thread_loop *g_loop;
static struct pw_stream *g_stream;
static atomic_int g_pw_state; /* enum pw_stream_state, updated from the loop thread */

static void pw_on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state,
                                const char *error) {
  atomic_store(&g_pw_state, (int)state);
  if (state == PW_STREAM_STATE_ERROR) {
    atomic_store(&g_failed, 1);
    set_error("PipeWire stream error: %s", error ? error : "unknown");
  }
  pw.thread_loop_signal(g_loop, false);
}

static void pw_on_process(void *data) {
  if (!g_stream) return;
  struct pw_buffer *b = pw.stream_dequeue_buffer(g_stream);
  if (!b) return;
  struct spa_data *d = &b->buffer->datas[0];
  if (d->data && d->chunk && atomic_load(&g_capturing)) {
    uint32_t offset = d->chunk->offset % d->maxsize;
    uint32_t size = d->chunk->size;
    if (size > d->maxsize - offset) size = d->maxsize - offset;
    size -= size % RC_BYTES_PER_SAMPLE;
    ring_write((const uint8_t *)d->data + offset, size);
  }
  pw.stream_queue_buffer(g_stream, b);
}

static const struct pw_stream_events k_stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = pw_on_state_changed,
    .process = pw_on_process,
};

static int pw_load(void) {
  if (pw.lib) return 0;
  void *lib = dlopen("libpipewire-0.3.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return -1;
#define SYM(field, name)                         \
  do {                                           \
    *(void **)(&pw.field) = dlsym(lib, name);    \
    if (!pw.field) {                             \
      dlclose(lib);                              \
      memset(&pw, 0, sizeof pw);                 \
      return -1;                                 \
    }                                            \
  } while (0)
  SYM(init, "pw_init");
  SYM(thread_loop_new, "pw_thread_loop_new");
  SYM(thread_loop_start, "pw_thread_loop_start");
  SYM(thread_loop_stop, "pw_thread_loop_stop");
  SYM(thread_loop_destroy, "pw_thread_loop_destroy");
  SYM(thread_loop_lock, "pw_thread_loop_lock");
  SYM(thread_loop_unlock, "pw_thread_loop_unlock");
  SYM(thread_loop_timed_wait, "pw_thread_loop_timed_wait");
  SYM(thread_loop_signal, "pw_thread_loop_signal");
  SYM(thread_loop_get_loop, "pw_thread_loop_get_loop");
  SYM(properties_new, "pw_properties_new");
  SYM(stream_new_simple, "pw_stream_new_simple");
  SYM(stream_connect, "pw_stream_connect");
  SYM(stream_disconnect, "pw_stream_disconnect");
  SYM(stream_destroy, "pw_stream_destroy");
  SYM(stream_dequeue_buffer, "pw_stream_dequeue_buffer");
  SYM(stream_queue_buffer, "pw_stream_queue_buffer");
#undef SYM
  pw.lib = lib;
  pw.init(NULL, NULL);
  return 0;
}

static void pw_teardown(void) {
  if (!g_loop) return;
  pw.thread_loop_lock(g_loop);
  if (g_stream) {
    struct pw_stream *s = g_stream;
    g_stream = NULL;
    pw.stream_destroy(s);
  }
  pw.thread_loop_unlock(g_loop);
  pw.thread_loop_stop(g_loop);
  pw.thread_loop_destroy(g_loop);
  g_loop = NULL;
}

/* Returns 0 once the stream is streaming. */
static int pw_begin(void) {
  if (pw_load() != 0) {
    set_error("libpipewire-0.3 not available");
    return -1;
  }
  g_loop = pw.thread_loop_new("ramble-capture", NULL);
  if (!g_loop || pw.thread_loop_start(g_loop) != 0) {
    if (g_loop) pw.thread_loop_destroy(g_loop);
    g_loop = NULL;
    set_error("could not start PipeWire thread loop");
    return -1;
  }
  atomic_store(&g_pw_state, PW_STREAM_STATE_UNCONNECTED);
  pw.thread_loop_lock(g_loop);

  struct pw_properties *props =
      pw.properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                        PW_KEY_MEDIA_ROLE, "Communication", PW_KEY_APP_NAME, "Ramble Voice",
                        PW_KEY_NODE_NAME, "ramble-voice", NULL);
  g_stream = props ? pw.stream_new_simple(pw.thread_loop_get_loop(g_loop), "Ramble Voice capture",
                                          props, &k_stream_events, NULL)
                   : NULL;
  if (!g_stream) {
    pw.thread_loop_unlock(g_loop);
    pw_teardown();
    set_error("could not connect to the PipeWire daemon");
    return -1;
  }
  uint8_t pod_buf[256];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
  const struct spa_pod *params[1];
  params[0] = spa_format_audio_raw_build(
      &builder, SPA_PARAM_EnumFormat,
      &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_S16_LE, .rate = RC_SAMPLE_RATE,
                               .channels = RC_CHANNELS));

  int res = pw.stream_connect(
      g_stream, PW_DIRECTION_INPUT, PW_ID_ANY,
      PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
  if (res < 0) {
    pw.thread_loop_unlock(g_loop);
    pw_teardown();
    set_error("pw_stream_connect failed: %s", strerror(-res));
    return -1;
  }

  for (int waited = 0; waited < CONNECT_TIMEOUT_SEC; waited++) {
    int st = atomic_load(&g_pw_state);
    if (st == PW_STREAM_STATE_STREAMING || st == PW_STREAM_STATE_ERROR) break;
    pw.thread_loop_timed_wait(g_loop, 1); /* seconds; woken early by state_changed */
  }
  int state = atomic_load(&g_pw_state);
  pw.thread_loop_unlock(g_loop);
  if (state != PW_STREAM_STATE_STREAMING && state != PW_STREAM_STATE_PAUSED) {
    if (!atomic_load(&g_failed)) set_error("PipeWire stream did not start (state %d)", state);
    pw_teardown();
    return -1;
  }
  return 0;
}

/* ---- PulseAudio simple API (dlopen) --------------------------------------- */

static struct {
  void *lib_simple;
  void *lib_pulse;
  pa_simple *(*simple_new)(const char *, const char *, pa_stream_direction_t, const char *,
                           const char *, const pa_sample_spec *, const pa_channel_map *,
                           const pa_buffer_attr *, int *);
  int (*simple_read)(pa_simple *, void *, size_t, int *);
  void (*simple_free)(pa_simple *);
  const char *(*strerror_fn)(int);
} pa;

static pthread_t g_pa_thread;
static int g_pa_thread_running;
static atomic_int g_pa_stop;
static pthread_mutex_t g_pa_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pa_cond = PTHREAD_COND_INITIALIZER;
static int g_pa_ready; /* 0 pending, 1 ok, -1 failed */

static int pa_load(void) {
  if (pa.lib_simple) return 0;
  void *simple = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_LOCAL);
  void *pulse = dlopen("libpulse.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!simple || !pulse) {
    if (simple) dlclose(simple);
    if (pulse) dlclose(pulse);
    return -1;
  }
  *(void **)(&pa.simple_new) = dlsym(simple, "pa_simple_new");
  *(void **)(&pa.simple_read) = dlsym(simple, "pa_simple_read");
  *(void **)(&pa.simple_free) = dlsym(simple, "pa_simple_free");
  *(void **)(&pa.strerror_fn) = dlsym(pulse, "pa_strerror");
  if (!pa.simple_new || !pa.simple_read || !pa.simple_free || !pa.strerror_fn) {
    dlclose(simple);
    dlclose(pulse);
    memset(&pa, 0, sizeof pa);
    return -1;
  }
  pa.lib_simple = simple;
  pa.lib_pulse = pulse;
  return 0;
}

static void pa_signal_ready(int value) {
  pthread_mutex_lock(&g_pa_mutex);
  g_pa_ready = value;
  pthread_cond_signal(&g_pa_cond);
  pthread_mutex_unlock(&g_pa_mutex);
}

static void *pa_thread_main(void *arg) {
  pa_sample_spec spec = {.format = PA_SAMPLE_S16LE, .rate = RC_SAMPLE_RATE, .channels = RC_CHANNELS};
  pa_buffer_attr attr;
  memset(&attr, 0xff, sizeof attr); /* (uint32_t)-1 means server default */
  attr.fragsize = PA_CHUNK_BYTES;
  int err = 0;
  pa_simple *s = pa.simple_new(NULL, "Ramble Voice", PA_STREAM_RECORD, NULL, "Dictation", &spec,
                               NULL, &attr, &err);
  if (!s) {
    set_error("PulseAudio connect failed: %s", pa.strerror_fn(err));
    pa_signal_ready(-1);
    return NULL;
  }
  pa_signal_ready(1);
  uint8_t chunk[PA_CHUNK_BYTES];
  while (!atomic_load(&g_pa_stop)) {
    if (pa.simple_read(s, chunk, sizeof chunk, &err) < 0) {
      set_error("PulseAudio read failed: %s", pa.strerror_fn(err));
      atomic_store(&g_failed, 1);
      break;
    }
    if (atomic_load(&g_capturing)) ring_write(chunk, sizeof chunk);
  }
  pa.simple_free(s);
  return NULL;
}

static int pa_begin(void) {
  if (pa_load() != 0) {
    set_error("libpulse-simple not available");
    return -1;
  }
  atomic_store(&g_pa_stop, 0);
  g_pa_ready = 0;
  if (pthread_create(&g_pa_thread, NULL, pa_thread_main, NULL) != 0) {
    set_error("could not start capture thread");
    return -1;
  }
  g_pa_thread_running = 1;
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += CONNECT_TIMEOUT_SEC;
  pthread_mutex_lock(&g_pa_mutex);
  while (g_pa_ready == 0) {
    if (pthread_cond_timedwait(&g_pa_cond, &g_pa_mutex, &deadline) == ETIMEDOUT) break;
  }
  int ready = g_pa_ready;
  pthread_mutex_unlock(&g_pa_mutex);
  if (ready != 1) {
    if (ready == 0) set_error("PulseAudio connection timed out");
    atomic_store(&g_pa_stop, 1);
    /* On timeout the thread may be stuck in connect; detach so we never hang. */
    if (ready == 0) pthread_detach(g_pa_thread);
    else pthread_join(g_pa_thread, NULL);
    g_pa_thread_running = 0;
    return -1;
  }
  return 0;
}

static void pa_end(void) {
  if (!g_pa_thread_running) return;
  atomic_store(&g_pa_stop, 1);
  pthread_join(g_pa_thread, NULL);
  g_pa_thread_running = 0;
}

/* ---- public API ----------------------------------------------------------- */

int rc_open(void) {
  g_error[0] = '\0';
  if (g_opened) return 0;
  int have_pw = pw_load() == 0;
  int have_pa = pa_load() == 0;
  if (!have_pw && !have_pa) {
    set_error("neither libpipewire-0.3 nor libpulse-simple could be loaded");
    return -1;
  }
  g_opened = 1;
  return 0;
}

int rc_start(void) {
  g_error[0] = '\0';
  if (!g_opened) {
    set_error("rc_open() was not called");
    return -1;
  }
  if (atomic_load(&g_capturing)) return 0;

  atomic_store(&g_failed, 0);
  /* Drop stale audio. Consumer-side only, so it never races the producer. */
  atomic_store(&g_read, atomic_load(&g_write));

  char pw_error[sizeof g_error] = "";
  /* RAMBLE_CAPTURE_BACKEND=pulse skips PipeWire (used to test the fallback). */
  const char *forced = getenv("RAMBLE_CAPTURE_BACKEND");
  int skip_pw = forced && strcmp(forced, "pulse") == 0;
  if (skip_pw) snprintf(pw_error, sizeof pw_error, "PipeWire disabled by environment");
  if (!skip_pw && pw_begin() == 0) {
    g_backend = BACKEND_PIPEWIRE;
  } else {
    if (!skip_pw) snprintf(pw_error, sizeof pw_error, "%s", g_error);
    atomic_store(&g_failed, 0);
    if (pa_begin() == 0) {
      g_backend = BACKEND_PULSE;
    } else {
      char pa_error[sizeof g_error];
      snprintf(pa_error, sizeof pa_error, "%s", g_error);
      snprintf(g_error, sizeof g_error, "%.100s; %.140s", pw_error, pa_error);
      g_backend = BACKEND_NONE;
      return -1;
    }
  }
  g_error[0] = '\0';
  atomic_store(&g_capturing, 1);
  return 0;
}

int rc_read(uint8_t *buf, int max_bytes) {
  if (!buf || max_bytes <= 0) return 0;
  uint64_t r = atomic_load_explicit(&g_read, memory_order_relaxed);
  uint64_t w = atomic_load_explicit(&g_write, memory_order_acquire);
  size_t avail = (size_t)(w - r);
  if (avail == 0) return atomic_load(&g_failed) ? -1 : 0;
  size_t n = avail < (size_t)max_bytes ? avail : (size_t)max_bytes;
  n -= n % RC_BYTES_PER_SAMPLE;
  for (size_t i = 0; i < n; i++) buf[i] = g_ring[(r + i) & RING_MASK];
  atomic_store_explicit(&g_read, r + n, memory_order_release);
  return (int)n;
}

int rc_stop(void) {
  atomic_store(&g_capturing, 0);
  if (g_backend == BACKEND_PIPEWIRE) pw_teardown();
  else if (g_backend == BACKEND_PULSE) pa_end();
  return 0;
}

void rc_close(void) {
  rc_stop();
  g_opened = 0;
}

const char *rc_backend(void) {
  switch (g_backend) {
    case BACKEND_PIPEWIRE: return "pipewire";
    case BACKEND_PULSE: return "pulse";
    default: return "";
  }
}

const char *rc_last_error(void) { return g_error; }
