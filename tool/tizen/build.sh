#!/usr/bin/env bash
# Builds VyseTV's Samsung TV packages (.tpk), after tool/tizen/setup.sh.
#
# One package for each Tizen version Samsung's player plugin carries a library for, as its
# README says to: 6.0 (2021 TVs), 6.5 (Tizen 6.5 to 9.0: 2022 to 2025 TVs) and 10.0 (2026 TVs).
# Each is built in its own copy of the app (tool/tizen/stage.py), and looked inside
# (tool/tizen/look_inside.py) before it is called built.
#
#   bash tool/tizen/build.sh [6.0] [6.5] [10.0]      (none named: all three)
#
# The packages land in build/tizen/, named VyseTV-<version>-tizen<api>.tpk.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="${VYSE_TIZEN_TOOLS:-$HOME/.cache/vysetv-tizen}"
STAGES="${VYSE_TIZEN_STAGE:-$TOOLS/stage}"
export PATH="$TOOLS/flutter-tizen/bin:$PATH:$HOME/tizen-studio/tools/ide/bin"
# (setup.sh's signing profile)
PROFILE="vysetv"
PASSWORD="vysetv-ci"

apis=("$@")
[ ${#apis[@]} -gt 0 ] || apis=(6.0 6.5 10.0)
version="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$REPO/pubspec.yaml" | head -n1)"
out="$REPO/build/tizen"
mkdir -p "$out"

# the TV's own libraries (the JavaScript engine, the torrent engine): one build for every package
native="$TOOLS/native-libs"
bash "$REPO/tool/tizen/native.sh" "$native"

for api in "${apis[@]}"; do
  echo "== Tizen $api"
  stage="$STAGES/$api"
  python3 "$REPO/tool/tizen/stage.py" --api "$api" --out "$stage" --native "$native"
  rm -rf "$stage/build/tizen/tpk"
  (cd "$stage" && flutter-tizen pub get)
  dbus-run-session -- bash -c "
    set -e
    echo '$PASSWORD' | gnome-keyring-daemon --unlock >/dev/null
    cd '$stage'
    flutter-tizen build tpk --release --device-profile tv --security-profile '$PROFILE' --dart-define=VYSE_TIZEN=true
  "
  made=("$stage"/build/tizen/tpk/*.tpk)
  if [ ! -f "${made[0]}" ]; then
    echo "no package in $stage/build/tizen/tpk"
    exit 1
  fi
  name="VyseTV-$version-tizen$api.tpk"
  cp "${made[0]}" "$out/$name"
  python3 "$REPO/tool/tizen/look_inside.py" "$out/$name" --api "$api"
done

ls -l "$out"/*.tpk
