#!/usr/bin/env bash
# Makes the package for older webOS out of the one LG's tool built for webOS 26.
#
#     tool/webos/older.sh <the folder LG's tool packed from> <where the new .ipk goes> [<LG's build folder>]
#
# Called by build.sh; nothing to run by hand. See webos/README.md, "Older webOS".
#
# Why a second package. LG's Flutter engine and the program built around it need the system
# runtime of webOS 26 (glibc 2.38 and its C++ library). On an older TV the TV's own loader
# refuses the program before a line of it runs. A program does not have to use the TV's
# runtime, though: it can name a loader of its own and bring a runtime with it, and the TV's
# libraries then run on top of that newer runtime, which is the direction that works (a
# library made for an old runtime runs on a new one, never the other way round).
#
# What is done to the copy, and nothing else differs from the webOS 26 package:
#
#   1. runtime/ is added: the loader, glibc and the C++ library of Debian 13 for 32-bit
#      soft-float ARM, the same kind of code as a webOS TV's. Debian's, because they are open,
#      exact (four packages, each checked against its checksum) and made to run on any kernel
#      since 3.2. (Not the copies in LG's NDK: those are LG's to hand out, and made for the
#      kernel of webOS 26.)
#   2. The app's program is told to start under that loader, to look in runtime/ first, and to
#      load the whole runtime before anything else, so that no library of the TV pulls in a
#      piece of the TV's own older runtime beside it. Its name and place stay what they were:
#      the TV still starts the same file.
#   3. LG's embedder is pointed at two stand-ins instead of two libraries of the TV that an
#      older webOS lacks or calls otherwise (packages/vyse_webos/webos/older); and two small
#      libraries are made part of the program: one keeps a record of the start, one stands
#      between the embedder and the TV's Wayland library.
#
# The loader's place is written into the program in full, so this package runs from where
# Developer Mode installs apps and nowhere else.

set -euo pipefail

