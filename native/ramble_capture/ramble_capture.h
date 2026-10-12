/* SPDX-License-Identifier: GPL-3.0-or-later */

/*
 * libramble_capture: microphone capture for Ramble Voice on Linux.
 *
 * Captures 16 kHz mono signed 16-bit little-endian PCM into an internal
 * ring buffer (about 10 seconds) that the caller drains with rc_read().
 * PipeWire is used when reachable; otherwise the PulseAudio simple API
 * (served by pipewire-pulse or PulseAudio) is used. Both libraries are
 * loaded with dlopen at runtime, so this library loads even when one of
 * them is not installed.
 *
 * Threading: all functions must be called from one thread (the Dart
 * isolate). Capture itself runs on library-owned threads.
 *
 * Typical use: rc_open(); rc_start(); loop { rc_read(...) }; rc_stop();
 * rc_close(). rc_start()/rc_stop() may be repeated between open and close.
 */
#ifndef RAMBLE_CAPTURE_H
#define RAMBLE_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define RC_API __attribute__((visibility("default")))
#else
#define RC_API
#endif

/* Sample format delivered by rc_read(). */
#define RC_SAMPLE_RATE 16000
#define RC_CHANNELS 1
#define RC_BYTES_PER_SAMPLE 2

/* Loads the audio libraries. Returns 0 on success, -1 if neither PipeWire
 * nor PulseAudio client libraries could be loaded (see rc_last_error()). */
RC_API int rc_open(void);

/* Starts capturing. Tries PipeWire first, then PulseAudio. Returns 0 on
 * success, a negative value on failure (see rc_last_error()). Discards any
 * audio left over from a previous run. Calling it while capturing is a no-op. */
RC_API int rc_start(void);

/* Copies up to max_bytes of captured PCM (whole samples only) into buf.
 * Never blocks. Returns the number of bytes copied, 0 if nothing is
 * available, or -1 if the capture stream failed (see rc_last_error()). */
RC_API int rc_read(uint8_t *buf, int max_bytes);

/* Stops capturing and releases the stream. Returns 0. Bytes captured before
 * the call remain readable with rc_read(). */
RC_API int rc_stop(void);

/* Stops capturing if needed and unloads state. The library may be reopened. */
RC_API void rc_close(void);

/* "pipewire" or "pulse" for the running (or last started) backend, "" if none.
 * The returned pointer stays valid until the next rc_* call. */
RC_API const char *rc_backend(void);

/* Human readable description of the last error, "" if none. The returned
 * pointer stays valid until the next rc_* call. */
RC_API const char *rc_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* RAMBLE_CAPTURE_H */
