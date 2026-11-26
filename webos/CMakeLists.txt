cmake_minimum_required(VERSION 3.19)
project(runner LANGUAGES CXX)

# The whole build graph is LG's: their tool writes it for each build (the engine, their
# embedder, the plugins of this build's pubspec, the bundle's layout). See webos/README.md
# for how this folder is built; it is never built in place, and not with the Flutter the
# other platforms use.
include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)

# The torrent engine travels in lib/ as a plugin's "bundled library" (packages/
# torrserver_flutter/webos), and LG's graph installs those as plain files. It is a program:
# mark it so, here, after their install rules have run. (An app on a TV cannot change the
# modes of its own files: they are root's. Should the mark be lost on the way to the TV all
# the same, the app copies the engine to its data folder and marks it there.)
install(CODE "
  set(_engine \"${INSTALL_BUNDLE_LIB_DIR}/torrserver-linux-arm7\")
  if(EXISTS \"\${_engine}\")
    file(CHMOD \"\${_engine}\" PERMISSIONS
      OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  endif()
  " COMPONENT Runtime)
