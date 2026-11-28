# The Usenet engine for Windows: vyse-usenet.exe, unpacked from ../binaries and shipped next to
# the app's own program (Flutter installs an FFI plugin's "bundled libraries" there). The app
# starts it (lib/data/usenet/usenet_engine.dart).
cmake_minimum_required(VERSION 3.19)
project(vyse_usenet LANGUAGES NONE)

include("${CMAKE_CURRENT_SOURCE_DIR}/../tool/unpack.cmake")
vyse_usenet_unpack("windows-amd64" "vyse-usenet.exe" VYSE_USENET_EXE)

set(vyse_usenet_bundled_libraries
  "${VYSE_USENET_EXE}"
  PARENT_SCOPE
)
