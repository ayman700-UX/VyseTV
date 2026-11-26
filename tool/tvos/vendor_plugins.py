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

Two more are copied whole, for a party's voice call (tvos/README.md, "Voice"): flutter_webrtc and
livekit_client, on the WebRTC build flutter_webrtc pins, whose Apple TV slices need tvOS 17. What
an Apple TV lacks is taken out of the copies (see tree_patch): the loudspeaker switches of a
phone, and the camera and screen capture (stand-ins answer "not on Apple TV"). They compile only
for the Apple TV project, so nothing here has to stay valid for an iPhone.
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

# Plugins copied whole: name -> (folder in the package, files left out)
TREES = {
    'flutter_webrtc': (
        'ios/flutter_webrtc/Sources/flutter_webrtc',
        # (screen broadcasting from a phone: ReplayKit's broadcast extension)
        lambda rel: rel.startswith('Broadcast/') or rel in {'FlutterRPScreenRecorder.m'},
    ),
    'livekit_client': (
        'ios/Classes',
        lambda rel: rel in {'BroadcastManager.swift', 'BroadcastBundleInfo.swift', 'DarwinNotificationCenter.swift'},
    ),
}
TREE_SUFFIXES = ('.m', '.mm', '.cpp', '.h', '.swift')

# Stand-ins for the parts an Apple TV has no use for (no camera of the plugin's kind, no screen
# to broadcast), answering the Dart side as the plugin does where it can't.
STUBS = {
    ('flutter_webrtc', 'CameraUtils.m'): """#import "CameraUtils.h"

// An Apple TV: no camera controls (a TV in VyseTV never sends video).
static FlutterError* VyseNoCamera(NSString* code) {
  return [FlutterError errorWithCode:code message:@"Not on Apple TV" details:nil];
}

@implementation FlutterWebRTCPlugin (CameraUtils)

- (void)mediaStreamTrackHasTorch:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  result(@NO);
}

- (void)mediaStreamTrackSetTorch:(RTCMediaStreamTrack*)track torch:(BOOL)torch result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetTorchFailed"));
}

- (void)mediaStreamTrackSetZoom:(RTCMediaStreamTrack*)track zoomLevel:(double)zoomLevel result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetZoomFailed"));
}

- (void)mediaStreamTrackSetFocusMode:(RTCMediaStreamTrack*)track focusMode:(NSString*)focusMode result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetFocusModeFailed"));
}

- (void)mediaStreamTrackSetFocusPoint:(RTCMediaStreamTrack*)track focusPoint:(NSDictionary*)focusPoint result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetFocusPointFailed"));
}

- (void)mediaStreamTrackSetExposureMode:(RTCMediaStreamTrack*)track exposureMode:(NSString*)exposureMode result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetExposureModeFailed"));
}

- (void)mediaStreamTrackSetExposurePoint:(RTCMediaStreamTrack*)track exposurePoint:(NSDictionary*)exposurePoint result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetExposurePointFailed"));
}

- (void)mediaStreamTrackSwitchCamera:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSwitchCameraFailed"));
}

- (NSInteger)selectFpsForFormat:(AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps {
  return targetFps;
}

- (AVCaptureDeviceFormat*)selectFormatForDevice:(AVCaptureDevice*)device targetWidth:(NSInteger)targetWidth targetHeight:(NSInteger)targetHeight {
  return nil;
}

- (AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position {
  return nil;
}

@end
""",
    ('flutter_webrtc', 'FlutterRTCDesktopCapturer.m'): """#import "FlutterRTCDesktopCapturer.h"

// An Apple TV: no screen sharing.
@implementation FlutterWebRTCPlugin (DesktopCapturer)

- (void)getDisplayMedia:(NSDictionary*)constraints result:(FlutterResult)result {
  result([FlutterError errorWithCode:@"getDisplayMediaFailed" message:@"Not on Apple TV" details:nil]);
}

- (void)getDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
  result(@{@"sources" : @[]});
}

- (void)updateDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
  result(@{@"result" : @NO});
}

- (void)getDesktopSourceThumbnail:(NSDictionary*)argsMap result:(FlutterResult)result {
  result([FlutterError errorWithCode:@"getDesktopSourceThumbnailFailed" message:@"Not on Apple TV" details:nil]);
}

@end
""",
}


