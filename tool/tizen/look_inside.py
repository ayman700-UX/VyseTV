#!/usr/bin/env python3
"""Looks inside a Samsung TV package (.tpk) built by tool/tizen/build.sh, and says what is not
right: what nothing on a PC can run, at least has to be there.

    python3 tool/tizen/look_inside.py build/tizen/VyseTV-1.0.2-tizen6.5.tpk --api 6.5
"""

from __future__ import annotations

import argparse
import re
import sys
import zipfile


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tpk")
    ap.add_argument("--api", required=True)
    args = ap.parse_args()

    z = zipfile.ZipFile(args.tpk)
    names = z.namelist()
    sizes = {i.filename: i.file_size for i in z.infolist()}
    wrong: list[str] = []

    def has(pattern: str, what: str, least: int = 1) -> list[str]:
        found = [n for n in names if re.search(pattern, n)]
        if not found:
            wrong.append(f"no {what} ({pattern})")
        elif least > 1 and max(sizes[n] for n in found) < least:
            wrong.append(f"{what} is too small: {max(sizes[n] for n in found)} bytes")
        return found

    manifest = z.read("tizen-manifest.xml").decode("utf-8") if "tizen-manifest.xml" in names else ""
    if not manifest:
        wrong.append("no tizen-manifest.xml")
    else:
        if f'api-version="{args.api}"' not in manifest:
            wrong.append(f"the manifest is not for Tizen {args.api}")
        if '<profile name="tv"/>' not in manifest and "<profile name=\"tv\" />" not in manifest:
            wrong.append("the manifest is not a TV app's")
        for p in ("internet", "mediastorage"):
            if f"http://tizen.org/privilege/{p}" not in manifest:
                wrong.append(f"the manifest does not ask for {p}")

    has(r"^bin/Runner\.dll$", "C# entry (Runner.dll)")
    has(r"(^|/)libflutter_engine\.so$", "Flutter engine")
    # the app's Dart, compiled for the TV's ARM: tens of MB
    has(r"(^|/)libapp\.so$", "compiled Dart (libapp.so)", least=5_000_000)
    # Samsung's player plugin and the TV player libraries it carries for this Tizen version
    has(r"video_player_avplay|video_player_tizen_plugin", "Samsung's player plugin")
    has(r"libplusplayer", "Samsung's player libraries")
    # VyseTV's build of that plugin (tool/tizen/avplay): its library knows the basic-player option
    plugin_libs = [n for n in names if n.endswith(".so") and "video_player_avplay" in n]
    if plugin_libs and not any(b"vyseBasicPlayer" in z.read(n) for n in plugin_libs):
        wrong.append("Samsung's player plugin is the published one, not VyseTV's build of it (tool/tizen/avplay)")
    has(r"flutter_assets/AssetManifest", "the app's assets")
    # the TV's own libraries (tool/tizen/native.sh): scraper plugins and torrents need them
    has(r"^lib/libquickjs_c_bridge_plugin\.so$", "the JavaScript engine (libquickjs_c_bridge_plugin.so)", least=500_000)
    has(r"^lib/libtorrserver\.so$", "the torrent engine (libtorrserver.so)", least=5_000_000)
    has(r"(^|/)author-signature\.xml$", "author signature")

    print(f"{args.tpk}: {len(names)} files, {sum(sizes.values()) // 1_000_000} MB unpacked")
    for n in sorted(names):
        if n.endswith(".so") or n.endswith(".dll") or n == "tizen-manifest.xml":
            print(f"  {sizes[n]:>11}  {n}")
    if wrong:
        print("NOT RIGHT:\n  " + "\n  ".join(wrong))
        sys.exit(1)
    print("looks right")


if __name__ == "__main__":
    main()
