#!/usr/bin/env bash
# Builds TorrServerKit.xcframework for Apple TV: TorrServer linked into the app (an app on an
# Apple TV, as on an iPhone, may not start a program of its own), with the shim in this folder
# (StartServer, StopServer, IsRunning). macOS with Xcode only. Used by the tvos-torrent job of
# .github/workflows/build.yml; the result is committed as
# packages/torrserver_flutter/binaries/TorrServerKit-tvos.xcframework.zip.
#
# Stock gomobile has no Apple TV target. NetBird's fork adds `tvos` and `tvossimulator` and is
# otherwise golang.org/x/mobile; it is pinned by commit, as TorrServer is by release.
#
#   OUTPUT_DIR   where the .xcframework and its .zip go (default: ../../dist)

set -euo pipefail

TORRSERVER_TAG="MatriX.151"
GOMOBILE_FORK="github.com/netbirdio/gomobile-tvos-fork"
GOMOBILE_COMMIT="a56582c0e7c97feda06c4f8a74995129e6b3f89a"
TVOS_MIN="15.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/../../dist}"
mkdir -p "$OUTPUT_DIR"
cd "$HERE"

echo "== gomobile for tvOS ($GOMOBILE_FORK @ ${GOMOBILE_COMMIT:0:12})"
go install "$GOMOBILE_FORK/cmd/gomobile-netbird@$GOMOBILE_COMMIT"
go install "$GOMOBILE_FORK/cmd/gobind-netbird@$GOMOBILE_COMMIT"
export PATH="$(go env GOPATH)/bin:$PATH"
gomobile-netbird init

echo "== TorrServer $TORRSERVER_TAG"
if [ ! -d torrserver-src ]; then
  git clone --depth 1 --branch "$TORRSERVER_TAG" https://github.com/YouROK/TorrServer.git torrserver-src
  (cd torrserver-src && NODE_OPTIONS=--openssl-legacy-provider go run gen_web.go)
fi

echo "== the shim's module, against this TorrServer and the fork's bind package"
go get "$GOMOBILE_FORK@$GOMOBILE_COMMIT"
go mod tidy

echo "== TorrServerKit.xcframework (tvOS, tvOS simulator)"
rm -rf "$OUTPUT_DIR/TorrServerKit.xcframework"
gomobile-netbird bind \
  -target=tvos,tvossimulator \
  -tvosversion="$TVOS_MIN" \
  -tags=nosqlite \
  -ldflags="-s -w -checklinkname=0" \
  -trimpath \
  -o "$OUTPUT_DIR/TorrServerKit.xcframework" \
  .

ls -la "$OUTPUT_DIR/TorrServerKit.xcframework"
plutil -p "$OUTPUT_DIR/TorrServerKit.xcframework/Info.plist"
(cd "$OUTPUT_DIR" && rm -f TorrServerKit-tvos.xcframework.zip && zip -qr -9 TorrServerKit-tvos.xcframework.zip TorrServerKit.xcframework)
echo "Built $OUTPUT_DIR/TorrServerKit-tvos.xcframework.zip"
