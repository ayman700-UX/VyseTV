#!/usr/bin/env bash
# Builds libvyse_voice.so, the LG TV's listen-only party voice (voice.go), with LG's NDK:
# libopus first (static, from its release, checked against its checksum), then the Go library
# with cgo through the NDK's compiler. tool/webos/build.sh runs it before LG's tool builds the
# app; the library goes into packages/vyse_webos/webos/prebuilt/, which the plugin's CMake puts
# in the package's lib/.
#
#   bash packages/vyse_webos/voice/build.sh <LG's NDK settings file (environment-setup-*)>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDK_ENV="${1:?the NDK settings file}"
OUT="$HERE/../webos/prebuilt"
WORK="${VYSE_WEBOS_HOME:-$HOME/.cache/vysetv-webos}/voice"
OPUS_VERSION="1.5.2"
OPUS_SHA256="65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"
mkdir -p "$OUT" "$WORK"

# Everything fetched first, with this machine's own settings: once LG's settings are loaded,
# its tools look for certificates in the NDK and no HTTPS download can be checked.
PREFIX="$WORK/opus-prefix"
if [ ! -f "$PREFIX/lib/libopus.a" ]; then
  echo "== libopus $OPUS_VERSION: the source"
  curl -fsSL "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" -o "$WORK/opus.tar.gz"
  echo "$OPUS_SHA256  $WORK/opus.tar.gz" | sha256sum -c -
  rm -rf "$WORK/opus-src" && mkdir -p "$WORK/opus-src"
  tar -xzf "$WORK/opus.tar.gz" -C "$WORK/opus-src" --strip-components=1
fi
echo "== the Go modules"
(cd "$HERE" && go mod download)

# the NDK's compiler and the TV's libraries (in a subshell: its settings stay there)
(
  # shellcheck disable=SC1090
  . "$NDK_ENV"
  unset SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE
  # (what LG's compiler says when asked to make a program and a library: for the log)
  echo "== LG's compiler: $CC"
  printf 'int main(void){return 0;}\n' > "$WORK/t.c"
  $CC $CFLAGS $LDFLAGS "$WORK/t.c" -o "$WORK/t" 2>&1 | tail -n 8 && echo "   a program: made" || echo "   a program: NOT made"
  $CC $CFLAGS -fPIC -shared $LDFLAGS "$WORK/t.c" -o "$WORK/t.so" 2>&1 | tail -n 8 && echo "   a library: made" || echo "   a library: NOT made"
  if [ ! -f "$PREFIX/lib/libopus.a" ]; then
    # With CMake, and its compiler checks made as libraries (a program is never linked: only
    # a library is wanted, and LG's settings make libraries, as LG's own tool does).
    echo "== libopus $OPUS_VERSION with LG's compiler"
    rm -rf "$WORK/opus-build"
    cmake -S "$WORK/opus-src" -B "$WORK/opus-build" -G "Unix Makefiles" \
      -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="${CFLAGS:-} -O2" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib >"$WORK/opus-cmake.log" 2>&1 || { tail -n 40 "$WORK/opus-cmake.log"; exit 1; }
    cmake --build "$WORK/opus-build" -j"$(nproc)" >"$WORK/opus-make.log" 2>&1 || { tail -n 40 "$WORK/opus-make.log"; exit 1; }
    cmake --install "$WORK/opus-build" >/dev/null
  fi
  ls -l "$PREFIX/lib/libopus.a" "$PREFIX/include/opus/opus.h"

  echo "== libvyse_voice.so (linux/arm, cgo with LG's compiler)"
  cd "$HERE"
  # (the modules are here already: nothing is fetched from inside LG's settings)
  export GOFLAGS=-mod=readonly GOPROXY=off
  export CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7
  export CGO_CFLAGS="-I$PREFIX/include -O2"
  export CGO_LDFLAGS="-L$PREFIX/lib"
  go build -buildmode=c-shared -trimpath \
    -ldflags="-s -w -extldflags=-Wl,-soname,libvyse_voice.so" \
    -o "$OUT/libvyse_voice.so" .
)
rm -f "$OUT/libvyse_voice.h"
file "$OUT/libvyse_voice.so"
ls -l "$OUT/libvyse_voice.so"
syms="$(readelf --dyn-syms -W "$OUT/libvyse_voice.so" | grep -v ' UND ')"
for sym in VyseVoiceJoin VyseVoiceLeave VyseVoiceState VyseVoiceSetDeafened VyseVoiceSetVolume VyseVoicePlayWav VyseVoiceFree; do
  grep -qw "$sym" <<<"$syms" || { echo "libvyse_voice.so has no $sym"; exit 1; }
done
readelf -d "$OUT/libvyse_voice.so" | grep -E 'NEEDED|SONAME'
