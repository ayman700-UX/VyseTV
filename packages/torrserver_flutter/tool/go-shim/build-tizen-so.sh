#!/usr/bin/env bash
# Builds the torrent engine for a Samsung TV (Tizen): libtorrserver.so, a shared library the
# app loads into its own process (a Samsung TV starts no program of an app's own), with the C
# entry points in cshared/main.go.
#
# For 32-bit ARM, with the Tizen SDK's own compiler and the Tizen 6.0 system it builds against
# (tool/tizen/setup.sh installs both): a library made against Tizen 6.0's C library loads on
# every newer one. Needs Go and Node (TorrServer's web page is generated as it is fetched).
#
#   bash build-tizen-so.sh <output folder>
set -euo pipefail

TORRSERVER_TAG="MatriX.151"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?output folder}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

TS="${TIZEN_STUDIO:-$HOME/tizen-studio}"
TOOLCHAIN="$TS/tools/arm-linux-gnueabi-gcc-9.2/bin"
SYSROOT="$TS/platforms/tizen-6.0/iot-headed/rootstraps/iot-headed-6.0-device.core"
for need in "$TOOLCHAIN/arm-linux-gnueabi-gcc" "$SYSROOT"; do
  if [ ! -e "$need" ]; then
    echo "missing: $need (tool/tizen/setup.sh installs it)"
    exit 1
  fi
done

cd "$HERE"
echo "== TorrServer $TORRSERVER_TAG"
if [ ! -d torrserver-src ]; then
  git clone --depth 1 --branch "$TORRSERVER_TAG" https://github.com/YouROK/TorrServer.git torrserver-src
  (cd torrserver-src && NODE_OPTIONS=--openssl-legacy-provider go run gen_web.go)
fi

echo "== libtorrserver.so (linux/arm, Tizen's compiler)"
# (Tizen's C library and the TV's own libraries are soft-float ARM EABI, which is this
# compiler's own default; Go's GOARM=7 uses the FPU inside Go code only)
export CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7
export CC="$TOOLCHAIN/arm-linux-gnueabi-gcc --sysroot=$SYSROOT"
export CXX="$TOOLCHAIN/arm-linux-gnueabi-g++ --sysroot=$SYSROOT"
go mod tidy
go build -buildmode=c-shared -trimpath -tags=nosqlite \
  -ldflags="-s -w -checklinkname=0 -extldflags=-Wl,-soname,libtorrserver.so" \
  -o "$OUT/libtorrserver.so" ./cshared
rm -f "$OUT/libtorrserver.h"
file "$OUT/libtorrserver.so"
ls -l "$OUT/libtorrserver.so"
