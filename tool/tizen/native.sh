#!/usr/bin/env bash
# Builds the two libraries a Samsung TV package carries besides Flutter's, after
# tool/tizen/setup.sh, into the folder given (tool/tizen/build.sh puts them in each package's
# lib/, through tizen/Runner.csproj):
#
#  * libquickjs_c_bridge_plugin.so: the JavaScript engine scraper plugins run in. flutter_js
#    calls it by that name; it ships it for desktop PCs only. Built from the same source and
#    commit the LG build uses (packages/vyse_webos/webos/CMakeLists.txt), with the one function
#    it lacks (quickjs_memory_limit.cc), by the Tizen SDK's own `tizen build-native`, as
#    flutter-tizen builds plugins' C++.
#  * libtorrserver.so: the torrent engine, inside the app's process
#    (packages/torrserver_flutter/tool/go-shim/build-tizen-so.sh).
#
# Both are built for 32-bit ARM against Tizen 6.0, which every newer TV runs too.
#
#   bash tool/tizen/native.sh <output folder>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?output folder}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TS="${TIZEN_STUDIO:-$HOME/tizen-studio}"
export PATH="$PATH:$TS/tools/ide/bin"
WORK="${VYSE_TIZEN_TOOLS:-$HOME/.cache/vysetv-tizen}/native"
mkdir -p "$WORK"

QJS_REPO="https://github.com/abner/quickjs-c-bridge.git"
QJS_COMMIT="7204d9bf1afbe0550d51d7decdcce398b2c22e1a"
ROOTSTRAP="iot-headed-6.0-device.core"

echo "== QuickJS (quickjs-c-bridge ${QJS_COMMIT:0:12})"
src="$WORK/quickjs-c-bridge"
if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" remote add origin "$QJS_REPO"
fi
git -C "$src" fetch -q --depth 1 origin "$QJS_COMMIT"
git -C "$src" checkout -q --force FETCH_HEAD
have="$(git -C "$src" rev-parse HEAD)"
if [ "$have" != "$QJS_COMMIT" ]; then
  echo "quickjs-c-bridge is at $have, not $QJS_COMMIT"
  exit 1
fi

proj="$WORK/quickjs_project"
rm -rf "$proj"
mkdir -p "$proj/src/quickjs"
cp "$src"/cxx/quickjs/*.c "$src"/cxx/quickjs/*.h "$proj/src/quickjs/"
cp "$src/cxx/libfastdev_quickjs_runtime.cpp" "$proj/src/"
cp "$REPO/packages/vyse_webos/webos/quickjs_memory_limit.cc" "$proj/src/"
# (the version QuickJS reports, which its build gives it as a define: here at the top of its file)
version="$(tr -d '\r\n' < "$src/cxx/quickjs/VERSION")"
{ printf '#define CONFIG_VERSION "%s"\n' "$version"; cat "$src/cxx/quickjs/quickjs.c"; } > "$proj/src/quickjs/quickjs.c"
cat > "$proj/project_def.prop" <<'PROP'
APPNAME = quickjs_c_bridge_plugin
type = sharedLib
profile = tv-6.0

USER_SRCS = src/quickjs/cutils.c src/quickjs/libregexp.c src/quickjs/libunicode.c src/quickjs/quickjs.c src/libfastdev_quickjs_runtime.cpp src/quickjs_memory_limit.cc
USER_DEFS = _GNU_SOURCE
USER_CPP_DEFS = _GNU_SOURCE
USER_INC_DIRS = src
USER_LIBS = pthread m
PROP
USER_CPP_OPTS='-std=c++17' tizen build-native -C Release -a arm -c gcc -r "$ROOTSTRAP" \
  -e "-O2 -w -Wl,-soname,libquickjs_c_bridge_plugin.so" -- "$proj"
cp "$proj/Release/libquickjs_c_bridge_plugin.so" "$OUT/"

echo "== the torrent engine"
bash "$REPO/packages/torrserver_flutter/tool/go-shim/build-tizen-so.sh" "$OUT"

echo "== what was built"
for lib in "$OUT"/*.so; do
  file "$lib"
  readelf -d "$lib" | grep -E 'SONAME|NEEDED' || true
done
# (what flutter_js and the app look up in each; a name missing here fails every plugin or torrent)
for sym in jsSetMemoryLimit jsNewRuntime jsNewContext jsEval jsFreeRuntime jsCall jsNewString; do
  readelf --dyn-syms -W "$OUT/libquickjs_c_bridge_plugin.so" | grep -v " UND " | grep -qw "$sym" || { echo "libquickjs_c_bridge_plugin.so has no $sym"; exit 1; }
done
for sym in TorrServerStart TorrServerStop TorrServerIsRunning TorrServerFree; do
  readelf --dyn-syms -W "$OUT/libtorrserver.so" | grep -v " UND " | grep -qw "$sym" || { echo "libtorrserver.so has no $sym"; exit 1; }
done
echo "native libraries ready in $OUT"
