// The Usenet engine beside the app (packages/vyse_usenet): starting it the way this device
// allows, its control API, and letting it go when nothing plays from it.
//
// It is a program the app starts on Android, Windows, Linux, macOS and LG TVs (stdin carries
// its bootstrap record and holds it alive: when VyseTV ends, however it ends, the engine's
// stdin closes and it stops), a library inside the app on iPhone, iPad and Apple TV, and a
// library loaded into the app on Samsung TVs. Whichever, it serves on 127.0.0.1 and a port of
// its own; control requests carry a random token made here, and the player reads the media
// through unguessable session addresses.
//
// One session at a time belongs to the app (the one playing, or one prepared for a click): each
// open names it (`keepSessionId`), and the engine drops every other, which also recovers an open
// whose answer or a close that never arrived.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vyse_usenet/vyse_usenet.dart';

import '../../core/platform/tizen_tv.dart';
import '../app_settings.dart';

/// Where a failure stops the fallback to other releases: the engine or the settings (no other
/// release would fare better), the providers (other releases on the same providers would fail
/// alike), or this source (try the next).
enum UsenetFailureScope { engine, provider, source }

/// Why the engine would not open a release, or would not go on playing it.
class UsenetEngineError implements Exception {
  UsenetEngineError(this.message, {this.status = 0, this.kind, this.scope = UsenetFailureScope.source, this.providers});
  final String message;
  final int status;

  /// The engine's failure kind (`X-Usenet-Failure`): configuration, provider, missing-article,
  /// hole-limit, invalid-article, blank-content, provider-authentication, provider-quota,
  /// temporary-read-error; null when it gave none.
  final String? kind;
  final UsenetFailureScope scope;

  /// What each provider did before the open failed (`X-Usenet-Providers`).
  final List<Map<String, Object?>>? providers;

  /// The release itself won't play from these providers (gone, incomplete, damaged, empty): worth
  /// remembering, so it is listed last and never tried by itself again.
  bool get releaseIsBad => const {'missing-article', 'hole-limit', 'invalid-article', 'blank-content'}.contains(kind);

  @override
  String toString() => message;
}

/// A release opened in the engine: the address the player reads, and what it is.
class UsenetSession {
  UsenetSession({required this.id, required this.url, required this.filename, required this.size, required this.subtitles, required this.startup, required this.servers});
  final String id;
  final String url;
  final String filename;
  final int size;

  /// Subtitle files that came with the release: id, file name, language and address each.
  final List<({String id, String filename, String lang, String url})> subtitles;

  /// How the open went, step by step (the engine's own timings and its NZB cache outcome).
  final Map<String, Object?> startup;

  /// The provider addresses it was opened with (provider counts name them by their place here).
  final List<String> servers;

  /// Whether its NZB came from the engine's cache (so the indexer was not asked: no grab).
  bool get nzbFromCache => (startup['nzbCache'] as Map?)?['lookup'] == 'hit';
}

class UsenetEngine {
  UsenetEngine._();
  static final instance = UsenetEngine._();

  /// Seconds an engine with no session is kept, should another release open soon.
  static const idleSeconds = 30;

  String? _token;
  int? _port;
  Process? _process;
  UsenetLibrary? _library;
  bool _linked = false;
  Future<void>? _starting;
  Timer? _idle;

  /// The session that is ours (playing, or prepared), or null.
  String? _owned;
  final _servers = <String, List<String>>{}; // session → the servers it was opened with
  final _retired = <String>{};
  final _ports = <int>[]; // the last 8 ports engines of this run served on
  final _stderr = <String>[];

  /// Provider counts reported as sessions close (statistics listen: usenet_stats.dart).
  void Function(List<String> servers, List<Map<String, Object?>> report, {required bool refused, String? kind})? onProviderReport;

  /// The engine's last words on stderr.
  List<String> get lastErrors => List.unmodifiable(_stderr);

  /// Whether this device runs the engine at all.
  static bool get supported =>
      !kIsWeb &&
      (TizenTv.isTv
          ? TizenTv.library('libvyse_usenet.so') != null
          : (Platform.isAndroid || Platform.isWindows || Platform.isLinux || Platform.isMacOS || Platform.isIOS));

  bool get running => _port != null;

