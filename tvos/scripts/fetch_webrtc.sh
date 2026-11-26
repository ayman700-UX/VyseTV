#!/bin/bash
# Fetches the WebRTC build a party's voice call runs on, and keeps its Apple TV slices in
# tvos/Frameworks/WebRTC.xcframework (tool/tvos/make_project.py links it and puts it in the app).
#
# It is the build flutter_webrtc pins for the iPhone (WebRTC-SDK, the version in tvos/webrtc.version,
# which must be the one in flutter_webrtc's podspec at the locked version): the same release
# carries tvOS slices, for tvOS 17 and later. The whole download is 686 MB; only the Apple TV
# slices are kept. When tvos/webrtc.sha256 is there, the download must be that file exactly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$HERE/webrtc.version")"
URL="https://github.com/webrtc-sdk/Specs/releases/download/$VERSION/WebRTC.xcframework.zip"
OUT="$HERE/Frameworks"

# (the version flutter_webrtc asks for, when its package is at hand)
PODSPEC="$(ls "${PUB_CACHE:-$HOME/.pub-cache}"/hosted/pub.dev/flutter_webrtc-*/ios/flutter_webrtc.podspec 2>/dev/null | tail -n 1 || true)"
if [ -n "$PODSPEC" ]; then
  want="$(sed -n "s/.*dependency 'WebRTC-SDK', '\([^']*\)'.*/\1/p" "$PODSPEC")"
  if [ -n "$want" ] && [ "$want" != "$VERSION" ]; then
    echo "flutter_webrtc ($PODSPEC) asks for WebRTC-SDK $want; tvos/webrtc.version says $VERSION"
    exit 1
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "== WebRTC-SDK $VERSION"
curl -fsSL "$URL" -o "$TMP/webrtc.zip"
sum="$(shasum -a 256 "$TMP/webrtc.zip" | cut -d' ' -f1)"
echo "WebRTC.xcframework.zip: $(wc -c < "$TMP/webrtc.zip") bytes, sha256 $sum"
if [ -f "$HERE/webrtc.sha256" ]; then
  pinned="$(tr -d '[:space:]' < "$HERE/webrtc.sha256")"
  if [ "$sum" != "$pinned" ]; then
    echo "not the pinned file (tvos/webrtc.sha256: $pinned)"
    exit 1
  fi
fi

(cd "$TMP" && unzip -q webrtc.zip 'WebRTC.xcframework/Info.plist' 'WebRTC.xcframework/tvos-*' && unzip -q webrtc.zip 'WebRTC.xcframework/LICENSE*' || true)
python3 - "$TMP/WebRTC.xcframework/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
keep = [lib for lib in info['AvailableLibraries'] if lib.get('SupportedPlatform') == 'tvos']
if not keep:
    raise SystemExit('this WebRTC build has no Apple TV slices')
info['AvailableLibraries'] = keep
with open(path, 'wb') as f:
    plistlib.dump(info, f)
print('kept:', ', '.join(lib['LibraryIdentifier'] for lib in keep))
PY
rm -rf "$OUT/WebRTC.xcframework"
mkdir -p "$OUT"
mv "$TMP/WebRTC.xcframework" "$OUT/"
ls "$OUT/WebRTC.xcframework"
