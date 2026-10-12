# SPDX-License-Identifier: GPL-3.0-or-later
#
# Ramble Voice Linux runner: a GTK4 application on the Flutter Embedder API.
# `flutter build linux` drives this file (it passes FLUTTER_TARGET_PLATFORM,
# CMAKE_BUILD_TYPE and the ephemeral dir with icudtl.dat); see linux/README.md.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

set(BINARY_NAME "ramble_voice")
set(APPLICATION_ID "io.github.luohoa97.RambleVoice")

cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Profile" "Release")
endif()

# Compatibility for FFI/native CMake projects written against the
# flutter-create plugin template.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter tool glue (unpacks icudtl.dat and builds assets).  Nothing from
# Flutter's GTK3 embedding is ever built or linked.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# The pinned embedder engine (libflutter_engine.so) for this arch and mode.
add_subdirectory("engine")

find_package(PkgConfig REQUIRED)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must be in the right relative locations.
set_target_properties(${BINARY_NAME} PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run")

# Native PipeWire capture library (dart:ffi), built from native/ramble_capture.
set(RAMBLE_CAPTURE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/ramble_capture")
if(EXISTS "${RAMBLE_CAPTURE_DIR}/CMakeLists.txt")
  add_subdirectory("${RAMBLE_CAPTURE_DIR}" "native/ramble_capture")
endif()

# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ENGINE_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(TARGET ramble_capture)
  install(FILES "$<TARGET_FILE:ramble_capture>" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Bundle gtk4-layer-shell (not installed on most desktops, e.g. Fedora
# Silverblue) so the bundle runs outside the build environment. RPATH is
# $ORIGIN/lib, so the bundled copy is found first.
find_package(PkgConfig REQUIRED)
pkg_check_modules(BUNDLE_LAYER_SHELL QUIET gtk4-layer-shell-0)
if(BUNDLE_LAYER_SHELL_FOUND)
  find_library(BUNDLE_LAYER_SHELL_LIB NAMES gtk4-layer-shell
    HINTS ${BUNDLE_LAYER_SHELL_LIBRARY_DIRS})
  if(BUNDLE_LAYER_SHELL_LIB)
    get_filename_component(BUNDLE_LAYER_SHELL_REAL "${BUNDLE_LAYER_SHELL_LIB}" REALPATH)
    install(FILES "${BUNDLE_LAYER_SHELL_REAL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      RENAME "libgtk4-layer-shell.so.0" COMPONENT Runtime)
  endif()
endif()

# App icon, referenced by the desktop entry written for source builds.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/icons/io.github.luohoa97.RambleVoice-256.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" RENAME "icon.png" COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
