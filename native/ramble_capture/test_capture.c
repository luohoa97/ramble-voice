/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Records for N seconds (default 2) and prints how many bytes arrived. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "ramble_capture.h"

int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 2;
  if (rc_open() != 0) {
    fprintf(stderr, "open failed: %s\n", rc_last_error());
    return 2;
  }
  if (rc_start() != 0) {
    fprintf(stderr, "start failed: %s\n", rc_last_error());
    rc_close();
    return 3;
  }
  printf("backend: %s\n", rc_backend());
  long total = 0;
  uint8_t buf[4096];
  for (int i = 0; i < seconds * 50; i++) {
    usleep(20000);
    int n;
    while ((n = rc_read(buf, sizeof buf)) > 0) total += n;
    if (n < 0) {
      fprintf(stderr, "read failed: %s\n", rc_last_error());
      break;
    }
  }
  rc_stop();
  int n;
  while ((n = rc_read(buf, sizeof buf)) > 0) total += n;
  rc_close();
  printf("bytes: %ld (expected about %d)\n", total, seconds * RC_SAMPLE_RATE * RC_BYTES_PER_SAMPLE);
  return total > 0 ? 0 : 1;
}
