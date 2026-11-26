#!/usr/bin/env bash
# Builds VyseTV's installable package (.ipk) for LG webOS.
#
#     tool/webos/build.sh [--install <tv>] [--debug]
#
# Linux only, after tool/webos/setup.sh has run once on this machine (see webos/README.md).
# Two packages come out in build/webos/ of this repository: one for webOS 26, as LG's tool
# makes it, and one for older webOS (..._older-webos.ipk), which is the same build on a
# runtime of its own (tool/webos/older.sh).
#
#   --install <tv>   also puts the right one on a TV in Developer Mode: <tv> is the name you
#                    gave the TV with `ares-setup-device` (see webos/README.md)
#   --debug          a debug build instead of a release one (slower; for looking for a fault)
#
# What it does: lays out the copy LG's tool can build (stage.py: the same lib/, a pubspec
# their older Flutter can resolve), in ~/.cache/vysetv-webos/stage, which is on the Linux
# side even when the repository is a Windows folder seen from WSL (a build there fails).
# Then LG's `flutter-webos build webos`, and a look inside the package for the parts that
# are easy to lose on the way: the torrent engine, still marked as a program, and the
# JavaScript engine the scraper plugins run in.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_DIR="${VYSE_WEBOS_HOME:-$HOME/.cache/vysetv-webos}"
SDK="${FLUTTER_WEBOS:-$HOME_DIR/flutter-webos}"
NODE_DIR="$HOME_DIR/node"
STAGE="$HOME_DIR/stage"

MODE=release
TV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) TV="${2:?--install needs the name of the TV}"; shift 2 ;;
    --debug) MODE=debug; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# The NDK's settings file: one you named, the one setup.sh installs, or one put where LG's
# guide puts it.
if [ -n "${WEBOS_FLUTTER_NDK_ENV:-}" ] && [ -f "$WEBOS_FLUTTER_NDK_ENV" ]; then
  NDK_ENV="$WEBOS_FLUTTER_NDK_ENV"
else
  NDK_ENV="$({ find "$HOME_DIR"/ndk/*/ /usr/local/starfish-sdk-x86_64 -maxdepth 1 -name 'environment-setup-*' 2>/dev/null || true; } | head -n 1)"
fi

missing() { echo "$1" >&2; echo "Run tool/webos/setup.sh first." >&2; exit 1; }
[ "$(uname -s)" = "Linux" ] || { echo "LG's Flutter SDK builds on Linux only." >&2; exit 1; }
[ -x "$SDK/bin/flutter-webos" ] || missing "LG's Flutter tool is not at $SDK."
[ -n "$NDK_ENV" ] || missing "LG's webOS NDK is not installed."
export PATH="$SDK/bin:$NODE_DIR/bin:$PATH"
command -v ares-package >/dev/null 2>&1 || missing "The webOS CLI (ares-package) is not installed."

echo "== 0. the party's voice for LG TVs (Go, with this NDK)"
# (without it the package is still made: the app then says voice calls are not on this TV)
VOICE=1
if ! bash "$REPO/packages/vyse_webos/voice/build.sh" "$NDK_ENV"; then
  VOICE=0
  rm -f "$REPO/packages/vyse_webos/webos/prebuilt/libvyse_voice.so"
  echo "::warning::The party's voice for LG TVs did not build: this package has no voice calls." >&2
fi

echo "== 1. the copy LG's tool builds"
python3 "$REPO/tool/webos/stage.py" --out "$STAGE"

echo "== 2. LG's build ($MODE)"
# LG's tool reads the NDK's settings (its compiler, the TV's libraries) itself, from the file
# named here.
export WEBOS_FLUTTER_NDK_ENV="$NDK_ENV"
# (for the record: how LG's header for webOS 26 declares the one call that places the picture
# on a TV without exported windows. The native side uses it only if it is there, and as it is
# declared: packages/vyse_webos/webos/CMakeLists.txt.)
SYSROOT="$(sed -n 's/^export SDKTARGETSYSROOT=//p' "$NDK_ENV" | head -n 1 | tr -d '"' || true)"
if [ -n "$SYSROOT" ] && [ -f "$SYSROOT/usr/include/NDL/NDL_media.h" ]; then
  echo "   NDL_MediaSetDisplayWindow in LG's header: $(grep -n 'NDL_MediaSetDisplayWindow' "$SYSROOT/usr/include/NDL/NDL_media.h" | head -n 2 | tr '\n' ' ' || true)"
fi
cd "$STAGE"
flutter-webos pub get
# VYSE_WEBOS is how the app knows it is on an LG TV (lib/core/platform/webos.dart): the
# system there says it is Linux.
flutter-webos build webos "--$MODE" --dart-define=VYSE_WEBOS=true

IPK="$(ls -t "$STAGE"/build/webos/*/"$MODE"/ipk/*.ipk 2>/dev/null | head -n 1 || true)"
[ -n "$IPK" ] || { echo "LG's tool finished without an .ipk under $STAGE/build/webos." >&2; exit 1; }

