#!/usr/bin/env python3
"""Checks, on any PC, that VyseTV's Dart still builds for LG webOS. No LG tools needed.

The webOS build itself needs Linux and LG's SDK (tool/webos/build.sh). What decides most often
whether it will build, though, is the Dart: LG's Flutter is an older one (3.38.10, Dart 3.10)
than the project's, and a line of new syntax or a newer package anywhere in lib/ breaks it.
This script finds that out here, with a stock Flutter 3.38.10 beside the project's own:

    git clone -b 3.38.10 --depth 1 https://github.com/flutter/flutter.git <somewhere>/flutter-3.38.10
    python tool/webos/check.py --flutter <somewhere>/flutter-3.38.10

It stages the webOS copy (stage.py), resolves its packages, analyzes lib/, and compiles the
whole program to a kernel file the way LG's tool does: release mode, no target system baked in
(a webOS TV reports itself as Linux at run time), VYSE_WEBOS=true, and starting from the same
entry point LG's tool writes, which registers the webOS sides of the plugins. With --arm it
goes on to compile that for 32-bit ARM (see the note at ARM below).

It never touches the repository's own pubspec.lock or .dart_tool, and never the pinned Flutter.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def run(cmd, cwd, tail=25, check=True):
    print("  $", " ".join(str(c) for c in cmd))
    r = subprocess.run([str(c) for c in cmd], cwd=str(cwd), capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 and check:
        print("\n".join(out.strip().splitlines()[-tail:]))
        raise SystemExit(f"failed ({r.returncode})")
    return r.returncode, out


def webos_dart_plugins(stage: Path):
    """The packages of the staged copy that have a Dart side for webOS, as LG's tool finds them:
    (package, class) from each pubspec's flutter.plugin.platforms.webos.dartPluginClass."""
    config = json.loads((stage / ".dart_tool" / "package_config.json").read_text(encoding="utf-8"))
    found = []
    for pkg in config["packages"]:
        root = pkg["rootUri"]
        if root.startswith("file://"):
            from urllib.parse import unquote, urlparse

            path = unquote(urlparse(root).path)
            if os.name == "nt" and re.match(r"^/[A-Za-z]:", path):
                path = path[1:]
            base = Path(path)
        else:
            base = (stage / ".dart_tool" / root).resolve()
        pubspec = base / "pubspec.yaml"
        if not pubspec.exists():
            continue
        text = pubspec.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"(?ms)^\s+webos:\s*\n((?:\s+\S.*\n?)+)", text)
        if not m:
            continue
        cls = re.search(r"dartPluginClass:\s*(\w+)", m.group(1))
        if cls:
            found.append((pkg["name"], cls.group(1)))
    return sorted(found)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--flutter", type=Path, required=True, help="a stock Flutter 3.38.10 checkout (not the project's pinned one)")
    ap.add_argument("--out", type=Path, default=REPO / "build" / "webos_check", help="where the staged copy goes")
    ap.add_argument("--arm", type=Path, default=None, help="a gen_snapshot for 32-bit ARM, to compile that far")
    args = ap.parse_args()

    flutter = args.flutter / "bin" / ("flutter.bat" if os.name == "nt" else "flutter")
    if not flutter.exists():
        raise SystemExit(f"no Flutter at {args.flutter}")
    rc, version = run([flutter, "--version"], REPO, check=False)
    if "3.38.10" not in version:
        raise SystemExit(f"{args.flutter} is not Flutter 3.38.10:\n{version}")
    stage = args.out.resolve()

    print("1. staging")
    run([sys.executable, REPO / "tool" / "webos" / "stage.py", "--out", stage], REPO)

    print("2. packages (Dart 3.10)")
    run([flutter, "pub", "get"], stage)

    print("3. analyze lib/")
    rc, out = run([flutter, "analyze", "--no-pub", "--no-fatal-infos", "--no-fatal-warnings", "lib"], stage, check=False)
    errors = [line for line in out.splitlines() if re.match(r"^\s*error\b", line)]
    if errors:
        print("\n".join(errors[:60]))
        raise SystemExit(f"{len(errors)} errors on Dart 3.10")
    print("   no errors")

    print("4. the entry point LG's tool writes (the plugins' webOS sides registered first)")
    plugins = webos_dart_plugins(stage)
    for name, cls in plugins:
        print(f"   {name}: {cls}")
    flutter_dir = stage / "webos" / "flutter"
    flutter_dir.mkdir(parents=True, exist_ok=True)
    (flutter_dir / "generated_plugin_registrant.dart").write_text(
        "// Written by tool/webos/check.py, as LG's tool writes it.\n"
        + "".join(f"import 'package:{name}/{name}.dart';\n" for name, _ in plugins)
        + "\nvoid registerPlugins() {\n"
        + "".join(f"  {cls}.registerWith();\n" for _, cls in plugins)
        + "}\n",
        encoding="utf-8",
    )
    (flutter_dir / "main.dart").write_text(
        "// Written by tool/webos/check.py, as LG's tool writes it.\n"
        "import 'package:vyse_tv/main.dart' as entrypoint;\n"
        "import 'generated_plugin_registrant.dart';\n\n"
        "Future<void> main() async {\n  registerPlugins();\n  entrypoint.main();\n}\n",
        encoding="utf-8",
    )

    print("5. compile the program (release, VYSE_WEBOS=true)")
    defines = base64.b64encode(b"VYSE_WEBOS=true").decode()
    run(
        [
            flutter, "assemble", "--no-version-check",
            "-dTargetPlatform=flutter-tester", "-dBuildMode=release",
            "-dTargetFile=webos/flutter/main.dart", f"-dDartDefines={defines}",
            "--output=build/webos_check", "kernel_snapshot_program",
        ],
        stage,
        tail=60,
    )
    dills = sorted((stage / ".dart_tool" / "flutter_build").glob("*/app.dill"), key=lambda p: p.stat().st_mtime)
    if not dills:
        raise SystemExit("no app.dill was written")
    dill = dills[-1]
    print(f"   {dill.relative_to(stage)}: {dill.stat().st_size >> 20} MB")

    # ARM. A stock Flutter's ARM snapshot compiler (the android-arm one) reads the same Dart and
    # so proves the program compiles ahead of time for a 32-bit ARM with the TV's calling
    # convention. Its output is NOT what goes on a TV: it is stamped "arm android", and LG's
    # engine only loads "arm linux", which only LG's own Linux-hosted gen_snapshot writes.
    if args.arm is not None:
        print("6. ahead-of-time for 32-bit ARM (a check, not the TV's binary)")
        aot = stage / "build" / "webos_check" / "aot"
        aot.mkdir(parents=True, exist_ok=True)
        run(
            [
                args.arm, "--deterministic", "--snapshot_kind=app-aot-elf", f"--elf={aot / 'app.so'}",
                "--strip", "--no-sim-use-hardfp", "--no-use-integer-division", dill,
            ],
            stage,
            tail=60,
        )
        print(f"   app.so: {(aot / 'app.so').stat().st_size >> 20} MB")
    print("The Dart side builds for webOS.")


if __name__ == "__main__":
    main()
