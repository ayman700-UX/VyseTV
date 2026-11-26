# VyseTV: the engine for an LG webOS TV.
#
# Nothing is compiled here. LG's Flutter tool includes this folder for a package that says
# `webos: ffiPlugin: true`, and ships whatever it lists in <package>_bundled_libraries in the
# app's lib/ folder, next to the runner. That is how the engine gets into the .ipk; the app
# starts it as a program of its own, as on a desktop (lib/src/binary_locator.dart looks in
# lib/ beside the executable).
#
# The engine is TorrServer's own `TorrServer-linux-arm7` build of the release the other
# platforms ship: a static program (no C library, so it does not care which glibc a TV has)
# for 32-bit ARM, which is what every webOS TV runs, 64-bit kernel or not.

cmake_minimum_required(VERSION 3.18)
project(torrserver_flutter LANGUAGES CXX)

set(TORRSERVER_ARCHIVE "${CMAKE_CURRENT_SOURCE_DIR}/../binaries/torrserver-linux-arm7.tar.gz")
set(TORRSERVER_NAME "torrserver-linux-arm7")
# (MatriX.147's TorrServer-linux-arm7, as GitHub serves it)
set(TORRSERVER_SHA256 "2c70daa57ebbc390024ef5276bdf2dda905ea1cb6e61eb791ba2c706b1505f16")
set(TORRSERVER_DIR "${CMAKE_CURRENT_BINARY_DIR}/engine")
set(TORRSERVER_BIN "${TORRSERVER_DIR}/${TORRSERVER_NAME}")

if(NOT EXISTS "${TORRSERVER_ARCHIVE}")
  message(FATAL_ERROR "The TV's torrent engine is missing: ${TORRSERVER_ARCHIVE}")
endif()

file(MAKE_DIRECTORY "${TORRSERVER_DIR}")
file(ARCHIVE_EXTRACT INPUT "${TORRSERVER_ARCHIVE}" DESTINATION "${TORRSERVER_DIR}")
if(NOT EXISTS "${TORRSERVER_BIN}")
  message(FATAL_ERROR "${TORRSERVER_ARCHIVE} holds no ${TORRSERVER_NAME}")
endif()
file(SHA256 "${TORRSERVER_BIN}" TORRSERVER_GOT)
if(NOT TORRSERVER_GOT STREQUAL TORRSERVER_SHA256)
  message(FATAL_ERROR "${TORRSERVER_NAME} is not the build expected here (sha256 ${TORRSERVER_GOT})")
endif()

set(torrserver_flutter_bundled_libraries
  "${TORRSERVER_BIN}"
  PARENT_SCOPE
)
