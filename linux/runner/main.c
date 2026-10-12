// SPDX-License-Identifier: GPL-3.0-or-later
#include <gtk/gtk.h>

#include "rv_app.h"

int main(int argc, char** argv) {
  g_set_prgname("io.github.luohoa97.RambleVoice");
  GtkApplication* app = rv_app_new();
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
