cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "vyse_webos")
project(${PROJECT_NAME} LANGUAGES C CXX)

# LG's NDK: GLib (the embedder's main loop, which events are handed to) and the NDL media
# library (the TV's own player, as a C API).
find_package(PkgConfig)
pkg_check_modules(GLIB REQUIRED glib-2.0)
pkg_check_modules(NDLMEDIA REQUIRED ndlmedia)

# (as LG's own plugins: a TV's 32-bit system passes floats in integer registers)
if( ${CMAKE_SYSTEM_PROCESSOR} STREQUAL "arm" AND
    NOT "${CMAKE_CXX_COMPILER}" MATCHES "aarch64" )
  add_compile_options(-mfpu=neon -mfloat-abi=softfp)
endif()

# ── the player's native side ──

# LG's tool links "<package>_plugin" into the runner; the name must stay.
set(PLUGIN_NAME "vyse_webos_plugin")

add_library(${PLUGIN_NAME} SHARED
  "vyse_webos_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${GLIB_INCLUDE_DIRS}
  ${NDLMEDIA_INCLUDE_DIRS}
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  ${GLIB_LIBRARIES}
  ${NDLMEDIA_LIBRARIES}
  atomic
)

# ── the JavaScript engine scraper plugins run in ──
#
# Plugins run in QuickJS through the flutter_js package, whose Dart side calls a small C
# library by name: libquickjs_c_bridge_plugin.so. flutter_js ships that library built for
# desktop PCs only (x86-64), so for a TV it is built here, from the same source its author
# builds it from: QuickJS 2021-03-27 and one file of glue, at the commit named below (git
# checks what it fetched against that name, so nothing else can come in its place). The
# functions it exports are the ones flutter_js 0.8.7 looks up, compared one by one when this
# was written; quickjs_memory_limit.cc adds the one it lacks.
#
# The app loads it from lib/ beside the runner (lib/data/sources/plugins/js_plugins.dart).
include(FetchContent)
FetchContent_Declare(quickjs_c_bridge
  GIT_REPOSITORY https://github.com/abner/quickjs-c-bridge.git
  GIT_TAG 7204d9bf1afbe0550d51d7decdcce398b2c22e1a
)
FetchContent_MakeAvailable(quickjs_c_bridge)
set(QJS_DIR "${quickjs_c_bridge_SOURCE_DIR}/cxx")
file(STRINGS "${QJS_DIR}/quickjs/VERSION" QJS_VERSION)

add_library(quickjs_c_bridge_plugin SHARED
  "${QJS_DIR}/quickjs/cutils.c"
  "${QJS_DIR}/quickjs/libregexp.c"
  "${QJS_DIR}/quickjs/libunicode.c"
  "${QJS_DIR}/quickjs/quickjs.c"
  "${QJS_DIR}/libfastdev_quickjs_runtime.cpp"
  "quickjs_memory_limit.cc"
)
# (someone else's code: built as its author builds it, optimized, its warnings left alone.
# This QuickJS returns a pointer where a number is declared in two places, which newer
# compilers refuse outright unless told it is meant.)
target_compile_options(quickjs_c_bridge_plugin PRIVATE -O2 -w
  $<$<COMPILE_LANGUAGE:C>:-Wno-int-conversion>)
target_compile_definitions(quickjs_c_bridge_plugin PRIVATE
  _GNU_SOURCE
  "CONFIG_VERSION=\"${QJS_VERSION}\""
)
target_compile_features(quickjs_c_bridge_plugin PUBLIC cxx_std_17)
target_include_directories(quickjs_c_bridge_plugin PRIVATE "${QJS_DIR}")
set_target_properties(quickjs_c_bridge_plugin PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden)
# (QuickJS's Atomics wait on a thread; the thread library by whatever name this system has it)
find_package(Threads REQUIRED)
target_link_libraries(quickjs_c_bridge_plugin PRIVATE m Threads::Threads atomic)

# What goes into lib/ beside the runner, next to the plugin itself.
set(vyse_webos_bundled_libraries
  "$<TARGET_FILE:quickjs_c_bridge_plugin>"
  PARENT_SCOPE
)
