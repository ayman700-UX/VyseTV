import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'exceptions.dart';
import 'torrserver_controller.dart';
import 'torrserver_controller_ios.dart';

/// The engine inside the app, loaded from a shared library (libtorrserver.so, built by
/// tool/go-shim/build-tizen-so.sh with C entry points from tool/go-shim/cshared/main.go).
/// For a system that starts no program of an app's own and links no framework: a Samsung TV.
///
/// It listens on [ip] only (127.0.0.1: the engine's page and streams answer this device alone).
TorrServerController torrServerControllerFfi(String libraryPath, {String ip = '127.0.0.1'}) {
  return TorrServerControllerIos(
    startNative: (port, dataDir) async {
      final lib = _TorrServerLibrary(libraryPath);
      final dir = dataDir.toNativeUtf8();
      final at = ip.toNativeUtf8();
      try {
        final err = lib.take(lib.start(port, dir, at));
        if (err != null) throw TorrServerStartException('The torrent engine did not start: $err');
      } finally {
        malloc.free(dir);
        malloc.free(at);
      }
    },
    // (stopping waits up to five seconds for the engine: not on the interface's thread)
    stopNative: () => Isolate.run(() {
      final lib = _TorrServerLibrary(libraryPath);
      lib.take(lib.stop());
    }),
  );
}

class _TorrServerLibrary {
  _TorrServerLibrary(String path) : _lib = DynamicLibrary.open(path);

  final DynamicLibrary _lib;

  late final start = _lib.lookupFunction<Pointer<Utf8> Function(Int32, Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>)>(
    'TorrServerStart',
  );
  late final stop = _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('TorrServerStop');
  late final _free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('TorrServerFree');

  /// The engine's answer: null for none, or its error, given back to it to free.
  String? take(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    final said = p.toDartString();
    _free(p);
    return said;
  }
}
