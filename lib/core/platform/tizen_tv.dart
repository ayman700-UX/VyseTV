import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'webos.dart';

/// The Samsung TV build (Tizen).
///
/// Tizen runs Linux, and Dart says so there as on an LG TV: `Platform.isLinux` is true. So the
/// Tizen build is compiled with `--dart-define=VYSE_TIZEN=true` (tool/tizen does that), and
/// whatever must differ asks here: it is a TV, with a remote, Samsung's own video player
/// (mpv/player/platform/player_tizen.dart), no window to manage, and no desktop session
/// services (no D-Bus, no secret store).
abstract final class TizenTv {
  static const _build = bool.fromEnvironment('VYSE_TIZEN');

  /// Tests run on a PC: this stands in for "the Tizen build".
  @visibleForTesting
  static bool? debugIs;

  /// Whether this is the app on a Samsung TV.
  static bool get isTv => debugIs ?? _build;

  /// The package's id (tizen/tizen-manifest.xml).
  static const packageId = 'com.vyse.vysetv';

  /// Which of the Samsung packages this is: the Tizen version it was built for (6.0, 6.5 or
  /// 10.0; tool/tizen/build.sh says it with --dart-define=VYSE_TIZEN_API). Updates name the
  /// package for it.
  static const packageApi = String.fromEnvironment('VYSE_TIZEN_API', defaultValue: '6.5');

  /// The full path of a library the package carries in its lib/ folder (tool/tizen/native.sh
  /// builds them: the JavaScript engine plugins run in, the torrent engine), or null when the
  /// package has none by that name.
  ///
  /// Named by its whole path: nothing promises that a TV looks in the app's own folder for a
  /// library asked for by name alone. Where the app is installed is asked of the system
  /// (`app_get_resource_path`: the package's res/ folder, beside its lib/); the places Tizen
  /// installs apps are tried after that.
  static String? library(String name) {
    for (final dir in _libraryDirs()) {
      final path = '$dir/$name';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static List<String>? _dirs;

  /// A party's short sound, a WAV file on this device, through Tizen's own WAV player (the
  /// TV's player is the film's: a sound there would take it). As a notification's sound, which
  /// the TV mixes over what plays rather than pausing it; as a system sound where it will not
  /// take that. Whether it is heard is the TV's to say: nothing here is proven on a TV.
  static void playWav(String path) {
    try {
      final sm = DynamicLibrary.open('libcapi-media-sound-manager.so.0');
      final wav = DynamicLibrary.open('libcapi-media-wav-player.so.0');
      final createInfo = sm.lookupFunction<Int32 Function(Int32, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>), int Function(int, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(
        'sound_manager_create_stream_information',
      );
      final start = wav.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>), int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>)>(
        'wav_player_start_new',
      );
      final file = path.toNativeUtf8();
      final id = malloc<Int32>();
      final info = malloc<Pointer<Void>>();
      try {
        // (Tizen's stream types: 3 a notification, 1 a system sound; never 0, the film's)
        for (final type in const [3, 1]) {
          _streams[type] ??= () {
            info.value = nullptr;
            return createInfo(type, nullptr, nullptr, info) == 0 ? info.value : null;
          }();
          final stream = _streams[type];
          if (stream != null && start(file, stream, nullptr, nullptr, id) == 0) return;
        }
      } finally {
        malloc.free(file);
        malloc.free(id);
        malloc.free(info);
      }
    } catch (_) {
      // (no such library on this TV: no sound)
    }
  }

  // the stream information each kind of sound plays with, made once
  static final _streams = <int, Pointer<Void>?>{};

  static List<String> _libraryDirs() => _dirs ??= [
    if (_resourceDir() case final res?) '${Directory(res).parent.path}/lib',
    '/opt/usr/globalapps/$packageId/lib',
    '/opt/usr/apps/$packageId/lib',
    '/usr/apps/$packageId/lib',
  ];

  /// The package's res/ folder, from Tizen's app framework (null where there is none: a PC).
  static String? _resourceDir() {
    try {
      final lib = DynamicLibrary.open('libcapi-appfw-app-common.so.0');
      final get = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('app_get_resource_path');
      final p = get();
      if (p == nullptr) return null;
      final path = p.toDartString();
      malloc.free(p); // (the framework hands over a copy made with malloc)
      return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    } catch (_) {
      return null;
    }
  }
}

/// A TV whose system Dart takes for Linux: LG's webOS or Samsung's Tizen. What either needs
/// apart from a Linux desktop (no desktop windows, no session bus, the TV's own player, a
/// remote) asks here; what only one of them has asks [WebOS] or [TizenTv].
abstract final class LinuxTv {
  static bool get isTv => WebOS.isTv || TizenTv.isTv;
}