# The torrent engine is a program, and LG's tool does not keep it one: it copies the app into
# the package file by file, which drops every "this is a program" mark, and then puts the mark
# back on the app's main program only. So the engine is marked here, in the folder the tool
# packed from, and the package is made again the same way the tool made it.
IPK_DIR="$(dirname "$IPK")"
ENGINE="$(find "$IPK_DIR/data" -type f -path '*/lib/torrserver-linux-arm7' 2>/dev/null | head -n 1 || true)"
if [ -n "$ENGINE" ] && [ ! -x "$ENGINE" ]; then
  echo "== 2b. the torrent engine marked as a program, and the package made again"
  chmod 755 "$ENGINE"
  APP_DIR="$(dirname "$(dirname "$ENGINE")")"
  rm -f "$IPK_DIR"/*.ipk
  (cd "$IPK_DIR" && ares-package --no-minify "$APP_DIR" -o "$IPK_DIR")
  IPK="$(ls -t "$IPK_DIR"/*.ipk 2>/dev/null | head -n 1 || true)"
  [ -n "$IPK" ] || { echo "ares-package made no .ipk in $IPK_DIR." >&2; exit 1; }
fi

# (out of the copy first: a package that fails the look below is still there to be looked at)
mkdir -p "$REPO/build/webos"
cp -f "$IPK" "$REPO/build/webos/"
OUT="$REPO/build/webos/$(basename "$IPK")"

echo "== 3. a look inside the package"
LIST="$(ar p "$IPK" data.tar.gz | tar -tzvf -)"
BAD=0
want() { # want <what it is> <pattern in the listing>
  if printf '%s\n' "$LIST" | grep -Eq -- "$2"; then echo "   ok       $1"; else echo "   MISSING  $1" >&2; BAD=1; fi
}
want "the app's own code (libapp.so)"                      '/lib/libapp\.so$'
want "LG's Flutter engine"                                 '/lib/libflutter_engine\.so$'
want "the player's native side (libvyse_webos_plugin.so)"  '/lib/libvyse_webos_plugin\.so$'
want "the JavaScript engine for scraper plugins"           '/lib/libquickjs_c_bridge_plugin\.so$'
want "the torrent engine"                                  '/lib/torrserver-linux-arm7$'
if [ "$VOICE" = 1 ]; then
  want "the party's voice (libvyse_voice.so)"              '/lib/libvyse_voice\.so$'
else
  echo "   none     the party's voice (it did not build: see step 0)"
fi
want "the torrent engine, marked as a program"             '^-rwx[r-]-x[r-]-x .*/lib/torrserver-linux-arm7$'
want "the app's description for the TV (appinfo.json)"     '/appinfo\.json$'
echo "   its programs and libraries:"
printf '%s\n' "$LIST" | grep -E '/lib/[^/]+$|/appinfo\.json$|^-rwx' | awk '{print "     " $1 "  " $3 "  " $NF}' | sort -u -k3 | head -n 60
if [ "$BAD" != 0 ]; then
  echo "The package is not whole: see above." >&2
  exit 1
fi

echo
echo "Built: $OUT ($(du -h "$OUT" | cut -f1))"

echo "== 4. the package for older webOS"
bash "$REPO/tool/webos/older.sh" "$IPK_DIR/data" "$REPO/build/webos" "$STAGE/build/webos"
OLDER="$(ls -t "$REPO/build/webos"/*_older-webos.ipk 2>/dev/null | head -n 1 || true)"
[ -n "$OLDER" ] || { echo "The package for older webOS did not come out." >&2; exit 1; }
LIST="$(ar p "$OLDER" data.tar.gz | tar -tzvf -)"
BAD=0
want "its own loader, marked as a program"                 '^-rwx[r-]-x[r-]-x .*/runtime/ld-linux\.so\.3$'
want "its own runtime (glibc, the C++ library)"            '/runtime/libc\.so\.6$'
want "the stand-ins for what an older TV lacks"            '/lib/libvyse_sdevent\.so$'
want "the app's program, marked as one"                    '^-rwx[r-]-x[r-]-x .*/vysetv$'
want "the torrent engine, marked as a program"             '^-rwx[r-]-x[r-]-x .*/lib/torrserver-linux-arm7$'
want "the app's own code (libapp.so)"                      '/lib/libapp\.so$'
[ "$BAD" = 0 ] || { echo "The package for older webOS is not whole: see above." >&2; exit 1; }
echo
echo "Built: $OLDER ($(du -h "$OLDER" | cut -f1))"

if [ -n "$TV" ]; then
  echo "== 5. onto the TV ($TV)"
  # Which of the two: the TV says which webOS it is (11 and up is webOS 26).
  MAJOR="$(ares-device --system-info --device "$TV" 2>/dev/null | sed -n 's/^sdkVersion[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1 || true)"
  PICK="$OUT"
  if [ -n "$MAJOR" ] && [ "$MAJOR" -lt 11 ]; then PICK="$OLDER"; fi
  echo "   the TV's webOS (its sdkVersion): ${MAJOR:-not said}; installing $(basename "$PICK")"
  ares-install -d "$TV" "$PICK"
  echo "Installed. Start it from the TV's app list, or: ares-launch -d $TV com.vyse.vysetv"
else
  echo "To put one on a TV in Developer Mode: ares-install -d <tv> <the .ipk>"
  echo "  webOS 26:        $OUT"
  echo "  older webOS:     $OLDER"
fi