PACKED="${1:?the folder the webOS 26 package was made from}"
OUT_DIR="${2:?where the new .ipk goes}"
BUILT="${3:-}"
HOME_DIR="${VYSE_WEBOS_HOME:-$HOME/.cache/vysetv-webos}"
WORK="$HOME_DIR/older"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Debian 13 (trixie), armel. Path in the archive, then sha256 (Debian's own, from its index).
DEBIAN="https://deb.debian.org/debian"
# (kept for ever, should Debian's own mirror have moved on to a newer build)
DEBIAN_KEPT="https://snapshot.debian.org/archive/debian/20261126T000000Z"
RUNTIME_PACKAGES=(
  "pool/main/g/glibc/libc6_2.41-12+deb13u5_armel.deb e6d49111722906c475ba891b613161f1359e4d15e5e86efc68533bbf846eafdb"
  "pool/main/g/gcc-14/libstdc++6_14.2.0-19_armel.deb 8067dee08a90833f1018421d2b41216e51948d0642239c5a1f8522434b70281f"
  "pool/main/g/gcc-14/libgcc-s1_14.2.0-19_armel.deb 2a7efceac4acc13ee23ff73fee1ca3e865baa2b09b9537f0d8496fac7dff7d4f"
  "pool/main/g/gcc-14/libatomic1_14.2.0-19_armel.deb 133a0a2dbaeff15a8264b15b13c557f23fcd67cdc85c001c9bfc04ecaef953b3"
)
# What of them goes along: the loader, glibc whole (its parts must all be of one build), the
# C++ library and the two compiler helpers.
RUNTIME_FILES=(
  ld-linux.so.3 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2
  libutil.so.1 libanl.so.1 libnss_dns.so.2 libnss_files.so.2
  libstdc++.so.6 libgcc_s.so.1 libatomic.so.1
)
# Loaded with the program itself, before any library of the TV asks for one of them by name.
RUNTIME_FIRST=(libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2 libutil.so.1 libanl.so.1)

command -v patchelf >/dev/null 2>&1 || { echo "patchelf is not installed (tool/webos/setup.sh installs it)." >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb is not installed." >&2; exit 1; }

echo "   the runtime (Debian 13, armel)"
mkdir -p "$HOME_DIR/runtime/debs"
rm -rf "$HOME_DIR/runtime/root"
mkdir -p "$HOME_DIR/runtime/root"
for entry in "${RUNTIME_PACKAGES[@]}"; do
  path="${entry%% *}"
  sum="${entry##* }"
  deb="$HOME_DIR/runtime/debs/$(basename "$path")"
  if ! echo "$sum  $deb" | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$deb" "$DEBIAN/$path" || curl -fsSL --retry 3 -o "$deb" "$DEBIAN_KEPT/$path"
    echo "$sum  $deb" | sha256sum -c - >/dev/null || { echo "$(basename "$path") is not the file expected (checksum)." >&2; exit 1; }
  fi
  dpkg-deb -x "$deb" "$HOME_DIR/runtime/root"
  echo "     $(basename "$path")"
done
FROM="$HOME_DIR/runtime/root/usr/lib/arm-linux-gnueabi"

rm -rf "$WORK"
mkdir -p "$WORK"
# (with every file's "this is a program" mark and the open data folder as they are)
cp -a "$PACKED" "$WORK/data"
INFO="$(find "$WORK/data" -type f -name appinfo.json | head -n 1)"
[ -n "$INFO" ] || { echo "no appinfo.json under $PACKED" >&2; exit 1; }
APP="$(dirname "$INFO")"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$INFO")"
MAIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["main"])' "$INFO")"
# Where Developer Mode puts an app, on every webOS.
INSTALLED="/media/developer/apps/usr/palm/applications/$ID"

mkdir -p "$APP/runtime"
for f in "${RUNTIME_FILES[@]}"; do
  [ -e "$FROM/$f" ] || { echo "Debian's packages have no $f" >&2; exit 1; }
  cp -L "$FROM/$f" "$APP/runtime/$f"
  chmod 644 "$APP/runtime/$f"
done
chmod 755 "$APP/runtime/ld-linux.so.3"
cat > "$APP/runtime/README.txt" <<'NOTICE'
The system runtime VyseTV brings along on an older webOS: the loader (ld-linux.so.3), the GNU C
Library and the GNU C++ runtime, unchanged, as Debian 13 ("trixie") builds them for armel.

  libc6       2.41-12+deb13u5   GNU C Library, LGPL-2.1-or-later
  libstdc++6  14.2.0-19         GNU Standard C++ Library, GPL-3.0-or-later with the GCC Runtime Library Exception
  libgcc-s1   14.2.0-19         GCC support library, GPL-3.0-or-later with the GCC Runtime Library Exception
  libatomic1  14.2.0-19         GCC atomic helpers, GPL-3.0-or-later with the GCC Runtime Library Exception

Their source is Debian's: https://sources.debian.org/src/glibc/2.41-12+deb13u5/ and
https://sources.debian.org/src/gcc-14/14.2.0-19/ (and for ever at https://snapshot.debian.org).
You may replace these files with builds of your own: they are found by name, in this folder.
NOTICE

echo "   the program: its own loader, its own runtime first"
ADD=(--add-needed libvyse_start.so --add-needed libvyse_wayland.so)
for f in "${RUNTIME_FIRST[@]}"; do ADD+=(--add-needed "$f"); done
# (single quotes: $ORIGIN is the loader's word for "where this program is", not the shell's)
patchelf --set-interpreter "$INSTALLED/runtime/ld-linux.so.3" \
  --force-rpath --set-rpath '$ORIGIN/runtime:$ORIGIN:$ORIGIN/lib' \
  "${ADD[@]}" "$APP/$MAIN"

echo "   LG's embedder: the two stand-ins"
patchelf --replace-needed libsystemd.so.0 libvyse_sdevent.so \
  --replace-needed libwayland-egl.so.1 libvyse_wlegl.so \
  "$APP/lib/libflutter_webos_media.so"
chmod 755 "$APP/$MAIN"

echo "   as it now stands:"
echo "     loader:  $(patchelf --print-interpreter "$APP/$MAIN")"
echo "     looks in: $(patchelf --print-rpath "$APP/$MAIN")"
echo "     program needs:  $(patchelf --print-needed "$APP/$MAIN" | tr '\n' ' ')"
echo "     embedder needs: $(patchelf --print-needed "$APP/lib/libflutter_webos_media.so" | tr '\n' ' ')"
for want in libvyse_start.so libvyse_wayland.so libvyse_sdevent.so libvyse_wlegl.so libvyse_fallback.so; do
  [ -f "$APP/lib/$want" ] || { echo "lib/$want is not in the package LG's tool built" >&2; exit 1; }
done

# A start without a TV. An emulator runs the program from the place it will be installed in,
# under the loader it names, and the loader is asked to say where it finds each library
# instead of going on (the way `ldd` asks). What must hold: every piece of the runtime comes
# from runtime/, every library of the package is found, and what is not found is the TV's own
# and nothing else. That is the whole of what can be tried without a TV.
if command -v qemu-arm-static >/dev/null 2>&1; then
  echo "   a start without a TV (emulated: where the loader finds each library)"
  ROOT="$WORK/root"
  mkdir -p "$ROOT$INSTALLED"
  cp -a "$APP/." "$ROOT$INSTALLED/"
  FOUND="$(QEMU_LD_PREFIX="$ROOT" timeout 120 qemu-arm-static -E LD_TRACE_LOADED_OBJECTS=1 "$ROOT$INSTALLED/$MAIN" 2>&1 || true)"
  printf '%s\n' "$FOUND" | sed "s#$ROOT##" | sed 's/^[[:space:]]*/     /'
  BAD=0
  for f in libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1 libatomic.so.1 "${RUNTIME_FIRST[@]}"; do
    if ! printf '%s\n' "$FOUND" | grep -F "$f =>" | grep -q "/runtime/$f"; then
      echo "   $f does not come from the package's runtime" >&2
      BAD=1
    fi
  done
  for f in libvyse_start.so libvyse_wayland.so libvyse_sdevent.so libvyse_wlegl.so libvyse_fallback.so libflutter_webos_media.so libflutter_engine.so libvyse_webos_plugin.so; do
    if ! printf '%s\n' "$FOUND" | grep -F "$f =>" | grep -q "/lib/$f"; then
      echo "   $f of the package is not found" >&2
      BAD=1
    fi
  done
  if printf '%s\n' "$FOUND" | grep -E 'libsystemd\.so|libwayland-egl\.so' >/dev/null; then
    echo "   the embedder still asks for a library an older TV lacks" >&2
    BAD=1
  fi
  # (a stand-in must carry the version names the embedder asks the real library for)
  if printf '%s\n' "$FOUND" | grep -E 'libvyse_[a-z]+\.so: (no version information|version .* not found)' >/dev/null; then
    echo "   a stand-in lacks a version name the embedder asks for" >&2
    BAD=1
  fi
  # (the app's requests must go through vyse_wayland: named before LG's embedder, which is
  # before the TV's own Wayland library)
  ORDER="$(printf '%s\n' "$FOUND" | grep -n -E 'libvyse_wayland\.so =>|libflutter_webos_media\.so =>' | cut -d: -f1 | tr '\n' ' ')"
  set -- $ORDER
  if [ "$#" -ne 2 ] || [ "$1" -ge "$2" ]; then
    echo "   libvyse_wayland.so is not ahead of LG's embedder" >&2
    BAD=1
  fi
  [ "$BAD" = 0 ] || { echo "The package for older webOS would not start right." >&2; exit 1; }
  # (and for the record, what the program says when run for real here: it stops at the first
  # library only a TV has)
  QEMU_LD_PREFIX="$ROOT" timeout 60 qemu-arm-static "$ROOT$INSTALLED/$MAIN" 2>&1 | head -n 3 | sed "s#$ROOT##" | sed 's/^/     run: /' || true
  rm -rf "$ROOT"

  # The library between the embedder and the TV's Wayland library, tried for real: the test
  # program of packages/vyse_webos/webos/older/test, with the packaged libvyse_wayland.so, on
  # the packaged runtime, against a stand-in for an older TV's Wayland library and a newer's.
  TEST="$([ -n "$BUILT" ] && find "$BUILT" -type f -name vyse_wayland_test 2>/dev/null | head -n 1 || true)"
  if [ -n "$TEST" ]; then
    for shape in old new; do
      echo "   requests to the compositor, tried against a stand-in for the Wayland library of a TV ($shape)"
      FAKE="$(dirname "$TEST")/fake-$shape"
      [ -f "$FAKE/libvyse_fake_wayland.so" ] || { echo "no stand-in library in $FAKE" >&2; exit 1; }
      (cd "$WORK" && timeout 120 qemu-arm-static "$APP/runtime/ld-linux.so.3" --library-path "$APP/runtime:$APP/lib:$FAKE" "$TEST" "$shape") \
        || { echo "The package for older webOS would not talk to the compositor right." >&2; exit 1; }
    done
  elif [ -n "$BUILT" ]; then
    echo "The test of libvyse_wayland.so was not built (looked under $BUILT)." >&2
    exit 1
  fi
else
  echo "   (no qemu-arm-static here: the start without a TV is skipped)"
fi

echo "   the package"
mkdir -p "$WORK/ipk" "$OUT_DIR"
# (the tree ares-package wants is the app's folder; it names the .ipk itself)
(cd "$WORK/ipk" && ares-package --no-minify "$APP" -o "$WORK/ipk")
MADE="$(ls -t "$WORK/ipk"/*.ipk 2>/dev/null | head -n 1 || true)"
[ -n "$MADE" ] || { echo "ares-package made no .ipk in $WORK/ipk" >&2; exit 1; }
NAME="$(basename "$MADE" .ipk)_older-webos.ipk"
cp -f "$MADE" "$OUT_DIR/$NAME"
echo "$OUT_DIR/$NAME"