  /// The memory the engine may use, in MiB, by Settings > Usenet > Performance profile.
  static int get memoryMiB => switch (AppSettings.usenetProfile.value) {
    'low-memory' => 96,
    'throughput' => 224,
    _ => 144,
  };

  /// The engine's address, starting it first if need be.
  Future<Uri> base() async {
    await (_starting ??= _start().whenComplete(() => _starting = null));
    final port = _port;
    if (port == null) throw UsenetEngineError('Usenet engine could not start', scope: UsenetFailureScope.engine);
    return Uri.parse('http://127.0.0.1:$port');
  }

  Future<void> _start() async {
    if (_port != null) return;
    final rnd = Random.secure();
    final token = List.generate(32, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final support = debugSupportDir ?? await getApplicationSupportDirectory();
    final cache = Directory('${support.path}${Platform.pathSeparator}usenet${Platform.pathSeparator}nzb-cache');
    if (AppSettings.usenetCacheNzb.value) await cache.create(recursive: true);
    final bootstrap = jsonEncode({'token': token, 'certificates': const <String>[], 'memoryMiB': memoryMiB, 'nzbCacheDir': AppSettings.usenetCacheNzb.value ? cache.path : ''});
    _stderr.clear();
    if (TizenTv.isTv) {
      final path = TizenTv.library('libvyse_usenet.so');
      if (path == null) throw UsenetEngineError('Usenet engine is missing for this device', scope: UsenetFailureScope.engine);
      final lib = _library ??= UsenetLibrary(path);
      lib.stop(); // (a start while one runs keeps the first one's token: ours would be refused)
      _port = lib.start(bootstrap);
    } else if (Platform.isIOS) {
      await UsenetLinked.stop().catchError((Object _) {});
      _port = await UsenetLinked.start(bootstrap);
      _linked = true;
    } else {
      final path = await _runnable();
      final Process p;
      try {
        p = await Process.start(path, const [], environment: const {'GODEBUG': 'madvdontneed=1'});
      } catch (_) {
        throw UsenetEngineError('Usenet engine could not start', scope: UsenetFailureScope.engine);
      }
      _process = p;
      p.stdin.writeln(bootstrap);
      await p.stdin.flush();
      final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter());
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        _stderr.add(l);
        if (_stderr.length > 20) _stderr.removeAt(0);
      }, onError: (Object _) {});
      final first = Completer<String>();
      lines.listen((l) {
        if (!first.isCompleted) first.complete(l);
      }, onError: (Object _) {}, onDone: () {
        if (!first.isCompleted) first.completeError(StateError('stopped'));
      });
      unawaited(p.exitCode.then((_) {
        if (identical(_process, p)) {
          _process = null;
          _port = null;
          _owned = null;
          _retired.clear();
        }
      }));
      try {
        final ready = jsonDecode(await first.future.timeout(const Duration(seconds: 15))) as Map;
        if (ready['protocol'] != 1) throw StateError('protocol ${ready['protocol']}');
        _port = (ready['port'] as num).toInt();
      } catch (_) {
        p.kill();
        _process = null;
        throw UsenetEngineError('Usenet engine could not start', scope: UsenetFailureScope.engine);
      }
    }
    _token = token;
    _ports.add(_port!);
    if (_ports.length > 8) _ports.removeAt(0);
  }

  /// The engine program, where it can be run from. A Linux bundle (an AppImage above all)
  /// installs it as a plain file and may be read-only: then a copy is made in the app's own
  /// folder and marked as a program.
  Future<String> _runnable() async {
    final path = debugProgram ?? await UsenetProgram.path();
    if (path == null) throw UsenetEngineError('Usenet engine is missing for this device', scope: UsenetFailureScope.engine);
    if (Platform.isWindows || Platform.isAndroid) return path;
    final stat = await File(path).stat();
    if (stat.mode & 0x49 == 0x49) return path; // runnable by everyone already
    final support = debugSupportDir ?? await getApplicationSupportDirectory();
    final copy = File('${support.path}/usenet/${UsenetProgram.fileName}');
    final source = File(path);
    if (!await copy.exists() || (await copy.length()) != await source.length()) {
      await copy.parent.create(recursive: true);
      await source.copy(copy.path);
    }
    await Process.run('chmod', ['755', copy.path]);
    return copy.path;
  }

  /// Ends the engine now (every session with it).
  Future<void> stop() async {
    _idle?.cancel();
    _owned = null;
    _retired.clear();
    final p = _process, lib = _library;
    _process = null;
    _port = null;
    _token = null;
    if (p != null) {
      try {
        await p.stdin.close(); // the engine's sign to stop
      } catch (_) {}
      unawaited(p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
        p.kill();
        return -1;
      }));
    }
    if (lib != null) lib.stop();
    if (_linked) {
      _linked = false;
      await UsenetLinked.stop().catchError((Object _) {});
    }
  }

  /// No session left: the engine goes after [idleSeconds] (or [after]), unless one opens before.
  void _maybeIdle([Duration after = const Duration(seconds: idleSeconds)]) {
    _idle?.cancel();
    if (_owned != null || AppSettings.usenetPrewarm.value) return;
    _idle = Timer(after, () {
      if (_owned == null && !AppSettings.usenetPrewarm.value) unawaited(stop());
    });
  }

  /// The app went to the background: an engine with nothing of ours goes now.
  Future<void> backgrounded() async {
    if (_owned == null && running) await stop();
  }

  /// The app came to the front: "Pre-warm Usenet Engine" starts it, ready for a release.
  Future<void> foregrounded() async {
    if (AppSettings.usenetPrewarm.value && supported && !running) {
      try {
        await base();
      } catch (_) {}
    }
  }

  // ── addresses ──

  /// The player's address for a session: the engine's `path`, each part percent-encoded.
  static String streamUrl(Uri base, String id, String path) {
    final prefix = '/stream/$id/';
    final name = path.startsWith(prefix) ? path.substring(prefix.length) : path.split('/').last;
    final parts = name.split('/').map(_encodeSegment).join('/');
    return '${base.toString().replaceAll(RegExp(r'/$'), '')}/stream/$id/$parts';
  }

  static String _encodeSegment(String s) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      if (RegExp(r"[A-Za-z0-9_\-!.~'()*]").hasMatch(c) && b < 128) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static final _sessionUrl = RegExp(r'^http://127\.0\.0\.1:(\d{1,5})/(stream|subtitle)/([0-9a-f]{48})/');

  /// The session a player address reads from, if it is one of this run's engines'.
  String? sessionOf(String url) {
    final m = _sessionUrl.firstMatch(url);
    if (m == null || !_ports.contains(int.parse(m.group(1)!))) return null;
    return m.group(3);
  }

  bool isEngineUrl(String url) => sessionOf(url) != null;

  // ── control API ──

  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'DIRECT';

  Future<(int, Map<String, String>, String)> _call(String method, String path, {Object? body, required Duration timeout}) async {
    final b = await base();
    try {
      final req = await _http.openUrl(method, b.resolve(path)).timeout(timeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout, onTimeout: () => throw UsenetEngineError('Usenet engine response was interrupted'));
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.where((x) => x.trim().isNotEmpty).firstOrNull?.trim() ?? '');
      return (res.statusCode, headers, text);
    } on UsenetEngineError {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw UsenetEngineError('Usenet engine connection failed', scope: UsenetFailureScope.engine);
    }
  }

  static List<Map<String, Object?>>? _report(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      final list = j is Map ? j['providers'] : null;
      return [if (list is List) for (final p in list.whereType<Map>()) p.cast<String, Object?>()];
    } catch (_) {
      return null;
    }
  }

  /// Opens a release: [request] is the engine's open request without `keepSessionId` (the
  /// session ours now is kept until this one is ready, then let go). [timeout]: the open gives
  /// up (and the engine with it) after this long.
  Future<UsenetSession> open(Map<String, Object?> request, {Duration timeout = const Duration(seconds: 120)}) async {
    _idle?.cancel();
    final previous = _owned;
    final servers = [for (final s in (request['servers'] as List? ?? const [])) '$s'];
    try {
      final (status, headers, text) = await _call('POST', '/sessions', body: {...request, 'keepSessionId': previous ?? ''}, timeout: timeout);
      if (status != 200) {
        final kind = headers['x-usenet-failure'];
        final providers = _report(headers['x-usenet-providers']);
        if (providers != null) onProviderReport?.call(servers, providers, refused: true, kind: kind);
        final body = text.trim();
        throw UsenetEngineError(
          body.isEmpty ? 'Usenet engine returned HTTP $status' : (body.length > 240 ? body.substring(0, 240) : body),
          status: status,
          kind: kind,
          scope: kind == 'configuration' ? UsenetFailureScope.engine : (kind == 'provider' ? UsenetFailureScope.provider : UsenetFailureScope.source),
          providers: providers,
        );
      }
      final j = jsonDecode(text);
      final id = j is Map ? '${j['id'] ?? ''}' : '';
      final path = j is Map ? '${j['path'] ?? ''}' : '';
      if (!RegExp(r'^[0-9a-f]{48}$').hasMatch(id) || !path.startsWith('/stream/$id/') || j['filename'] is! String || j['size'] is! num) {
        throw UsenetEngineError('Usenet stream could not be opened');
      }
      final b = await base();
      final session = UsenetSession(
        id: id,
        url: streamUrl(b, id, path),
        filename: j['filename'] as String,
        size: (j['size'] as num).toInt(),
        servers: servers,
        subtitles: [
          for (final s in (j['subtitles'] as List? ?? const []).whereType<Map>())
            if (s['path'] is String)
              (id: '${s['id'] ?? ''}', filename: '${s['filename'] ?? ''}', lang: '${s['lang'] ?? 'und'}', url: b.resolve(s['path'] as String).toString()),
        ],
        startup: (j['startup'] as Map?)?.cast<String, Object?>() ?? const {},
      );
      // the engine let every other session go; ours is this one now
      _retired.clear();
      _servers.removeWhere((k, _) => k != previous && k != id);
      _servers[id] = servers;
      _owned = id;
      if (previous != null && previous != id) _retire(previous);
      return session;
    } catch (e) {
      // a failed or abandoned open leaves what played playing; with nothing else of ours, the
      // engine goes too
      if (previous == null || _owned != previous || !running) {
        unawaited(stop());
      } else {
        _maybeIdle();
      }
      if (e is UsenetEngineError) rethrow;
      if (e is TimeoutException) throw UsenetEngineError('Usenet source preparation timed out');
      throw UsenetEngineError('Usenet stream could not be opened');
    }
  }

  /// Lets a session go (the player closed, or it was never played): its provider counts go to
  /// the statistics. An engine that doesn't answer in 2 s is stopped whole.
  Future<void> release(String id) async {
    if (_owned == id) _owned = null;
    if (!running) return;
    try {
      final (status, _, text) = await _call('DELETE', '/sessions/${Uri.encodeComponent(id)}', timeout: const Duration(seconds: 2));
      final report = status == 200 ? _report(text) : null;
      final servers = _servers.remove(id);
      if (report != null && servers != null) onProviderReport?.call(servers, report, refused: false);
    } catch (_) {
      await stop();
      return;
    }
    _maybeIdle();
  }

  /// A replaced session, let go in the background: three tries (now, after 1 s, after 2 s more);
  /// the next open lets go of anything still left.
  void _retire(String id) {
    _retired.add(id);
    unawaited(() async {
      for (final wait in const [0, 1, 2]) {
        if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
        if (!_retired.contains(id) || !running) return;
        try {
          final (status, _, text) = await _call('DELETE', '/sessions/${Uri.encodeComponent(id)}', timeout: const Duration(seconds: 2));
          if (status != 200 && status != 204) continue;
          _retired.remove(id);
          final report = status == 200 ? _report(text) : null;
          final servers = _servers.remove(id);
          if (report != null && servers != null) onProviderReport?.call(servers, report, refused: false);
          return;
        } catch (_) {}
      }
    }());
  }

  /// What the engine knows of a session now: provider counts, cache, failures (null when it
  /// doesn't answer in [timeout]).
  Future<Map<String, Object?>?> diagnostics(String id, {Duration timeout = const Duration(milliseconds: 800)}) async {
    if (!running) return null;
    try {
      final (status, _, text) = await _call('GET', '/sessions/${Uri.encodeComponent(id)}/diagnostics', timeout: timeout);
      if (status != 200) return null;
      return (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  /// The servers [id] was opened with.
  List<String> serversOf(String id) => _servers[id] ?? const [];

  /// The session that is ours now.
  String? get owned => _owned;

  /// Tests: the engine program to run, and the folder standing in for the app's own.
  @visibleForTesting
  static String? debugProgram;
  @visibleForTesting
  static Directory? debugSupportDir;
}
