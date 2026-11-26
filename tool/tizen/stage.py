#!/usr/bin/env python3
"""Lays out a copy of VyseTV that flutter-tizen builds into a Samsung TV package (.tpk).

Why a copy. The app's Dart and its packages are the same as on every other platform: the
flutter-tizen release used (tool/tizen/setup.sh) is made from the very Flutter the project is
pinned to. What a Samsung TV needs on top are the Tizen sides of a few plugins, which are
packages of their own (shared_preferences_tizen and the like). Added to the repository's own
pubspec they would move its lock for every other platform; so they go into a copy, and the
repository's pubspec.yaml and pubspec.lock are never touched.

What the copy is: the app's lib/ and assets/ as they are, the Tizen project (tizen/), the
app's own path packages, and the repository's pubspec.yaml with the Tizen sides added.
Nothing in lib/ is changed for Tizen: what differs there is asked at run time
(lib/core/platform/tizen_tv.dart), with the build's --dart-define=VYSE_TIZEN=true.

Samsung's player plugin carries a library for each Tizen version, and a package is built for
one: the copy's tizen-manifest.xml gets the api-version asked for (tizen/README.md says which
TVs each one is for).

    python tool/tizen/stage.py --api 6.0 [--out DIR] [--check]

--api       6.0 (2021 TVs), 6.5 (2022 to 2025 TVs, Tizen 6.5 to 9.0) or 10.0 (2026 TVs)
--out DIR   where the copy goes (default: build/tizen_stage/<api>)
--check     print the pubspec the copy would get, and write nothing
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

API_VERSIONS = ("6.0", "6.5", "10.0")

# The Tizen sides of the plugins the app uses on a TV, from flutter-tizen's own plugins
# (github.com/flutter-tizen/plugins, on pub.dev). Each registers itself for its plugin.
TIZEN_PLUGINS = {
    "path_provider_tizen": "where the app's files live",
    "shared_preferences_tizen": "settings",
    "sqflite_tizen": "the picture cache's index",
    "package_info_plus_tizen": "the app's own version",
    "connectivity_plus_tizen": "whether the TV is online",
    "url_launcher_tizen": "opening a link in the TV's browser",
}
# Left out on purpose:
#  flutter_secure_storage_tizen  sign-ins and keys are kept by lib/core/platform/tv_secrets.dart
#                                in the app's own folder when no keychain answers
#  wakelock_plus_tizen           the TV stays awake by itself while its player shows a video
#  audioplayers_tizen            party tones are not played on a TV (lib/data/party/alerts.dart)
#  video_player_tizen            the app plays through Samsung's TV player plugin,
#                                video_player_avplay, which is in the repository's own pubspec

# The app's own path packages (the pubspec names them by path).
OWN_PACKAGES = ["torrserver_flutter", "screen_brightness_windows"]


def tizen_pubspec(text: str) -> str:
    """The repository's pubspec.yaml, with the Tizen sides of the plugins added."""
    text = text.replace("\r\n", "\n")
    extra = ["  # Samsung TVs, Tizen (added by tool/tizen/stage.py)"]
    for name in TIZEN_PLUGINS:
        extra.append(f"  {name}: any")
    marker = "dependencies:\n  flutter:\n    sdk: flutter\n"
    if marker not in text:
        raise SystemExit("pubspec.yaml: the start of the dependencies block was not found")
    text = text.replace(marker, marker + "\n".join(extra) + "\n", 1)
    # nothing to make launcher icons for (the TV's is tizen/shared/res/ic_launcher.png)
    text = re.sub(r"(?ms)^flutter_launcher_icons:\n.*?(?=^\S)", "", text, count=1)
    text = re.sub(r"(?m)^  flutter_launcher_icons: .*\n", "", text, count=1)
    return text


def app_version(pubspec_text: str) -> str:
    m = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)", pubspec_text)
    if not m:
        raise SystemExit("pubspec.yaml: no version")
    return m.group(1)


