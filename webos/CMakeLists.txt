cmake_minimum_required(VERSION 3.19)
project(runner LANGUAGES CXX)

# The whole build graph is LG's: their tool writes it for each build (the engine, their
# embedder, the plugins of this build's pubspec, the bundle's layout). See webos/README.md
# for how this folder is built; it is never built in place, and not with the Flutter the
# other platforms use.
include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)

# The torrent engine travels in lib/ as a plugin's "bundled library" (packages/
# torrserver_flutter/webos). It is a program, and nothing here can keep it marked as one:
# LG's graph installs bundled libraries as plain files, and their tool then copies the bundle
# into the package file by file, which drops the mark from everything but the main program.
# tool/webos/build.sh puts it back in the folder the package is made from. (Should it be lost
# on the way to the TV all the same, the app copies the engine to its data folder and marks
# it there.)
