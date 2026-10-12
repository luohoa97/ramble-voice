# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pinned Flutter embedder engine.  Fetched (and sha256-verified) by
# fetch_engine.sh at configure time when it is missing.
if(FLUTTER_TARGET_PLATFORM STREQUAL "linux-arm64")
  set(RV_ENGINE_ARCH "aarch64")
elseif(FLUTTER_TARGET_PLATFORM STREQUAL "linux-x64" OR NOT FLUTTER_TARGET_PLATFORM)
  set(RV_ENGINE_ARCH "x64")
else()
  message(FATAL_ERROR "Unsupported FLUTTER_TARGET_PLATFORM: ${FLUTTER_TARGET_PLATFORM}")
endif()

string(TOLOWER "${CMAKE_BUILD_TYPE}" RV_ENGINE_MODE)
if(NOT RV_ENGINE_MODE MATCHES "^(debug|profile|release)$")
  set(RV_ENGINE_MODE "debug")
endif()

set(RV_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/${RV_ENGINE_ARCH}-${RV_ENGINE_MODE}")
set(RV_ENGINE_LIB "${RV_ENGINE_DIR}/libflutter_engine.so")

execute_process(
  COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/fetch_engine.sh" "${RV_ENGINE_ARCH}" "${RV_ENGINE_MODE}"
  RESULT_VARIABLE RV_FETCH_RESULT)
if(NOT RV_FETCH_RESULT EQUAL 0 OR NOT EXISTS "${RV_ENGINE_LIB}")
  message(FATAL_ERROR
    "Flutter engine ${RV_ENGINE_ARCH}-${RV_ENGINE_MODE} is missing; run "
    "linux/engine/fetch_engine.sh ${RV_ENGINE_ARCH} ${RV_ENGINE_MODE}")
endif()

add_library(flutter_engine SHARED IMPORTED GLOBAL)
set_target_properties(flutter_engine PROPERTIES
  IMPORTED_LOCATION "${RV_ENGINE_LIB}"
  IMPORTED_SONAME "libflutter_engine.so"
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/..")

set(FLUTTER_ENGINE_LIBRARY "${RV_ENGINE_LIB}" PARENT_SCOPE)
