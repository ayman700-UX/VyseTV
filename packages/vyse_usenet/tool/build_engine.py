#!/usr/bin/env python3
"""Builds the Usenet engine (packages/vyse_usenet/engine) for one platform VyseTV runs on.

    python3 build_engine.py <target> <output folder>

Targets, and what each makes:

    android-arm64 | android-arm | android-amd64
        libvyse_usenet.so: an Android executable (PIE, API 24, 16 KB pages) that the app starts
        from its native library folder. Needs ANDROID_NDK_HOME and cmake.
    windows-amd64      vyse-usenet.exe, started by the app (MinGW gcc on PATH)
    linux-amd64 | linux-arm64
                       vyse-usenet, started by the app (gcc / aarch64-linux-gnu-gcc)
    darwin-universal   vyse-usenet for Intel and Apple silicon Macs, started by the app (Xcode)
    webos-arm          vyse-usenet for LG TVs: 32-bit ARM, linked statically, so it runs with
                       the TV's own C library and with the older-webOS package's runtime alike
                       (arm-linux-gnueabihf-gcc)
    tizen-arm          libvyse_usenet.so for Samsung TVs: loaded into the app's process (a
                       Samsung TV starts no program of an app's own), with the C entry points of
                       cmd/libvyse-usenet; built with the Tizen SDK's compiler against Tizen 6.0
                       (TIZEN_STUDIO, tool/tizen/setup.sh installs it)
    ios-arm64 | tvos-arm64
                       VyseUsenet-ios.xcframework.zip / VyseUsenet-tvos.xcframework.zip: the
                       engine linked into the app (an iPhone or Apple TV app may not start a
                       program), with the entry points of cmd/libvyse-usenet (Xcode)

The engine's yEnc decoder is C++ (third_party/rapidyenc-native): it is compiled for the target
here, except where third_party/rapidyenc already carries the library (Windows, Linux, Mac).
"""

import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "engine"
NATIVE = ENGINE / "third_party" / "rapidyenc-native"
WRAPPER = ENGINE / "third_party" / "rapidyenc"
PROGRAM = "./cmd/vyse-usenet"
LIBRARY = "./cmd/libvyse-usenet"
IOS_MIN = "15.5"
TVOS_MIN = "17.0"

ANDROID = {
    "android-arm64": ("arm64-v8a", "arm64", "aarch64-linux-android"),
    "android-arm": ("armeabi-v7a", "arm", "armv7a-linux-androideabi"),
    "android-amd64": ("x86_64", "amd64", "x86_64-linux-android"),
}


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def go_env(**extra):
    env = dict(os.environ, CGO_ENABLED="1", GOTOOLCHAIN="local", GOFLAGS="-mod=mod")
    env.update({k: str(v) for k, v in extra.items()})
    return env


def cmake_rapidyenc(build: Path, out_name: str, *defs):
    """Compiles the yEnc decoder's C++ as a static library into third_party/rapidyenc."""
    shutil.rmtree(build, ignore_errors=True)
    run(["cmake", "-S", NATIVE, "-B", build, "-DCMAKE_BUILD_TYPE=Release", "-DDISABLE_SHARED=ON",
         "-DDISABLE_TOOL=ON", "-DDISABLE_CRC=ON", *defs])
    run(["cmake", "--build", build, "--target", "rapidyenc_static", "-j", "4"])
    lib = next(build.rglob("librapidyenc.a"))
    shutil.copyfile(lib, WRAPPER / out_name)
    print("rapidyenc ->", WRAPPER / out_name)


# ── Android ──

RUNTIME_TIME_FILE = Path("src") / "runtime" / "os_linux32.go"
RUNTIME_TIME_ANCHOR = "func configure64bitsTimeOn32BitsArchitectures() {\n"
RUNTIME_TIME_PATCH = """\t// Android 8.0-10 app seccomp filters kill the process on the time64
\t// syscalls even on kernels >= 5.1, and every Android filter allows the
\t// 32-bit variants, so Android always uses them (golang/go#83366).
\tif GOOS == "android" {
\t\tuse64bitsTimeOn32bits = false
\t\treturn
\t}
"""


def android_time32_goroot(workdir: Path):
    """A copy of Go whose 32-bit Android runtime uses the 32-bit time syscalls.

    Go picks futex_time64 and timer_settime64 from the kernel version alone, so a 32-bit
    program on Android 8.0 to 10 with a 5.1 or newer kernel (Fire OS 7 on a 5.4 kernel) is
    killed by the app sandbox before it starts. Only 32-bit builds compile the patched file.
    """
    source = Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
    text = (source / RUNTIME_TIME_FILE).read_text()
    if text.count(RUNTIME_TIME_ANCHOR) != 1:
        raise SystemExit(f"{source / RUNTIME_TIME_FILE} changed; review the Android time32 patch")
    body = text.split(RUNTIME_TIME_ANCHOR, 1)[1].split("\n}\n", 1)[0]
    if 'GOOS == "android"' in body:
        return None
    goroot = workdir / "go"
    shutil.copytree(source, goroot, symlinks=True)
    (goroot / RUNTIME_TIME_FILE).write_text(text.replace(RUNTIME_TIME_ANCHOR, RUNTIME_TIME_ANCHOR + RUNTIME_TIME_PATCH))
    return goroot


