"""Copies the native side of two Flutter plugins into the Apple TV project, at the versions
pubspec.lock names, with what Apple TV needs added.

    python tool/tvos/vendor_plugins.py           copy (after a plugin's version changed)
    python tool/tvos/vendor_plugins.py --check   only say whether the copies match pubspec.lock

Flutter's tool has no Apple TV target, so no plugin is built for it on its own: the Apple TV
project compiles the few it needs as part of the app (tvos/Runner/Plugins). Two of them speak to
their Dart side in generated messages that change between versions, so their copy must be the
locked version's, exactly. The others there (device info, package info, paths) are fixed ports
that answer plain method channels, and are not handled here.

What is changed in the copies:
  * every `#if os(iOS)` also takes tvOS (the iPhone code is what runs on an Apple TV);
  * connectivity_plus: the iOS 26 satellite check is left to the iPhone (tvOS has no such API
    at the version the app is built for).
"""
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / 'tvos' / 'Runner' / 'Plugins'

PLUGINS = {
    'shared_preferences_foundation': (
        'darwin/shared_preferences_foundation/Sources/shared_preferences_foundation',
        ['SharedPreferencesPlugin.swift', 'messages.g.swift'],
    ),
    'connectivity_plus': (
        'ios/connectivity_plus/Sources/connectivity_plus',
        ['ConnectivityPlusPlugin.swift', 'ConnectivityProvider.swift', 'PathMonitorConnectivityProvider.swift'],
    ),
}

STAMP = '// VyseTV Apple TV copy of {name} {version}: made by tool/tvos/vendor_plugins.py, do not edit.\n'


def locked_versions():
    text = (REPO / 'pubspec.lock').read_text(encoding='utf-8').replace('\r\n', '\n')
    out = {}
    for name in PLUGINS:
        m = re.search(r'^  %s:\n(?:    .*\n|      .*\n)*?    version: "([^"]+)"' % re.escape(name), text, re.M)
        if not m:
            raise SystemExit(f'{name} is not in pubspec.lock')
        out[name] = m.group(1)
    return out


def pub_cache():
    env = os.environ.get('PUB_CACHE')
    if env:
        return Path(env)
    if os.name == 'nt':
        return Path(os.environ['LOCALAPPDATA']) / 'Pub' / 'Cache'
    return Path.home() / '.pub-cache'


def patch(name, file, text):
    text = text.replace('#if os(iOS)\n', '#if os(iOS) || os(tvOS)\n')
    if name == 'connectivity_plus' and file == 'PathMonitorConnectivityProvider.swift':
        old = re.search(r'\n( *)if #available\(iOS 26\.0, \*\), path\.isUltraConstrained \{\n.*?\n\1\}\n', text, re.S)
        if old:
            indent = old.group(1)
            text = text.replace(old.group(0), f'\n{indent}#if os(iOS)\n{old.group(0)[1:]}{indent}#endif\n')
    return text


def main():
    check = '--check' in sys.argv
    versions = locked_versions()
    wrong = []
    for name, (sub, files) in PLUGINS.items():
        version = versions[name]
        stamp = STAMP.format(name=name, version=version)
        for file in files:
            dest = OUT / name / file
            if check:
                have = dest.read_text(encoding='utf-8').splitlines(keepends=True)[:1] if dest.exists() else []
                if have != [stamp]:
                    wrong.append(f'{dest.relative_to(REPO)} is not the copy of {name} {version}')
                continue
            src = pub_cache() / 'hosted' / 'pub.dev' / f'{name}-{version}' / sub / file
            if not src.exists():
                raise SystemExit(f'{src} is not there: run `flutter pub get` first')
            text = src.read_text(encoding='utf-8').replace('\r\n', '\n')
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(stamp + patch(name, file, text), encoding='utf-8', newline='\n')
            print(f'{dest.relative_to(REPO)}  <- {name} {version}')
    if wrong:
        print('\n'.join(wrong))
        print('Run: python tool/tvos/vendor_plugins.py')
        raise SystemExit(1)
    if check:
        print('The Apple TV plugin copies match pubspec.lock.')


if __name__ == '__main__':
    main()
