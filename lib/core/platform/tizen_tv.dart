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
