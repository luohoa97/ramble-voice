# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.12)
pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)
pkg_check_modules(PANGOCAIRO REQUIRED IMPORTED_TARGET pangocairo)
pkg_check_modules(LAYER_SHELL IMPORTED_TARGET gtk4-layer-shell-0)

add_executable(${BINARY_NAME}
  "main.c"
  "rv_app.c"
  "rv_engine.c"
  "rv_renderer.c"
  "rv_view.c"
  "rv_keyboard.c"
  "rv_keymap.c"
  "rv_textinput.c"
  "rv_platform.c"
  "rv_settings.c"
  "rv_a11y.c"
  "rv_overlay.c"
  "rv_codec.c"
)

target_compile_options(${BINARY_NAME} PRIVATE -Wall -Wextra -Werror
  -Wno-unused-parameter -Wno-missing-field-initializers)
target_compile_options(${BINARY_NAME} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O2>")
target_compile_definitions(${BINARY_NAME} PRIVATE
  APPLICATION_ID="${APPLICATION_ID}"
  "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# gtk4-layer-shell must precede GTK/libwayland-client in the link order.
if(LAYER_SHELL_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_LAYER_SHELL)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::LAYER_SHELL)
  target_link_options(${BINARY_NAME} PRIVATE "LINKER:--no-as-needed")
else()
  message(STATUS "gtk4-layer-shell not found: the dictation overlay is disabled")
endif()

target_link_libraries(${BINARY_NAME} PRIVATE ${CMAKE_DL_LIBS}
  PkgConfig::GTK4 PkgConfig::EPOXY PkgConfig::PANGOCAIRO flutter_engine m)
