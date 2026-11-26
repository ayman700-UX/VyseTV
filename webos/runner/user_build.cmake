# The runner's own sources and include directories (LG's tool assembles the rest).
#
# The runner is LG's template as it comes. VyseTV's native code for webOS is not here but in
# packages/vyse_webos, a plugin LG's tool builds and registers by itself.

set(USER_APP_EXTRA_SRCS
  runner/main.cc
)

set(USER_APP_EXTRA_INCLUDE_DIRS
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/runner
)