def build_android(target: str, out: Path):
    abi, arch, triple = ANDROID[target]
    ndk = Path(os.environ["ANDROID_NDK_HOME"])
    host = {"Linux": "linux-x86_64", "Darwin": "darwin-x86_64", "Windows": "windows-x86_64"}[platform.system()]
    bin_dir = ndk / "toolchains" / "llvm" / "prebuilt" / host / "bin"
    suffix = ".cmd" if host.startswith("windows") else ""
    cmake_rapidyenc(ENGINE / "build" / f"rapidyenc-{target}", f"librapidyenc_android_{arch}.a",
                    f"-DCMAKE_TOOLCHAIN_FILE={ndk / 'build' / 'cmake' / 'android.toolchain.cmake'}",
                    f"-DANDROID_ABI={abi}", "-DANDROID_PLATFORM=android-24", "-DANDROID_STL=c++_static")
    with tempfile.TemporaryDirectory(prefix="vyse-usenet-go-") as work:
        goroot = android_time32_goroot(Path(work)) if arch == "arm" else None
        go = str(goroot / "bin" / "go") if goroot else "go"
        env = go_env(GOOS="android", GOARCH=arch, CC=bin_dir / f"{triple}24-clang{suffix}",
                     CXX=bin_dir / f"{triple}24-clang++{suffix}")
        if goroot:
            env["GOROOT"] = str(goroot)
        if arch == "arm":
            env["GOARM"] = "7"
        run([go, "build", "-trimpath", "-buildvcs=false", "-buildmode=pie",
             "-ldflags=-s -w -buildid= -extldflags=-Wl,-z,max-page-size=16384",
             "-o", out / "libvyse_usenet.so", PROGRAM], cwd=ENGINE, env=env)


# ── Windows, Linux, Mac ──

def build_windows(out: Path):
    # (a GUI-subsystem program: no console window flashes up when the app starts it, and its
    # stdin and stdout, which the app hands it as pipes, work all the same)
    run(["go", "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w -buildid= -H windowsgui",
         "-o", out / "vyse-usenet.exe", PROGRAM], cwd=ENGINE, env=go_env(GOOS="windows", GOARCH="amd64", CC="gcc", CXX="g++"))


def build_linux(arch: str, out: Path):
    cc = "gcc" if arch == "amd64" else "aarch64-linux-gnu-gcc"
    cxx = "g++" if arch == "amd64" else "aarch64-linux-gnu-g++"
    run(["go", "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w -buildid=",
         "-o", out / "vyse-usenet", PROGRAM], cwd=ENGINE, env=go_env(GOOS="linux", GOARCH=arch, CC=cc, CXX=cxx))


def build_darwin(out: Path):
    parts = []
    for arch, clang_arch in (("amd64", "x86_64"), ("arm64", "arm64")):
        part = ENGINE / "build" / f"vyse-usenet-darwin-{arch}"
        run(["go", "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w -buildid=", "-o", part, PROGRAM], cwd=ENGINE,
            env=go_env(GOOS="darwin", GOARCH=arch, CC=f"clang -arch {clang_arch} -mmacosx-version-min=11.0",
                       CXX=f"clang++ -arch {clang_arch} -mmacosx-version-min=11.0", MACOSX_DEPLOYMENT_TARGET="11.0"))
        parts.append(part)
    run(["lipo", "-create", *parts, "-output", out / "vyse-usenet"])
    run(["lipo", "-info", out / "vyse-usenet"])


# ── LG and Samsung TVs ──

def build_webos(out: Path):
    cmake_rapidyenc(ENGINE / "build" / "rapidyenc-webos", "librapidyenc_linux_arm.a",
                    "-DCMAKE_SYSTEM_NAME=Linux", "-DCMAKE_SYSTEM_PROCESSOR=armv7", "-DTARGET_ARCH=armv7",
                    "-DCMAKE_C_COMPILER=arm-linux-gnueabihf-gcc", "-DCMAKE_CXX_COMPILER=arm-linux-gnueabihf-g++")
    # (netgo/osusergo: Go's own name lookup, so nothing of glibc is wanted at run time)
    run(["go", "build", "-trimpath", "-buildvcs=false", "-tags=netgo,osusergo",
         "-ldflags=-s -w -buildid= -linkmode=external -extldflags=-static",
         "-o", out / "vyse-usenet", PROGRAM], cwd=ENGINE,
        env=go_env(GOOS="linux", GOARCH="arm", GOARM="7", CC="arm-linux-gnueabihf-gcc", CXX="arm-linux-gnueabihf-g++"))


