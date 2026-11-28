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
  dl
)

# The one call that places the picture on a TV without exported windows (webOS 4). Every
# webOS has it in its library; whether LG's header for webOS 26 still declares it is found out
# here, and the code that uses it is only compiled when it does (with the header's own
# declaration: should that not be four numbers, the build stops and says so).
include(CheckCXXSymbolExists)
set(CMAKE_REQUIRED_INCLUDES ${NDLMEDIA_INCLUDE_DIRS})
set(CMAKE_REQUIRED_LIBRARIES ${NDLMEDIA_LIBRARIES})
check_cxx_symbol_exists(NDL_MediaSetDisplayWindow "NDL/NDL_media.h" VYSE_HAVE_NDL_SET_DISPLAY_WINDOW)
unset(CMAKE_REQUIRED_INCLUDES)
unset(CMAKE_REQUIRED_LIBRARIES)
if(VYSE_HAVE_NDL_SET_DISPLAY_WINDOW)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE VYSE_HAVE_NDL_SET_DISPLAY_WINDOW)
endif()

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

# ── stand-ins for older webOS ──
#
# LG's engine and embedder are made for webOS 26. The package for older sets (tool/webos/
# build.sh, "older webOS") runs the same build on a runtime of its own, and these six small
# libraries give LG's embedder and the TV's media library what an older TV's own libraries
# lack. Each file says what it is for; webos/README.md has the whole of it. In the package for
# webOS 26 they are files in lib/ that nothing asks for.
#
#   vyse_start     the record of how the app started (made part of the program)
#   vyse_wayland   how requests reach the compositor, and at which version an interface of
#                  it is asked for (made part of the program, ahead of the TV's own library)
#   vyse_sdevent   the embedder's event loop: the TV's libsystemd, or its own on webOS 4
#   vyse_wlegl     the window the embedder draws into, whatever the TV's library is called
#   vyse_fallback  what is looked for last: the description of exported windows, for TVs
#                  whose library has none, and what the TV's own libraries ask the runtime
#                  for that VyseTV's runtime lacks (std::future's futex waits)
#   vyse_sdl       the window the TV's media library asks SDL for (made part of the program)
add_library(vyse_fallback SHARED "older/vyse_fallback.c")
# (it uses two names of the TV's Wayland library, which is always loaded before it; it is
# not linked against that library, so the build needs no Wayland files of its own)
target_link_options(vyse_fallback PRIVATE "-Wl,--unresolved-symbols=ignore-all")

add_library(vyse_wayland SHARED "older/vyse_wayland.c")
target_link_libraries(vyse_wayland PRIVATE dl Threads::Threads)

add_library(vyse_sdevent SHARED "older/vyse_sdevent.c")
# (it is the one library that needs vyse_fallback: that is what puts vyse_fallback after
# every library of the TV when the loader looks a name up. It uses one name of it, or LG's
# build, which keeps only the libraries something is used of, would leave it off the list.)
target_link_libraries(vyse_sdevent PRIVATE vyse_fallback dl)
# (its ten functions carry the version name the embedder asks libsystemd's for)
target_link_options(vyse_sdevent PRIVATE "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/older/vyse_sdevent.map")
set_target_properties(vyse_sdevent PROPERTIES LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/older/vyse_sdevent.map")

add_library(vyse_wlegl SHARED "older/vyse_wlegl.c")
target_link_libraries(vyse_wlegl PRIVATE dl)

add_library(vyse_start SHARED "older/vyse_start.c")
target_link_libraries(vyse_start PRIVATE dl)

# vyse_sdl: what an older TV's media library is told when it asks SDL for the app's window.
# It carries SDL's own name (its soname) and the package for older webOS makes it a library the
# program needs (tool/webos/older.sh), so it is loaded at the start and the media library's
# request for SDL by that name finds it, never the TV's own SDL.
add_library(vyse_sdl SHARED "older/vyse_sdl.c")
set_target_properties(vyse_sdl PROPERTIES NO_SONAME ON)
target_link_options(vyse_sdl PRIVATE "-Wl,-soname,libSDL2-2.0.so.0")

foreach(standin vyse_fallback vyse_wayland vyse_sdevent vyse_wlegl vyse_start vyse_sdl)
  target_compile_options(${standin} PRIVATE -O2 -Wall -Werror)
  set_target_properties(${standin} PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden)
endforeach()

# vyse_wayland tried without a TV: a stand-in for the TV's Wayland library, in an older TV's
# shape and in a newer one's, and a program that plays the app and the compositor around it.
# tool/webos/older.sh runs it in an emulator as the package is made. None of it is packaged.
foreach(shape old new)
  add_library(vyse_fake_wayland_${shape} SHARED "older/test/fake_wayland.c")
  target_compile_options(vyse_fake_wayland_${shape} PRIVATE -O1 -Wall -Werror)
  set_target_properties(vyse_fake_wayland_${shape} PROPERTIES
    OUTPUT_NAME vyse_fake_wayland
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/wayland_test/fake-${shape}"
    POSITION_INDEPENDENT_CODE ON)
endforeach()
target_compile_definitions(vyse_fake_wayland_new PRIVATE VYSE_FAKE_NEW)
add_executable(vyse_wayland_test "older/test/wayland_test.c")
target_compile_options(vyse_wayland_test PRIVATE -O1 -Wall -Werror)
# (vyse_wayland first: as in the package, its two functions are the ones the program gets)
target_link_libraries(vyse_wayland_test PRIVATE vyse_wayland vyse_fake_wayland_old)
set_target_properties(vyse_wayland_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/wayland_test"
  SKIP_BUILD_RPATH TRUE)

# What goes into lib/ beside the runner, next to the plugin itself.
set(VYSE_BUNDLED
  "$<TARGET_FILE:quickjs_c_bridge_plugin>"
  "$<TARGET_FILE:vyse_fallback>"
  "$<TARGET_FILE:vyse_wayland>"
  "$<TARGET_FILE:vyse_sdevent>"
  "$<TARGET_FILE:vyse_wlegl>"
  "$<TARGET_FILE:vyse_start>"
  "$<TARGET_FILE:vyse_sdl>"
)
# A party's voice call, listening (packages/vyse_webos/voice: Go, built with this NDK by
# tool/webos/build.sh before LG's tool runs). Without it the app says voice is not here.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/libvyse_voice.so")
  list(APPEND VYSE_BUNDLED "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/libvyse_voice.so")
endif()
set(vyse_webos_bundled_libraries ${VYSE_BUNDLED} PARENT_SCOPE)
