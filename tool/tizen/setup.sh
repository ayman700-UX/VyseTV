#!/usr/bin/env bash
# Installs what VyseTV's Samsung TV packages are built with, on Ubuntu 22.04 (the GitHub job,
# .github/workflows/build.yml, or a Linux PC). Then tool/tizen/build.sh builds them.
#
#  * the Tizen SDK's command-line tools, with its native toolchain and the Tizen 6.0 and 6.5
#    rootstraps (Samsung's TV player plugin has a C++ side, built against them), as flutter-tizen's
#    own plugins are built on GitHub (github.com/flutter-tizen/plugins, .github/workflows)
#  * flutter-tizen, at the release made from the very Flutter this project is pinned to
#  * a Tizen author certificate made here, and a signing profile with it. A package signed with
#    it installs on a TV in Developer Mode that takes Tizen's own distributor certificate; one
#    that wants a Samsung certificate gets the package signed again (tizen/README.md).
#
# The Tizen SDK comes under the Tizen SDK licence, which only the person building can accept:
# the script runs with --accept-tizen-sdk-license and not otherwise.
set -euo pipefail

FLUTTER_TIZEN_TAG="3.47.1-tizen.1.1.2"
# (the commit that tag is at, and the Flutter it pins: the project's own, Flutter 3.47.1)
FLUTTER_TIZEN_COMMIT="7a70c89c3d11bbd97f5919f0a7ab2175e39d26e7"
FLUTTER_COMMIT="6655482ec06e547f90abf8ae7590466f4415978d"
TIZEN_SDK_URL="https://download.tizen.org/sdk/Installer/tizen-sdk_10.0/web-cli_Tizen_SDK_10.0_ubuntu-64.bin"
TIZEN_PACKAGES=(NativeToolchain-Gcc-9.2 IOT-Headed-6.0-NativeAppDevelopment-CLI IOT-Headed-6.5-NativeAppDevelopment-CLI)

# The signing profile the packages are built with (a certificate made on this machine, which
# signs nothing anyone relies on: its password is no secret).
PROFILE="vysetv"
PASSWORD="vysetv-ci"

accepted=0
for a in "$@"; do
  [ "$a" = "--accept-tizen-sdk-license" ] && accepted=1
done
if [ "$accepted" != 1 ]; then
  echo "The Tizen SDK comes under the Tizen SDK licence (shown at https://developer.tizen.org)."
  echo "Read it, and if you accept it run: bash tool/tizen/setup.sh --accept-tizen-sdk-license"
  exit 1
fi

TIZEN_STUDIO="$HOME/tizen-studio"
TOOLS="${VYSE_TIZEN_TOOLS:-$HOME/.cache/vysetv-tizen}"
mkdir -p "$TOOLS"

echo "== system packages the Tizen SDK's tools need"
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update -q
sudo apt-get install -y -q libncurses5 python3.8 libpython3.8 gettext \
  libkf5itemmodels5 libkf5kiowidgets5 libkchart2 dbus-x11 gnome-keyring zip unzip xz-utils file make

echo "== the Tizen SDK's command-line tools"
if [ ! -x "$TIZEN_STUDIO/package-manager/package-manager-cli.bin" ]; then
  curl -fsSL "$TIZEN_SDK_URL" -o "$TOOLS/tizen-sdk.bin"
  chmod a+x "$TOOLS/tizen-sdk.bin"
  "$TOOLS/tizen-sdk.bin" --accept-license "$TIZEN_STUDIO"
  rm -f "$TOOLS/tizen-sdk.bin"
fi
"$TIZEN_STUDIO/package-manager/package-manager-cli.bin" install "${TIZEN_PACKAGES[@]}"

echo "== .NET (the app's Tizen side is C#: a TV takes no other kind of app)"
if ! command -v dotnet >/dev/null; then
  echo "dotnet is not installed (.NET SDK 6 or newer)"
  exit 1
fi
dotnet --version

echo "== flutter-tizen $FLUTTER_TIZEN_TAG"
FT="$TOOLS/flutter-tizen"
if [ ! -d "$FT/.git" ]; then
  git clone --quiet --depth 1 --branch "$FLUTTER_TIZEN_TAG" https://github.com/flutter-tizen/flutter-tizen.git "$FT"
fi
have=$(git -C "$FT" rev-parse HEAD)
if [ "$have" != "$FLUTTER_TIZEN_COMMIT" ]; then
  echo "flutter-tizen is at $have, not $FLUTTER_TIZEN_COMMIT ($FLUTTER_TIZEN_TAG)"
  exit 1
fi
pinned=$(tr -d '[:space:]' < "$FT/bin/internal/flutter.version")
if [ "$pinned" != "$FLUTTER_COMMIT" ]; then
  echo "flutter-tizen $FLUTTER_TIZEN_TAG pins Flutter $pinned, not the project's $FLUTTER_COMMIT"
  exit 1
fi
export PATH="$FT/bin:$PATH"
flutter-tizen --version
flutter-tizen precache --tizen

echo "== a signing profile"
export PATH="$PATH:$TIZEN_STUDIO/tools/ide/bin"
if [ ! -f "$HOME/tizen-studio-data/keystore/author/$PROFILE.p12" ]; then
  dbus-run-session -- bash -c "
    set -e
    echo '$PASSWORD' | gnome-keyring-daemon --unlock >/dev/null
    tizen certificate -a '$PROFILE' -p '$PASSWORD' -f '$PROFILE'
    tizen security-profiles add -n '$PROFILE' -a '$HOME/tizen-studio-data/keystore/author/$PROFILE.p12' -p '$PASSWORD'
  "
fi

echo "ready: build with  bash tool/tizen/build.sh"