def build_tizen(out: Path):
    studio = Path(os.environ.get("TIZEN_STUDIO", Path.home() / "tizen-studio"))
    toolchain = studio / "tools" / "arm-linux-gnueabi-gcc-9.2" / "bin"
    sysroot = studio / "platforms" / "tizen-6.0" / "iot-headed" / "rootstraps" / "iot-headed-6.0-device.core"
    for need in (toolchain / "arm-linux-gnueabi-gcc", sysroot):
        if not need.exists():
            raise SystemExit(f"missing: {need} (tool/tizen/setup.sh installs it)")
    gcc, gxx = toolchain / "arm-linux-gnueabi-gcc", toolchain / "arm-linux-gnueabi-g++"
    # (Tizen's C library and the TV's own libraries are soft-float ARM EABI, the compiler's own
    # default; GOARM=7 uses the FPU inside Go code only)
    cmake_rapidyenc(ENGINE / "build" / "rapidyenc-tizen", "librapidyenc_linux_arm.a",
                    "-DCMAKE_SYSTEM_NAME=Linux", "-DCMAKE_SYSTEM_PROCESSOR=armv7", "-DTARGET_ARCH=armv7",
                    f"-DCMAKE_C_COMPILER={gcc}", f"-DCMAKE_CXX_COMPILER={gxx}", f"-DCMAKE_SYSROOT={sysroot}")
    run(["go", "build", "-buildmode=c-shared", "-trimpath", "-buildvcs=false",
         "-ldflags=-s -w -buildid= -extldflags=-Wl,-soname,libvyse_usenet.so",
         "-o", out / "libvyse_usenet.so", LIBRARY], cwd=ENGINE,
        env=go_env(GOOS="linux", GOARCH="arm", GOARM="7", CC=f"{gcc} --sysroot={sysroot}", CXX=f"{gxx} --sysroot={sysroot}"))
    (out / "libvyse_usenet.h").unlink(missing_ok=True)


# ── iPhone/iPad and Apple TV ──

def build_apple_library(target: str, out: Path):
    sdk, cmake_system, min_flag, minimum, name = {
        "ios-arm64": ("iphoneos", "iOS", "-miphoneos-version-min", IOS_MIN, "VyseUsenet-ios"),
        "tvos-arm64": ("appletvos", "tvOS", "-mtvos-version-min", TVOS_MIN, "VyseUsenet-tvos"),
    }[target]
    sysroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["xcrun", "--sdk", sdk, "-f", "clang"], text=True).strip()
    clangxx = subprocess.check_output(["xcrun", "--sdk", sdk, "-f", "clang++"], text=True).strip()
    cmake_rapidyenc(ENGINE / "build" / f"rapidyenc-{target}", "librapidyenc_ios_arm64.a",
                    f"-DCMAKE_SYSTEM_NAME={cmake_system}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                    f"-DCMAKE_OSX_SYSROOT={sysroot}", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}",
                    "-DCMAKE_SYSTEM_PROCESSOR=aarch64", "-DTARGET_ARCH=arm64")
    flags = f"-isysroot {sysroot} -arch arm64 {min_flag}={minimum}"
    stage = ENGINE / "build" / name
    shutil.rmtree(stage, ignore_errors=True)
    (stage / "include").mkdir(parents=True)
    run(["go", "build", "-buildmode=c-archive", "-trimpath", "-buildvcs=false", "-ldflags=-s -w -buildid=",
         "-o", stage / "libvyse_usenet.a", LIBRARY], cwd=ENGINE,
        env=go_env(GOOS="ios", GOARCH="arm64", CC=f"{clang} {flags}", CXX=f"{clangxx} {flags}",
                   CGO_CFLAGS=flags, CGO_LDFLAGS=flags))
    shutil.move(str(stage / "libvyse_usenet.h"), stage / "include" / "libvyse_usenet.h")
    framework = stage / f"{name}.xcframework"
    run(["xcodebuild", "-create-xcframework", "-library", stage / "libvyse_usenet.a",
         "-headers", stage / "include", "-output", framework])
    archive = out / f"{name}.xcframework.zip"
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--keepParent", framework, archive])


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    target, out = sys.argv[1], Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if target in ANDROID:
        build_android(target, out)
    elif target == "windows-amd64":
        build_windows(out)
    elif target in ("linux-amd64", "linux-arm64"):
        build_linux(target.split("-")[1], out)
    elif target == "darwin-universal":
        build_darwin(out)
    elif target == "webos-arm":
        build_webos(out)
    elif target == "tizen-arm":
        build_tizen(out)
    elif target in ("ios-arm64", "tvos-arm64"):
        build_apple_library(target, out)
    else:
        raise SystemExit(f"unknown target {target}\n\n{__doc__}")
    for f in sorted(out.iterdir()):
        print(f"{f.name}: {f.stat().st_size} bytes")


if __name__ == "__main__":
    main()
