import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

/// Where the app keeps its sign-ins and keys on an LG TV.
///
/// On every platform they go to the system's own keychain, through flutter_secure_storage. LG's
/// webOS side of that plugin seals each value with the TV's key service (keymanager3), and LG's
/// own reference says apps have that service from webOS TV 24. On an older set nothing
/// answers, and LG's plugin then keeps nothing and reads nothing back, without a word: a debrid
/// key or a sign-in would be gone the moment it was saved.
///
/// So on a TV this sits in front of LG's store. The first time anything is asked, LG's store is
/// tried (a value written, read back, removed). Where that works nothing changes. Where it does
/// not, values are kept in a file in the app's own folder on the TV. That file is not sealed by
/// the TV: this app can read it, and so can whoever has the TV in Developer Mode, which is what
/// holds for everything a web app stores on a TV. Should the TV gain the key service later (an
/// update to webOS 24 or newer), what the file holds is moved into it and the file is removed.
class WebosSecrets extends FlutterSecureStoragePlatform {
  WebosSecrets(this._tv, {Future<Directory> Function()? folder, this.wait = const Duration(seconds: 6)})
    : _folder = folder ?? getApplicationSupportDirectory;

  /// Puts this in front of the store the plugin registered. Called once, as the app starts on
  /// an LG TV (lib/main.dart).
  static void install() {
    final current = FlutterSecureStoragePlatform.instance;
    if (current is WebosSecrets) return;
    FlutterSecureStoragePlatform.instance = WebosSecrets(current);
  }

  /// The file's name, in the app's own data folder.
  static const fileName = 'keychain.json';

  static const _probe = 'vyse.keychain.probe';
  static const _none = <String, String>{};

  final FlutterSecureStoragePlatform _tv;
  final Future<Directory> Function() _folder;

  /// How long the TV's store is given to answer when it is tried.
  final Duration wait;

  Future<bool>? _decided;
  bool _useTv = false;
  Map<String, String>? _kept; // what the file holds, once read
  Future<void> _turn = Future<void>.value(); // one change of the file at a time

  /// Whether the TV's own store is the one in use (false: the file is). For the report card.
  Future<bool> get sealedByTheTv async {
    await _ready();
    return _useTv;
  }

  Future<void> _ready() => _decided ??= _decide();

  Future<bool> _decide() async {
    var hasFile = false;
    try {
      hasFile = await _exists(await _file());
    } catch (_) {
      // (no folder to look in: there is no file)
    }
    if (hasFile) {
      // This TV's store did not work before. The file is used at once (nothing waits on a
      // service that may never answer), and the TV is asked again beside it: an update may
      // have brought the service.
      await _read();
      unawaited(_tryTheTvAgain());
      return _useTv = false;
    }
    if (await _tvKeeps() || await _tvHolds()) return _useTv = true;
    // (once more: a TV that is still starting its services is not a TV without them)
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (await _tvKeeps()) return _useTv = true;
    _kept = <String, String>{};
    await _oneAtATime(_save);
    return _useTv = false;
  }

  /// Beside the file being used: the TV is asked once more, and if it now keeps what it is
  /// given, the file's values move into it. (The asking is done before anything waits on it: a
  /// change of the file is never held up by a service that does not answer.)
  Future<void> _tryTheTvAgain() async {
    if (!await _tvKeeps()) return;
    await _oneAtATime(_moveIntoTheTv);
  }

  /// A value given to the TV's store comes back as it was.
  Future<bool> _tvKeeps() async {
    try {
      final value = 'kept-${DateTime.now().microsecondsSinceEpoch}';
      await _tv.write(key: _probe, value: value, options: _none).timeout(wait);
      final back = await _tv.read(key: _probe, options: _none).timeout(wait);
      if (back != value) return false;
      await _tv.delete(key: _probe, options: _none).timeout(wait);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The TV's store already has values it can read: it works, whatever a single try said.
  Future<bool> _tvHolds() async {
    try {
      final all = await _tv.readAll(options: _none).timeout(wait);
      return all.keys.any((k) => k != _probe);
    } catch (_) {
      return false;
    }
  }

  /// The file's values into the TV's store, now that the TV has one; then no file.
  Future<void> _moveIntoTheTv() async {
    final all = await _read();
    try {
      for (final entry in all.entries) {
        if (entry.value.isEmpty) continue;
        await _tv.write(key: entry.key, value: entry.value, options: _none).timeout(wait);
        if (await _tv.read(key: entry.key, options: _none).timeout(wait) != entry.value) return;
      }
      final file = await _file();
      if (await _exists(file)) await file.delete();
    } catch (_) {
      return; // (the file stays as it is, and stays in use)
    }
    _useTv = true;
  }

  // ── the file ──

  Future<File> _file() async => File('${(await _folder()).path}${Platform.pathSeparator}$fileName');

  static Future<bool> _exists(File file) async {
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> _read() async {
    final had = _kept;
    if (had != null) return had;
    final out = <String, String>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is String) out[key] = value;
          });
        }
      }
    } catch (_) {
      // (a file that cannot be read is a file with nothing in it)
    }
    return _kept = out;
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      // (written beside it and moved into place: a TV switched off mid-write keeps the old file)
      final next = File('${file.path}.new');
      await next.writeAsString(jsonEncode(_kept ?? _none), flush: true);
      await next.rename(file.path);
    } catch (e) {
      // A folder that cannot be written: the values live as long as the app runs, and the
      // record of the start says why they will be gone after.
      stderr.writeln('[vyse] sign-ins and keys could not be saved: $e');
    }
  }

  Future<T> _oneAtATime<T>(Future<T> Function() work) {
    final done = _turn.then((_) => work());
    _turn = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _change(void Function(Map<String, String> all) how) => _oneAtATime(() async {
    how(await _read());
    await _save();
  });

  // ── what the plugin asks ──

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.write(key: key, value: value, options: options);
    await _change((all) => all[key] = value);
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.read(key: key, options: options);
    return (await _read())[key];
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.containsKey(key: key, options: options);
    return (await _read()).containsKey(key);
  }

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.delete(key: key, options: options);
    await _change((all) => all.remove(key));
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.readAll(options: options);
    return Map<String, String>.of(await _read());
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    await _ready();
    if (_useTv) return _tv.deleteAll(options: options);
    await _change((all) => all.clear());
  }
}
