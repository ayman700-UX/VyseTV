#!/usr/bin/env python3
"""Lays out a copy of VyseTV that LG's Flutter tool can build for webOS.

Why a copy. Every other platform builds this repository in place with the Flutter the project
is pinned to. The webOS build cannot: LG's Flutter SDK is its own, older Flutter (3.38.10,
Dart 3.10), so the same pubspec does not resolve there, and running LG's `pub get` here would
rewrite pubspec.lock and .dart_tool under the other platforms' feet. On Windows there is one
more reason: LG's tool only runs on Linux, and under WSL a project on a Windows drive fails to
build (the shader compiler sets file modes NTFS refuses), so the copy has to be on the Linux
side.

What the copy is: the app's own lib/ and assets/ as they are, the webOS project folder
(webos/), the two packages that carry native webOS parts, and a pubspec.yaml worked out from
the repository's one by the rules below. Nothing in lib/ is changed for webOS: what differs
there is asked at run time (lib/core/platform/webos.dart).

    python tool/webos/stage.py [--out DIR] [--update-lock] [--check]

--out DIR       where the copy goes (default: ~/.cache/vysetv-webos/stage on Linux, and
                build/webos_stage here on Windows, where it is only good for checking)
--update-lock   after LG's `pub get` ran in the copy: take its pubspec.lock back into
                tool/webos/pubspec.lock, which is the lock the webOS build is made with
--check         print the pubspec the copy would get, and write nothing
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# LG's webOS plugins, at the commit they were read at (github.com/lg-flutter-webos/plugins).
LG_PLUGINS_URL = "https://github.com/lg-flutter-webos/plugins.git"
LG_PLUGINS_REF = "3a742bb86b04e261044f0864f9b1f71acf0bbad3"

# The Dart of LG's Flutter. The app's own code is written to compile on it (lib/core/compat.dart).
WEBOS_DART = "^3.10.0"

# Packages whose current release needs a newer Dart than LG's Flutter has: the newest one that
# does not. (Checked 2026-11-26: with these the whole of lib/ analyzes clean on Flutter 3.38.10.)
OLDER = {
    "flutter_foreground_task": "10.0.0",  # 11 needs Dart 3.12 (Android and iOS only; unused on a TV)
    "url_launcher": "6.3.2",  # 6.3.3 needs Dart 3.11
    "google_fonts": "8.2.1",  # 9 needs Dart 3.13
    "cached_network_image": "3.4.1",  # 4 needs Dart 3.12
    "xml": "6.6.1",  # 7 needs Dart 3.11
    "flutter_svg": "2.3.0",  # 2.3.2 needs Dart 3.11
}

# Not for Dart's sake. LG's webOS side of flutter_secure_storage says it wants the plugin's
# 1.x interface; the app's flutter_secure_storage (10.x) comes with 2.x. The two interfaces ask
# the same six methods of an implementation (2.x adds one, with a body of its own), so LG's
# class builds against 2.x as it is, and the app keeps the version every other platform has.
INTERFACES = {
    "flutter_secure_storage_platform_interface": "2.1.1",
}

# The webOS sides LG ships, by the folder they are in. Each is a package of its own that
# registers itself over the plugin's Linux side (a webOS TV says it is Linux).
LG_PLUGINS = {
    "path_provider_webos": "path_provider",  # where the app's files live (appdata/ in its folder)
    "shared_preferences_webos": "shared_preferences",  # settings
    "sqflite_webos": "sqflite",  # the picture cache's index
    "connectivity_plus_webos": "connectivity_plus",
    "url_launcher_webos": "url_launcher",  # opens the TV's browser
    "flutter_secure_storage_webos": "flutter_secure_storage",  # sign-ins and keys
}
# Left out on purpose:
#  audioplayers_webos   it and the video player would both count the TV's player slots from 0;
#                       party alert tones are not played on a TV (lib/data/party/alerts.dart)
#  video_player_webos   VyseTV has its own player over the same library (packages/vyse_webos)
#  package_info_plus_webos, device_info_plus_webos
#                       the plugins' own Linux sides are plain Dart and work on a TV; the TV's
#                       model is asked of LG's embedder directly

# The app's own packages that have a webOS part.
OWN_PACKAGES = ["vyse_webos", "torrserver_flutter", "vyse_usenet"]

# Of the torrent engine's archives only the TV's is needed (the others are 270 MB).
ENGINE_ARCHIVE = "torrserver-linux-arm7.tar.gz"


def webos_pubspec(text: str) -> str:
    """The repository's pubspec.yaml, as the webOS build needs it."""
    text = text.replace("\r\n", "\n")

    # 1. the Dart of LG's Flutter
    text, n = re.subn(r"(?m)^(  sdk: )\^3\.\d+\.\d+\s*$", rf"\g<1>{WEBOS_DART}", text, count=1)
    if n != 1:
        raise SystemExit("pubspec.yaml: the environment's sdk line was not found")

    # 2. the repository's own override block goes (it is the Windows brightness stand-in) and
    #    this build's comes in its place
    text, n = re.subn(r"(?ms)^dependency_overrides:\n.*?(?=^\S)", "", text, count=1)
    if n != 1:
        raise SystemExit("pubspec.yaml: the dependency_overrides block was not found")
    overrides = ["dependency_overrides:"]
    overrides.append("  # (the newest releases that LG's Flutter, Dart 3.10, can build: tool/webos/stage.py)")
    for name, version in OLDER.items():
        overrides.append(f"  {name}: {version}")
    overrides.append("  # (the interface the app's own version of the plugin uses: see INTERFACES in stage.py)")
    for name, version in INTERFACES.items():
        overrides.append(f"  {name}: {version}")
    text = re.sub(r"(?m)^dev_dependencies:\n", "\n".join(overrides) + "\n\ndev_dependencies:\n", text, count=1)

    # 3. the webOS sides: LG's plugins, and the app's own native side
    extra = ["  # LG webOS (added by tool/webos/stage.py)"]
    for name, folder in LG_PLUGINS.items():
        extra += [
            f"  {name}:",
            "    git:",
            f"      url: {LG_PLUGINS_URL}",
            f"      path: packages/{folder}",
            f"      ref: {LG_PLUGINS_REF}",
        ]
    extra += ["  vyse_webos:", "    path: packages/vyse_webos"]
    marker = "dependencies:\n  flutter:\n    sdk: flutter\n"
    if marker not in text:
        raise SystemExit("pubspec.yaml: the start of the dependencies block was not found")
    text = text.replace(marker, marker + "\n".join(extra) + "\n", 1)

    # 4. nothing to make launcher icons for
    text = re.sub(r"(?ms)^flutter_launcher_icons:\n.*?(?=^\S)", "", text, count=1)
    text = re.sub(r"(?m)^  flutter_launcher_icons: .*\n", "", text, count=1)
    return text


