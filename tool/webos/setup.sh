#!/usr/bin/env bash
# Sets a Linux machine up to build VyseTV for LG webOS. Run once; safe to run again.
#
#     tool/webos/setup.sh [--accept-lg-ndk-license]
#
# Where: Ubuntu 22.04, 24.04 or 26.04, the only hosts LG's Flutter SDK supports. On Windows
# that is WSL2 (an Ubuntu from the Store) or a container; on a Mac a container or a VM.
#
# What it puts in place, all of it LG's own or what LG's guide asks for
# (github.com/lg-flutter-webos/flutter-webos, doc/getting-started.md), the way LG's own
# container recipe does it (github.com/lg-flutter-webos/devcontainer):
#
#   1. the packages a Flutter Linux build needs (apt, asks for your password)
#   2. LG's Flutter tool, `flutter-webos`, at the commit VyseTV was written against. It brings
#      its own Flutter (3.38.10): the project's pinned one is never touched.
#   3. Node.js 22 and LG's webOS CLI (the `ares-*` commands), which make the .ipk. It goes in
#      a folder of its own and replaces no Node you have.
#   4. LG's webOS NDK: the compiler and the TV's own libraries (a 341 MB download).
#
# The NDK comes under LG's "LG SDK License Agreement". Its installer shows the agreement and
# asks; this script lets it ask. Only with --accept-lg-ndk-license does it answer for you, and
# passing that is you accepting LG's terms, nobody else.
#
# Everything lives under ~/.cache/vysetv-webos (VYSE_WEBOS_HOME to change it); nothing but
# the apt packages needs root.

set -euo pipefail

ACCEPT=no
for arg in "$@"; do
  case "$arg" in
    --accept-lg-ndk-license) ACCEPT=yes ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

HOME_DIR="${VYSE_WEBOS_HOME:-$HOME/.cache/vysetv-webos}"
SDK="$HOME_DIR/flutter-webos"
NODE_DIR="$HOME_DIR/node"

# LG's tool, at the commit its source was read at for this port.
SDK_URL="https://github.com/lg-flutter-webos/flutter-webos.git"
SDK_REF="950398131830e9bd5dc91e588c3db8f5c42322be"

# Node.js for the webOS CLI. LG's guide still says 14.15.1 to 16.20.2, but the CLI it has
# you install (3.2.6) refuses anything under 20: its packager stops with "only works on
# Node.js version: >=20.0.0". So: the long-term-support 22, and the CLI at the version read.
NODE_VERSION="v22.23.5"
NODE_SHA256="cdeb8670a0c81f51b4dc4ac61919f9b1ad917b304bf8221eb939570663d240f8" # nodejs.org's own, for linux-x64
ARES_CLI="@webos-tools/cli@3.2.6"

NDK_VERSION="11.2.0"
NDK_FILE="webos-ndk-flutter-starfish-x86_64-ca9v1-$NDK_VERSION.sh"
NDK_URL="https://github.com/lg-flutter-webos/ndk/releases/download/$NDK_VERSION/$NDK_FILE"
NDK_DIR="$HOME_DIR/ndk/$NDK_VERSION"

say() { printf '\n== %s\n' "$*"; }

# The NDK's settings file: one you named, the one this script installs, or one put where
# LG's guide puts it.
ndk_env() {
  if [ -n "${WEBOS_FLUTTER_NDK_ENV:-}" ] && [ -f "$WEBOS_FLUTTER_NDK_ENV" ]; then echo "$WEBOS_FLUTTER_NDK_ENV"; return; fi
  # (a folder that is not there is no fault here)
  { find "$NDK_DIR" /usr/local/starfish-sdk-x86_64 -maxdepth 1 -name 'environment-setup-*' 2>/dev/null || true; } | head -n 1
}

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "LG's Flutter SDK builds on 64-bit Intel/AMD Linux only (this is $(uname -s) $(uname -m))." >&2
  exit 1
