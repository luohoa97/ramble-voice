// SPDX-License-Identifier: GPL-3.0-or-later
#include <gtk/gtk.h>
#include <libgen.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "rv_app.h"

/*
 * Dart native assets (sqlite3, LiteRT-LM, ...) are dlopen()ed by file name.
 * The bundle keeps them in <exe dir>/lib, which is only on our own RUNPATH,
 * not on the dynamic loader's search path for dlopen() from the engine. The
 * loader reads LD_LIBRARY_PATH only at startup, so set it and re-exec once.
 */
static void ensure_bundle_library_path(char** argv) {
  if (getenv("RAMBLE_LIBPATH_SET")) return;
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0) return;
  exe[n] = '\0';
  char dir[PATH_MAX];
  strncpy(dir, exe, sizeof dir - 1);
  dir[sizeof dir - 1] = '\0';
  g_autofree char* lib = g_build_filename(dirname(dir), "lib", NULL);
  const char* old = getenv("LD_LIBRARY_PATH");
  g_autofree char* value = old && *old ? g_strconcat(lib, ":", old, NULL) : g_strdup(lib);
  setenv("LD_LIBRARY_PATH", value, 1);
  setenv("RAMBLE_LIBPATH_SET", "1", 1);
  execv(exe, argv);
  // If exec fails, carry on; only native assets loaded by name are affected.
}

int main(int argc, char** argv) {
  ensure_bundle_library_path(argv);
  g_set_prgname("io.github.luohoa97.RambleVoice");
  GtkApplication* app = rv_app_new();
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
