// Where sign-ins and keys are kept on an LG TV (lib/core/platform/webos_secrets.dart), with
// this test playing the TV's own store: one that works (webOS 24 and later), and one that
// behaves as LG's plugin does where the TV has no key service (it takes a value without a
// word and gives nothing back).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/webos_secrets.dart';

enum _Tv { works, keepsNothing, refuses, neverAnswers }

class _TvStore extends FlutterSecureStoragePlatform {
  _TvStore(this.kind);

  _Tv kind;
  final held = <String, String>{};
  var asked = 0;

  Future<void> _gate() async {
    asked++;
    if (kind == _Tv.refuses) throw PlatformException(code: 'LS2', message: 'Service does not exist: com.webos.service.keymanager3');
    if (kind == _Tv.neverAnswers) await Completer<void>().future;
  }

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    await _gate();
    if (kind == _Tv.works) held[key] = value;
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    await _gate();
    return kind == _Tv.works ? held[key] : null;
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async {
    await _gate();
    return kind == _Tv.works && held.containsKey(key);
  }

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    await _gate();
    if (kind == _Tv.works) held.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async {
    await _gate();
    return kind == _Tv.works ? Map.of(held) : {};
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    await _gate();
    if (kind == _Tv.works) held.clear();
  }
}

const _o = <String, String>{};

void main() {
  late Directory folder;
  File file() => File('${folder.path}${Platform.pathSeparator}${WebosSecrets.fileName}');
  WebosSecrets over(FlutterSecureStoragePlatform tv) => WebosSecrets(tv, folder: () async => folder, wait: const Duration(milliseconds: 150));

  setUp(() async => folder = await Directory.systemTemp.createTemp('vyse_secrets_test'));
  tearDown(() async {
    if (folder.existsSync()) await folder.delete(recursive: true);
  });

  test('a TV with the key service: everything goes to the TV, and no file is made', () async {
    final tv = _TvStore(_Tv.works);
    final secrets = over(tv);
    await secrets.write(key: 'debrid', value: 'k-123', options: _o);
    expect(await secrets.read(key: 'debrid', options: _o), 'k-123');
    expect(tv.held, {'debrid': 'k-123'}, reason: 'the value tried with is not left behind');
    expect(await secrets.sealedByTheTv, isTrue);
    expect(file().existsSync(), isFalse);
    expect(await secrets.containsKey(key: 'debrid', options: _o), isTrue);
    await secrets.delete(key: 'debrid', options: _o);
    expect(tv.held, isEmpty);
  });

  for (final kind in [_Tv.keepsNothing, _Tv.refuses, _Tv.neverAnswers]) {
    test('a TV without it (${kind.name}): values are kept in the app\'s own folder, and are there after a restart', () async {
      final secrets = over(_TvStore(kind));
      await secrets.write(key: 'debrid', value: 'k-123', options: _o);
      await secrets.write(key: 'trakt', value: 'token', options: _o);
      expect(await secrets.read(key: 'debrid', options: _o), 'k-123');
      expect(await secrets.sealedByTheTv, isFalse);
      expect(jsonDecode(file().readAsStringSync()), {'debrid': 'k-123', 'trakt': 'token'});

      // the app started again
      final again = over(_TvStore(kind));
      expect(await again.read(key: 'trakt', options: _o), 'token', reason: 'read from the file');
      expect(await again.readAll(options: _o), {'debrid': 'k-123', 'trakt': 'token'});
      expect(await again.containsKey(key: 'nothing', options: _o), isFalse);
      await again.delete(key: 'debrid', options: _o);
      expect(await again.read(key: 'debrid', options: _o), isNull);
      expect(jsonDecode(file().readAsStringSync()), {'trakt': 'token'});
      await again.deleteAll(options: _o);
      expect(await again.readAll(options: _o), isEmpty);
    });
  }

  test('a file already in use is read at once: nothing waits on a service that does not answer', () async {
    file().writeAsStringSync(jsonEncode({'debrid': 'k-123'}));
    final secrets = WebosSecrets(_TvStore(_Tv.neverAnswers), folder: () async => folder, wait: const Duration(seconds: 30));
    final watch = Stopwatch()..start();
    expect(await secrets.read(key: 'debrid', options: _o), 'k-123');
    await secrets.write(key: 'trakt', value: 'token', options: _o);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(jsonDecode(file().readAsStringSync()), {'debrid': 'k-123', 'trakt': 'token'});
  });

  test('the TV gains the key service (an update): what the file held moves into it, and the file goes', () async {
    final old = over(_TvStore(_Tv.keepsNothing));
    await old.write(key: 'debrid', value: 'k-123', options: _o);
    await old.write(key: 'trakt', value: 'token', options: _o);
    expect(file().existsSync(), isTrue);

    final tv = _TvStore(_Tv.works);
    final updated = over(tv);
    expect(await updated.read(key: 'debrid', options: _o), 'k-123', reason: 'at once, from the file');
    // (the move happens beside the app's own asking)
    for (var i = 0; i < 100 && file().existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(file().existsSync(), isFalse);
    expect(tv.held, {'debrid': 'k-123', 'trakt': 'token'});
    expect(await updated.sealedByTheTv, isTrue);
    await updated.write(key: 'simkl', value: 's', options: _o);
    expect(tv.held['simkl'], 's');
    expect(file().existsSync(), isFalse);
    expect(await updated.read(key: 'trakt', options: _o), 'token');

    // and the start after that is a TV with the key service, as any other
    final later = over(tv);
    expect(await later.readAll(options: _o), {'debrid': 'k-123', 'trakt': 'token', 'simkl': 's'});
  });

  test('a TV that holds values is taken at its word, though one try of it failed', () async {
    final tv = _TvStore(_Tv.works)..held['trakt'] = 'token';
    final secrets = over(_FlakyOnce(tv));
    expect(await secrets.read(key: 'trakt', options: _o), 'token');
    expect(await secrets.sealedByTheTv, isTrue);
    expect(file().existsSync(), isFalse);
  });

  test('a file that cannot be read is a file with nothing in it', () async {
    file().writeAsStringSync('not json {');
    final secrets = over(_TvStore(_Tv.keepsNothing));
    expect(await secrets.read(key: 'debrid', options: _o), isNull);
    await secrets.write(key: 'debrid', value: 'k', options: _o);
    expect(jsonDecode(file().readAsStringSync()), {'debrid': 'k'});
  });

  test('put in front of the plugin\'s own store once, however often it is asked', () {
    final before = FlutterSecureStoragePlatform.instance;
    addTearDown(() => FlutterSecureStoragePlatform.instance = before);
    FlutterSecureStoragePlatform.instance = _TvStore(_Tv.works);
    WebosSecrets.install();
    final first = FlutterSecureStoragePlatform.instance;
    expect(first, isA<WebosSecrets>());
    WebosSecrets.install();
    expect(FlutterSecureStoragePlatform.instance, same(first));
  });
}

/// A TV's store whose first write goes wrong, and which is fine after.
class _FlakyOnce extends FlutterSecureStoragePlatform {
  _FlakyOnce(this.inner);

  final _TvStore inner;
  var failed = false;

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) {
    if (!failed) {
      failed = true;
      throw PlatformException(code: 'LS2', message: 'busy');
    }
    return inner.write(key: key, value: value, options: options);
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) => inner.read(key: key, options: options);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) => inner.containsKey(key: key, options: options);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) => inner.delete(key: key, options: options);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) => inner.readAll(options: options);

  @override
  Future<void> deleteAll({required Map<String, String> options}) => inner.deleteAll(options: options);
}