# Audio session names an Apple TV's SDK may mark unavailable (a call's categories and modes, the
# Bluetooth headset option). Named by their values instead, which compiles either way; what tvOS
# does with such a value at run time is its own (an error the plugins already report).
OBJC_RAW = {
    'AVAudioSessionCategoryOptionAllowBluetooth': '((AVAudioSessionCategoryOptions)0x4)',
    'AVAudioSessionCategoryRecord': '@"AVAudioSessionCategoryRecord"',
    'AVAudioSessionCategoryPlayAndRecord': '@"AVAudioSessionCategoryPlayAndRecord"',
    'AVAudioSessionCategoryMultiRoute': '@"AVAudioSessionCategoryMultiRoute"',
    'AVAudioSessionModeVoiceChat': '@"AVAudioSessionModeVoiceChat"',
    'AVAudioSessionModeVideoChat': '@"AVAudioSessionModeVideoChat"',
    'AVAudioSessionModeGameChat': '@"AVAudioSessionModeGameChat"',
    'AVAudioSessionModeMeasurement': '@"AVAudioSessionModeMeasurement"',
    'AVAudioSessionModeVideoRecording': '@"AVAudioSessionModeVideoRecording"',
    'AVAudioSessionModeVoicePrompt': '@"AVAudioSessionModeVoicePrompt"',
}
SWIFT_RAW = {
    '.multiRoute': 'AVAudioSession.Category(rawValue: "AVAudioSessionCategoryMultiRoute")',
    '.playAndRecord': 'AVAudioSession.Category(rawValue: "AVAudioSessionCategoryPlayAndRecord")',
    '.record': 'AVAudioSession.Category(rawValue: "AVAudioSessionCategoryRecord")',
    '.allowBluetooth': 'AVAudioSession.CategoryOptions(rawValue: 0x4)',
    '.gameChat': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeGameChat")',
    '.measurement': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeMeasurement")',
    '.videoChat': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeVideoChat")',
    '.videoRecording': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeVideoRecording")',
    '.voiceChat': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeVoiceChat")',
    '.voicePrompt': 'AVAudioSession.Mode(rawValue: "AVAudioSessionModeVoicePrompt")',
}


def tree_patch(name, rel, text):
    """What an Apple TV lacks, taken out of a copied file (compiled for tvOS only)."""
    if name == 'flutter_webrtc':
        # a phone's loudspeaker switch: an Apple TV's sound goes where tvOS sends it
        text = text.replace('AVAudioSessionCategoryOptionDefaultToSpeaker', '((AVAudioSessionCategoryOptions)0)')
        for name_, value in OBJC_RAW.items():
            text = re.sub(r'\b' + name_ + r'\b', value, text)
        text = re.sub(r'(?m)^([ \t]*)([^\n;]*overrideOutputAudioPort:[^;]*;)',
                      lambda m: '#if !TARGET_OS_TV\n' + m.group(1) + m.group(2) + '\n#endif', text)
    if name == 'livekit_client':
        # (one target: flutter_webrtc's classes come through tvos/Runner/Runner-Bridging-Header.h)
        text = re.sub(r'(?m)^import flutter_webrtc\n', '', text)
        text = text.replace('"defaultToSpeaker": .defaultToSpeaker,', '"defaultToSpeaker": [],')
        text = re.sub(r'(?m)^([ \t]*)try rtcSession\.overrideOutputAudioPort\([^\n]*\)\n',
                      lambda m: m.group(1) + '// (an Apple TV has no loudspeaker to switch to)\n', text)
        # the maps of names the Dart side sends, and the call's own settings
        for short, value in SWIFT_RAW.items():
            text = re.sub(r'(?<=[:\[ ,(])' + re.escape(short) + r'(?=[,\]\n )])', value, text)
            text = text.replace('AVAudioSession.Category' + short + '.rawValue', value + '.rawValue')
            text = text.replace('AVAudioSession.Mode' + short + '.rawValue', value + '.rawValue')
    return text


def copy_trees(check, versions, wrong):
    for name, (sub, leave_out) in TREES.items():
        version = versions[name]
        root = pub_cache() / 'hosted' / 'pub.dev' / f'{name}-{version}' / sub
        if not root.exists():
            raise SystemExit(f'{root} is not there: run `flutter pub get` first')
        stamp = STAMP.format(name=name, version=version)
        made = set()
        for src in sorted(p for p in root.rglob('*') if p.is_file() and p.suffix in TREE_SUFFIXES):
            rel = src.relative_to(root).as_posix()
            if leave_out(rel):
                continue
            dest = OUT / name / rel
            made.add(dest)
            if check:
                have = dest.read_text(encoding='utf-8').splitlines(keepends=True)[:1] if dest.exists() else []
                if have != [stamp]:
                    wrong.append(f'{dest.relative_to(REPO)} is not the copy of {name} {version}')
                continue
            stub = STUBS.get((name, rel))
            text = stub if stub is not None else tree_patch(name, rel, src.read_text(encoding='utf-8').replace('\r\n', '\n'))
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(stamp + text, encoding='utf-8', newline='\n')
        if check:
            continue
        # (what an older copy had and this one has not)
        for old in list((OUT / name).rglob('*')):
            if old.is_file() and old not in made:
                old.unlink()
        print(f'{(OUT / name).relative_to(REPO)}  <- {name} {version} ({len(made)} files)')


def locked_versions():
    text = (REPO / 'pubspec.lock').read_text(encoding='utf-8').replace('\r\n', '\n')
    out = {}
    for name in [*PLUGINS, *TREES]:
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
    copy_trees(check, versions, wrong)
    if wrong:
        print('\n'.join(wrong[:20]) + ('' if len(wrong) <= 20 else f'\n... and {len(wrong) - 20} more'))
        print('Run: python tool/tvos/vendor_plugins.py')
        raise SystemExit(1)
    if check:
        print('The Apple TV plugin copies match pubspec.lock.')


if __name__ == '__main__':
    main()
