import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/platform/webos.dart';

/// A party's voice call on an LG TV, listening, and the party's sounds there: VyseTV's own
/// LiveKit client (packages/vyse_webos/voice, Go), in lib/ beside the app's program. There is no
/// WebRTC library for an LG TV, nor a microphone LG gives an app, so the call is joined through
/// it instead of livekit_client (lib/data/party/voice.dart asks here first on LG).
abstract final class LgVoice {
  static String get _path => '${File(Platform.resolvedExecutable).parent.path}/lib/libvyse_voice.so';

  /// Whether this package has it (an LG TV, built with it).
  static bool get available => WebOS.isTv && _lib != null;

  static final _Lib? _lib = () {
    if (!WebOS.isTv) return null;
    try {
      return File(_path).existsSync() ? _Lib(DynamicLibrary.open(_path)) : null;
    } catch (_) {
      return null;
    }
  }();

  /// Starts joining; [state] says how it goes.
  static void join(String url, String token) {
    final lib = _lib;
    if (lib == null) return;
    final u = url.toNativeUtf8(), t = token.toNativeUtf8();
    try {
      lib.join(u, t);
    } finally {
      malloc.free(u);
      malloc.free(t);
    }
  }

  static void leave() => _lib?.leave();

  static void setDeafened(bool on) => _lib?.setDeafened(on ? 1 : 0);

  static void setVolume(String user, double volume) {
    final lib = _lib;
    if (lib == null) return;
    final u = user.toNativeUtf8();
    try {
      lib.setVolume(u, volume);
    } finally {
      malloc.free(u);
    }
  }

  /// The call as it is: state (off, connecting, on, failed), error, me, people (identity → mic
  /// on), speaking, output (alsa or pulse).
  static Map<String, Object?> state() {
    final lib = _lib;
    if (lib == null) return const {'state': 'off'};
    final p = lib.state();
    try {
      final said = jsonDecode(p.toDartString());
      return said is Map ? said.cast<String, Object?>() : const {'state': 'off'};
    } catch (_) {
      return const {'state': 'off'};
    } finally {
      lib.free(p);
    }
  }

  /// Plays a 16-bit WAV file through the TV's sound (call or not). An error in words, or null.
  static String? playWav(String path, double volume) {
    final lib = _lib;
    if (lib == null) return 'no voice library';
    final f = path.toNativeUtf8();
    try {
      final p = lib.playWav(f, volume);
      if (p == nullptr) return null;
      final said = p.toDartString();
      lib.free(p);
      return said;
    } finally {
      malloc.free(f);
    }
  }
}

class _Lib {
  _Lib(DynamicLibrary l)
    : join = l.lookupFunction<Void Function(Pointer<Utf8>, Pointer<Utf8>), void Function(Pointer<Utf8>, Pointer<Utf8>)>('VyseVoiceJoin'),
      leave = l.lookupFunction<Void Function(), void Function()>('VyseVoiceLeave'),
      state = l.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('VyseVoiceState'),
      setDeafened = l.lookupFunction<Void Function(Int32), void Function(int)>('VyseVoiceSetDeafened'),
      setVolume = l.lookupFunction<Void Function(Pointer<Utf8>, Double), void Function(Pointer<Utf8>, double)>('VyseVoiceSetVolume'),
      playWav = l.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Double), Pointer<Utf8> Function(Pointer<Utf8>, double)>('VyseVoicePlayWav'),
      free = l.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('VyseVoiceFree');

  final void Function(Pointer<Utf8>, Pointer<Utf8>) join;
  final void Function() leave;
  final Pointer<Utf8> Function() state;
  final void Function(int) setDeafened;
  final void Function(Pointer<Utf8>, double) setVolume;
  final Pointer<Utf8> Function(Pointer<Utf8>, double) playWav;
  final void Function(Pointer<Utf8>) free;
}
