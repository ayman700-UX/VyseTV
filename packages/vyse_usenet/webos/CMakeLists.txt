# VyseTV: the Usenet engine for an LG webOS TV.
#
# Nothing is compiled here. LG's Flutter tool includes this folder for a package that says
# `webos: ffiPlugin: true`, and ships whatever it lists in <package>_bundled_libraries in the
# app's lib/ folder, next to the runner; the app starts it as a program of its own, as on a
# desktop (lib/data/usenet/usenet_engine.dart).
#
# The engine is built statically for 32-bit ARM (tool/build_engine.py webos-arm): no C library
# of the TV's is used, so it runs on webOS 26 and with the older-webOS package's own runtime
# alike.
cmake_minimum_required(VERSION 3.19)
project(vyse_usenet LANGUAGES NONE)

include("${CMAKE_CURRENT_SOURCE_DIR}/../tool/unpack.cmake")
vyse_usenet_unpack("webos-arm" "vyse-usenet" VYSE_USENET_BIN)

set(vyse_usenet_bundled_libraries
  "${VYSE_USENET_BIN}"
  PARENT_SCOPE
)