fi
case "$(pwd -P)" in
  /mnt/[a-z]/*) echo "note: this is a Windows folder seen from WSL. That is fine: the build itself is done in a copy under $HOME_DIR." ;;
esac
mkdir -p "$HOME_DIR"

say "1. packages (apt)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  curl wget unzip xz-utils cmake make pkg-config file git git-lfs ninja-build clang binutils python3 ca-certificates \
  libgtk-3-0 libgtk-3-dev liblzma-dev libglu1-mesa patchelf dpkg
# (to try the older-webOS package's start without a TV; the build goes on without it)
sudo apt-get install -y --no-install-recommends qemu-user-static >/dev/null 2>&1 || true
# (the C++ library's headers, by whichever name this Ubuntu has them: LG's recipe names one)
for p in libstdc++-12-dev libstdc++-10-dev; do
  if sudo apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then break; fi
done

say "2. LG's Flutter tool"
if [ ! -d "$SDK/.git" ]; then
  git clone "$SDK_URL" "$SDK"
fi
git -C "$SDK" fetch --quiet origin
git -C "$SDK" checkout --quiet "$SDK_REF"

say "3. Node.js $NODE_VERSION and the webOS CLI"
if [ ! -x "$NODE_DIR/bin/node" ] || [ "$("$NODE_DIR/bin/node" --version)" != "$NODE_VERSION" ]; then
  tarball="$HOME_DIR/node-$NODE_VERSION-linux-x64.tar.xz"
  curl -fL --retry 3 -o "$tarball" "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.xz"
  echo "$NODE_SHA256  $tarball" | sha256sum -c -
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$tarball" -C "$NODE_DIR" --strip-components=1
  rm -f "$tarball"
fi
export PATH="$NODE_DIR/bin:$PATH"
if ! command -v ares-package >/dev/null 2>&1; then
  npm install --global --prefix "$NODE_DIR" "$ARES_CLI"
fi
# (asked for real: a CLI that will not run on this Node says so here, not at the end of a build)
ares -V
ares-package --version

say "4. LG's webOS NDK $NDK_VERSION"
NDK_ENV="$(ndk_env)"
if [ -n "$NDK_ENV" ]; then
  echo "already there: $NDK_ENV"
else
  # The installer shows LG's agreement and asks. With nobody at a keyboard it cannot ask, and
  # this script does not answer for you unless you said so.
  if [ "$ACCEPT" != "yes" ] && [ ! -t 0 ]; then
    echo "LG's webOS NDK is under the LG SDK License Agreement, which its installer shows and asks about." >&2
    echo "Run this in a terminal to read and answer it yourself, or pass --accept-lg-ndk-license if you accept it." >&2
    exit 1
  fi
  mkdir -p "$NDK_DIR"
  installer="$HOME_DIR/ndk/$NDK_FILE"
  if [ ! -f "$installer" ]; then
    curl -fL --retry 3 -o "$installer.part" "$NDK_URL"
    mv "$installer.part" "$installer"
  fi
  chmod +x "$installer"
  echo
  echo "LG's NDK is licensed under the LG SDK License Agreement. Its installer shows it."
  # (it can end with an error code after a good install: what counts is whether its settings
  # file is there afterwards, as LG's own recipe checks)
  if [ "$ACCEPT" = "yes" ]; then
    echo "You passed --accept-lg-ndk-license: answering its questions with yes for you."
    "$installer" -y -d "$NDK_DIR" || true
  else
    echo "Read it and answer the installer yourself."
    "$installer" -d "$NDK_DIR" || true
  fi
  NDK_ENV="$(ndk_env)"
  if [ -z "$NDK_ENV" ]; then
    echo "The NDK did not install: no environment-setup file under $NDK_DIR." >&2
    exit 1
  fi
  rm -f "$installer"
fi

say "5. the engine LG built for the TV, and a look at the whole"
# (LG's tool reads the NDK's settings itself, from the file named here)
export PATH="$SDK/bin:$NODE_DIR/bin:$PATH"
export WEBOS_FLUTTER_NDK_ENV="$NDK_ENV"
flutter-webos precache
# (says what is missing; Android and Chrome may be, and are not needed. With a time limit
# and nothing to read from: on a machine that has Android's tools its Android check can sit
# waiting for an answer nobody is there to give, which once held a whole build up.)
timeout 180 flutter-webos doctor -v </dev/null || true

say "ready"
echo "Build with: tool/webos/build.sh"