def manifest_for(text: str, api: str, version: str) -> str:
    """tizen-manifest.xml for one package: its api-version, and the app's version."""
    text, n = re.subn(r'(<manifest\b[^>]*?\bapi-version=")[^"]*(")', rf"\g<1>{api}\g<2>", text, count=1)
    if n != 1:
        raise SystemExit("tizen/tizen-manifest.xml: no api-version on <manifest>")
    text, n = re.subn(r'(<manifest\b[^>]*?\bversion=")[^"]*(")', rf"\g<1>{version}\g<2>", text, count=1)
    if n != 1:
        raise SystemExit("tizen/tizen-manifest.xml: no version on <manifest>")
    if '<profile name="tv"/>' not in text:
        raise SystemExit("tizen/tizen-manifest.xml: not a TV app (<profile name=\"tv\"/>)")
    return text


def mirror(src: Path, dst: Path, keep=None) -> int:
    """Makes dst hold what src holds, touching only files that differ. Returns how many were
    written."""
    written = 0
    seen = set()
    skip = {".dart_tool", "build", "ephemeral", ".git", "__pycache__", "bin", "obj"}
    for root, dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        dirs[:] = [d for d in dirs if d not in skip and not (rel == Path(".") and d == "flutter" and src.name == "tizen")]
        for name in files:
            relfile = rel / name
            if keep is not None and not keep(relfile):
                continue
            seen.add(relfile.as_posix())
            s, d = Path(root) / name, dst / relfile
            st = s.stat()
            if d.exists():
                dt = d.stat()
                if dt.st_size == st.st_size and int(dt.st_mtime) == int(st.st_mtime):
                    continue
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)
            written += 1
    # what is no longer in the source goes from the copy too (never what flutter-tizen wrote:
    # tizen/flutter, tizen/bin, tizen/obj stay)
    if dst.exists():
        for root, dirs, files in os.walk(dst):
            rel = Path(root).relative_to(dst)
            dirs[:] = [d for d in dirs if d not in skip and not (rel == Path(".") and d == "flutter" and dst.name == "tizen")]
            for name in files:
                relfile = rel / name
                if keep is not None and not keep(relfile):
                    continue
                if relfile.as_posix() not in seen:
                    (Path(root) / name).unlink()
    return written


def write_if_changed(path: Path, text: str) -> None:
    data = text.encode("utf-8")
    if path.exists() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", required=True, choices=API_VERSIONS)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    out = (args.out or REPO / "build" / "tizen_stage" / args.api).resolve()

    source = (REPO / "pubspec.yaml").read_text(encoding="utf-8")
    pubspec = tizen_pubspec(source)
    version = app_version(source)
    manifest = manifest_for((REPO / "tizen" / "tizen-manifest.xml").read_text(encoding="utf-8"), args.api, version)

    if args.check:
        sys.stdout.write(pubspec)
        return

    if not (REPO / "lib" / "data" / "server_config.dart").exists():
        raise SystemExit(
            "lib/data/server_config.dart is missing (it is not in the repository). A build without it "
            "would have no accounts: copy lib/data/server_config.example.dart and fill it in."
        )

    out.mkdir(parents=True, exist_ok=True)
    n = 0
    n += mirror(REPO / "lib", out / "lib")
    n += mirror(REPO / "assets", out / "assets")
    n += mirror(REPO / "tizen", out / "tizen")
    for name in OWN_PACKAGES:
        keep = None
        if name == "torrserver_flutter":
            # its Dart only: a Samsung TV runs no engine beside the app (lib/data/sources/torrents.dart)
            keep = lambda p: p.parts[0] == "lib" or p.as_posix() in {"pubspec.yaml", "LICENSE", "LICENSE-GPL3", "NOTICE.md"}
        n += mirror(REPO / "packages" / name, out / "packages" / name, keep=keep)
    for name in ("analysis_options.yaml", "LICENSE"):
        if (REPO / name).exists():
            shutil.copy2(REPO / name, out / name)

    write_if_changed(out / "pubspec.yaml", pubspec)
    # The app's own lock: `pub get` in the copy keeps every package the other platforms are
    # built with at its version, and only adds the Tizen sides.
    write_if_changed(out / "pubspec.lock", (REPO / "pubspec.lock").read_text(encoding="utf-8").replace("\r\n", "\n"))
    write_if_changed(out / "tizen" / "tizen-manifest.xml", manifest)
    print(f"staged VyseTV {version} for Tizen {args.api} in {out} ({n} files written)")


if __name__ == "__main__":
    main()
