# The Usenet engine for Linux: vyse-usenet for this build's processor, unpacked from
# ../binaries and shipped in the bundle's lib/ folder (with the AppImage). Flutter installs it
# there as a plain file; the app makes a runnable copy of it when the bundle's own copy can't
# be run (lib/data/usenet/usenet_engine.dart).
cmake_minimum_required(VERSION 3.19)
project(vyse_usenet LANGUAGES NONE)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(VYSE_USENET_TARGET "linux-arm64")
else()
  set(VYSE_USENET_TARGET "linux-amd64")
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/../tool/unpack.cmake")
vyse_usenet_unpack("${VYSE_USENET_TARGET}" "vyse-usenet" VYSE_USENET_BIN)

set(vyse_usenet_bundled_libraries
  "${VYSE_USENET_BIN}"
  PARENT_SCOPE
)
