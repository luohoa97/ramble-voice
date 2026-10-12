# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.16)
project(ramble_capture C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)

find_package(PkgConfig REQUIRED)
# Headers only: libpipewire and libpulse are loaded with dlopen at runtime.
pkg_check_modules(PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3)
pkg_check_modules(PULSE_SIMPLE REQUIRED IMPORTED_TARGET libpulse-simple)

add_library(ramble_capture SHARED ramble_capture.c)
target_compile_options(ramble_capture PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_include_directories(ramble_capture PRIVATE
  ${PIPEWIRE_INCLUDE_DIRS}
  ${PULSE_SIMPLE_INCLUDE_DIRS})
target_link_libraries(ramble_capture PRIVATE ${CMAKE_DL_LIBS} pthread)
set_target_properties(ramble_capture PROPERTIES
  C_VISIBILITY_PRESET hidden
  PREFIX "lib"
  OUTPUT_NAME "ramble_capture")

install(TARGETS ramble_capture LIBRARY DESTINATION lib)
install(FILES ramble_capture.h DESTINATION include)

option(RAMBLE_CAPTURE_BUILD_TEST "Build the standalone capture test" OFF)
if(RAMBLE_CAPTURE_BUILD_TEST)
  add_executable(ramble_capture_test test_capture.c)
  target_link_libraries(ramble_capture_test PRIVATE ramble_capture)
endif()
