/// The native pieces of VyseTV's Usenet engine. Which one a device uses is the app's to say
/// (lib/data/usenet/usenet_engine.dart):
///
/// * a program the app starts and talks to over stdin/stdout (Android, Windows, Linux, macOS,
///   LG): [UsenetProgram.path] says where the build put it;
/// * a library inside the app (iPhone, iPad, Apple TV): [UsenetLinked] starts it through the
///   plugin;
/// * a library the app loads (Samsung): [UsenetLibrary], over dart:ffi.
///
/// Whichever runs, the engine serves on 127.0.0.1 and a port of its own, and speaks the same
/// HTTP to the app and the player (README.md).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('vyse/usenet');

/// The engine as a program next to the app.
class UsenetProgram {
  /// Its file name in the build: `libvyse_usenet.so` on Android (installed with the app's native
  /// libraries), `vyse-usenet.exe` on Windows, `vyse-usenet` elsewhere.
  static String get fileName => Platform.isAndroid ? 'libvyse_usenet.so' : (Platform.isWindows ? 'vyse-usenet.exe' : 'vyse-usenet');

  /// Where the build put it, or null when this build has none: Android's native library folder;
  /// next to the program on Windows; the bundle's `lib/` on Linux and LG; the plugin
  /// framework's resources on macOS.
  static Future<String?> path() async {
    if (Platform.isAndroid) {
      try {
        final dir = await _channel.invokeMethod<String>('nativeLibraryDir');
        if (dir != null && File('$dir/$fileName').existsSync()) return '$dir/$fileName';
      } catch (_) {}
      return null;
    }
    final exe = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      if (Platform.isWindows) '$exe$sep$fileName',
      // (an older LG's package starts the app under a loader of its own: from there, ../lib)
      if (Platform.isLinux) ...['$exe/lib/$fileName', '$exe/$fileName', '$exe/../lib/$fileName'],
      if (Platform.isMacOS) ...[
        '$exe/../Frameworks/vyse_usenet.framework/Resources/$fileName',
        '$exe/../Frameworks/vyse_usenet.framework/Versions/A/Resources/$fileName',
        '$exe/../Resources/$fileName',
      ],
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return null;
  }
}

/// The engine linked into the app (iPhone, iPad, Apple TV), started through the plugin.
class UsenetLinked {
  /// Whether this build carries it.
  static Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('hasEngine') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts it with its [bootstrap] record (JSON); answers its port.
  static Future<int> start(String bootstrap) async {
    final port = await _channel.invokeMethod<int>('start', bootstrap);
    if (port == null || port <= 0) throw StateError('the Usenet engine did not start');
    return port;
  }

  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}

typedef _StartC = Int32 Function(Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>);
typedef _StopC = Void Function();
typedef _StopDart = void Function();
typedef _ErrorC = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();

/// The engine as a library loaded into the app's process (Samsung TVs), over dart:ffi.
class UsenetLibrary {
  UsenetLibrary(String path) : this._(DynamicLibrary.open(path));

  UsenetLibrary._(DynamicLibrary lib)
    : _start = lib.lookupFunction<_StartC, _StartDart>('VyseUsenetStart'),
      _stop = lib.lookupFunction<_StopC, _StopDart>('VyseUsenetStop'),
      _error = lib.lookupFunction<_ErrorC, _ErrorDart>('VyseUsenetError');

  final _StartDart _start;
  final _StopDart _stop;
  final _ErrorDart _error;

  /// Starts it with its [bootstrap] record (JSON); answers its port. A second start while it
  /// runs answers the running engine's port.
  int start(String bootstrap) {
    final b = bootstrap.toNativeUtf8();
    try {
      final port = _start(b);
      if (port > 0) return port;
      final e = _error();
      throw StateError(e == nullptr ? 'the Usenet engine did not start' : e.toDartString());
    } finally {
      malloc.free(b);
    }
  }

  void stop() => _stop();
}