def app_version(pubspec_text: str) -> str:
    m = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)", pubspec_text)
    if not m:
        raise SystemExit("pubspec.yaml: no version")
    return m.group(1)


def mirror(src: Path, dst: Path, keep=None) -> int:
    """Makes dst hold what src holds, touching only files that differ (so LG's tool, which
    builds again whatever is newer, does no more than it must). Returns how many were written."""
    written = 0
    seen = set()
    for root, dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        # (build leftovers and tool state are never part of the copy)
        dirs[:] = [d for d in dirs if d not in {".dart_tool", "build", "ephemeral", ".git", "__pycache__"}]
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
    # what is no longer in the source goes from the copy too (never what was not ours to copy:
    # LG's tool keeps its own files in webos/flutter, and they stay)
    if dst.exists():
        for root, dirs, files in os.walk(dst):
            rel = Path(root).relative_to(dst)
            dirs[:] = [d for d in dirs if d not in {".dart_tool", "build", "ephemeral"}]
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


def default_out() -> Path:
    if os.name == "nt":
        return REPO / "build" / "webos_stage"
    return Path.home() / ".cache" / "vysetv-webos" / "stage"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--update-lock", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    out = (args.out or default_out()).resolve()

    source = (REPO / "pubspec.yaml").read_text(encoding="utf-8")
    pubspec = webos_pubspec(source)
    version = app_version(source)
    lock = REPO / "tool" / "webos" / "pubspec.lock"

    if args.check:
        sys.stdout.write(pubspec)
        return

    if args.update_lock:
        made = out / "pubspec.lock"
        if not made.exists():
            raise SystemExit(f"{made} is not there: run LG's `flutter-webos pub get` in {out} first")
        write_if_changed(lock, made.read_text(encoding="utf-8").replace("\r\n", "\n"))
        print(f"took {made} as {lock.relative_to(REPO)}")
        return

    if not (REPO / "lib" / "data" / "server_config.dart").exists():
        raise SystemExit(
            "lib/data/server_config.dart is missing (it is not in the repository). A build without it "
            "would have no accounts and no updater: copy lib/data/server_config.example.dart and fill it in."
        )
    if not (REPO / "packages" / "torrserver_flutter" / "binaries" / ENGINE_ARCHIVE).exists():
        raise SystemExit(f"packages/torrserver_flutter/binaries/{ENGINE_ARCHIVE} is missing: the TV's torrent engine")

    out.mkdir(parents=True, exist_ok=True)
    n = 0
    n += mirror(REPO / "lib", out / "lib")
    n += mirror(REPO / "assets", out / "assets")
    n += mirror(REPO / "webos", out / "webos", keep=lambda p: p.parts[0] != "flutter")
    for name in OWN_PACKAGES:
        keep = None
        if name == "torrserver_flutter":
            # its Dart and its webOS folder, and of the engines only the TV's
            keep = lambda p: (
                p.parts[0] in {"lib", "webos"}
                or p.as_posix() in {"pubspec.yaml", "LICENSE", "LICENSE-GPL3", "NOTICE.md", f"binaries/{ENGINE_ARCHIVE}"}
            )
        if name == "vyse_usenet":
            # its Dart, its webOS folder and the TV's engine (not the engine's Go source, nor the
            # other platforms' builds)
            keep = lambda p: (
                p.parts[0] in {"lib", "webos"}
                or p.as_posix() in {"pubspec.yaml", "NOTICE.md", "README.md", "tool/unpack.cmake", "binaries/manifest.json",
                                    "binaries/vyse-usenet-webos-arm.zip", "engine/LICENSE"}
                or (len(p.parts) > 1 and p.parts[0] == "engine" and p.parts[1] == "licenses")
            )
        n += mirror(REPO / "packages" / name, out / "packages" / name, keep=keep)
    for name in ("analysis_options.yaml", "LICENSE"):
        if (REPO / name).exists():
            shutil.copy2(REPO / name, out / name)

    write_if_changed(out / "pubspec.yaml", pubspec)
    # The lock this build was last resolved with. LG's `pub get` keeps to it, or says what moved.
    if lock.exists() and not (out / "pubspec.lock").exists():
        shutil.copy2(lock, out / "pubspec.lock")

    # the TV's package version is the app's (without the build number, which webOS has no place for)
    info_path = out / "webos" / "meta" / "appinfo.json"
    info = json.loads(info_path.read_text(encoding="utf-8"))
    if info.get("version") != version:
        info["version"] = version
        write_if_changed(info_path, json.dumps(info, indent=4) + "\n")

    print(f"staged VyseTV {version} for webOS in {out} ({n} files written)")


if __name__ == "__main__":
    main()
