import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../app_settings.dart';
import '../../net.dart';
import '../film_sources/common.dart';
import '../film_sources/film_sources.dart' show FilmSource;

/// Scraper plugins: JavaScript files from a GitHub (or any web) repository, run in a sandboxed
/// QuickJS engine, that find the streams for a film or an episode.
///
/// You add a repository's `repo.json` link in Settings → Sources. Every plugin it lists is
/// downloaded and becomes a source like the built-in ones: it can be reordered or switched off,
/// and the player asks it in turn. See docs/plugins/README.md for the repo and plugin format.
///
/// What a script can do is only what the bridge below gives it: `http()` to fetch web pages
/// (never this device's own network) and plain computation. No files, no other apps.

const _maxPlugins = 100;
const _maxScript = 512 * 1024;
const _maxBody = 8 * 1024 * 1024;
const _runTimeout = Duration(seconds: 25);

// ── repositories ──

@immutable
class JsPlugin {
  const JsPlugin({
    required this.id,
    required this.name,
    required this.url,
    required this.code,
    this.version = '',
    this.note = '',
    this.types = const ['movie', 'tv'],
  });

  /// The plugin's own id inside its repository.
  final String id;
  final String name;

  /// Where its script came from.
  final String url;
  final String code;
  final String version, note;

  /// 'movie' and/or 'tv'.
  final List<String> types;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url, 'code': code, 'version': version, 'note': note, 'types': types};

  static JsPlugin? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], url = j['url'], code = j['code'];
    if (id is! String || name is! String || url is! String || code is! String) return null;
    return JsPlugin(id: id, name: name, url: url, code: code, version: '${j['version'] ?? ''}', note: '${j['note'] ?? ''}', types: _types(j['types']));
  }
}

List<String> _types(Object? v) {
  final t = [
    if (v is List)
      for (final x in v)
        if (x == 'movie' || x == 'tv') x as String,
  ];
  return t.isEmpty ? const ['movie', 'tv'] : t;
}

@immutable
class PluginRepo {
  const PluginRepo({required this.url, required this.name, this.plugins = const []});

  /// The `repo.json` link.
  final String url;
  final String name;
  final List<JsPlugin> plugins;

  Map<String, Object?> toJson() => {
    'url': url,
    'name': name,
    'plugins': [for (final p in plugins) p.toJson()],
  };

  static PluginRepo? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return PluginRepo(
      url: j['url'] as String,
      name: '${j['name'] ?? j['url']}',
      plugins: [
        if (j['plugins'] is List)
          for (final p in j['plugins'] as List) ?JsPlugin.fromJson(p),
      ],
    );
  }
}

/// The repository file is not there any more (HTTP 404 or 410): it was deleted or moved.
class RepoGone extends FormatException {
  RepoGone(String url) : super('That link is gone (404): the repository file was deleted or moved.', url);
}

/// A GitHub page link to the file becomes the link to its raw text; a bare repository link
/// means its `repo.json` on the default branch. Anything else is used as given.
String normalizeRepoUrl(String input) {
  final u = input.trim();
  final blob = RegExp(r'^https?://github\.com/([^/]+)/([^/]+)/blob/(.+)$').firstMatch(u);
  if (blob != null) return 'https://raw.githubusercontent.com/${blob[1]}/${blob[2]}/${blob[3]}';
  final bare = RegExp(r'^https?://github\.com/([^/]+)/([^/#?]+?)(?:\.git)?/?$').firstMatch(u);
  if (bare != null) return 'https://raw.githubusercontent.com/${bare[1]}/${bare[2]}/HEAD/repo.json';
  return u;
}

// ── Vega providers (https://github.com/Zenda-Cross/vega-providers) ──
// A Vega repository's manifest.json is a list of providers, each built into dist/<value>/{posts,meta,stream,episodes}.js
// next to it. VyseTV composes those modules into one script that assets/plugins/vega_runtime.js (axios, cheerio, an
// adapter) runs: it searches the provider's site for the title, opens the page and resolves the stream.

/// Providers that are not about films and shows, or hand out torrents/live channels: not listed.
const _vegaSkip = {'torrentio', 'youtube', 'durbinLive', 'liveTgTv'};

/// The text that starts a composed Vega plugin's script.
const vegaMarker = '// @vega-provider ';

({String name, List<({String id, String name, String url, String version, String note, List<String> types, bool vega})> plugins}) _parseVegaManifest(
  List<Object?> list,
  String manifestUrl,
) {
  // the repository's folder: the manifest's link without its query and its file name
  final clean = manifestUrl.split(RegExp(r'[?#]')).first;
  final base = clean.substring(0, clean.lastIndexOf('/'));
  final out = <({String id, String name, String url, String version, String note, List<String> types, bool vega})>[];
  final seen = <String>{};
  for (final p in list) {
    if (p is! Map || p['value'] is! String) continue;
    final value = (p['value'] as String).trim();
    if (p['disabled'] == true || _vegaSkip.contains(value) || !RegExp(r'^[A-Za-z0-9_.-]{1,60}$').hasMatch(value)) continue;
    final id = 'vega-$value';
    if (!seen.add(id)) continue;
    final kind = '${p['type'] ?? ''}';
    out.add((
      id: id,
      name: '${p['display_name'] ?? value}',
      url: '$base/dist/$value',
      version: '${p['version'] ?? ''}',
      note: 'Vega provider${kind.isEmpty ? '' : ' ($kind)'}',
      types: const ['movie', 'tv'],
      vega: true,
    ));
    if (out.length >= _maxPlugins) break;
  }
  return (name: 'Vega providers', plugins: out);
}

/// The script of the Vega provider whose built modules are at [distUrl] (`…/dist/<value>`): posts, meta and stream are
/// needed, episodes is optional. [fetch] downloads one file. Throws when a needed module can't be read.
Future<String> composeVegaPlugin(String distUrl, String version, Future<String> Function(String url) fetch) async {
  final value = distUrl.substring(distUrl.lastIndexOf('/') + 1);
  final base = distUrl.substring(0, distUrl.length - '/dist/$value'.length);
  final b = StringBuffer('$vegaMarker$value\n// @vega-version $version\n__vega.source(${jsonEncode(base)}, ${jsonEncode(value)});\n');
  for (final m in const ['posts', 'meta', 'stream', 'episodes']) {
    final String code;
    try {
      code = await fetch('$distUrl/$m.js');
    } catch (e) {
      if (m == 'episodes' && e is HttpError && e.status == 404) continue;
      rethrow;
    }
    b.write('__vega.module(${jsonEncode(m)}, function (exports, module, require, __awaiter, providerGlobal) {\n$code\n});\n');
  }
  return b.toString();
}

/// A repository file: `{"name": "…", "plugins": [{"id","name","url","version","note","types"}]}`.
/// Each plugin's `url` may be relative to the repository file. Returns (name, entries).
({String name, List<({String id, String name, String url, String version, String note, List<String> types, bool vega})> plugins}) parseRepoFile(
  String text,
  String repoUrl,
) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    throw const FormatException('That link is not a JSON file.');
  }
  if (j is List) return _parseVegaManifest(j, repoUrl);
  if (j is! Map || j['plugins'] is! List) throw const FormatException('Not a plugin repository: it has no "plugins" list.');
  final base = Uri.parse(repoUrl);
  final out = <({String id, String name, String url, String version, String note, List<String> types, bool vega})>[];
  final seen = <String>{};
  for (final p in j['plugins'] as List) {
    if (p is! Map || p['url'] is! String) continue;
    final url = base.resolve(p['url'] as String);
    if (url.scheme != 'https' && url.scheme != 'http') continue;
    final id = '${p['id'] ?? ''}'.trim().isEmpty ? url.pathSegments.last.replaceAll(RegExp(r'\.js$'), '') : '${p['id']}'.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id) || !seen.add(id)) continue;
    out.add((
      id: id,
      name: '${p['name'] ?? id}',
      url: '$url',
      version: '${p['version'] ?? ''}',
      note: '${p['note'] ?? ''}',
      types: _types(p['types']),
      vega: false,
    ));
    if (out.length >= _maxPlugins) break;
  }
  return (name: '${j['name'] ?? ''}'.trim(), plugins: out);
}

/// What the plugins reported on their runs (their console.log lines, errors, timeouts). A TV's Android log can't be read, so
/// Settings → Sources → Plugins shows these; on Android they are also written to a file in the app's external folder
/// (`/sdcard/Android/data/PACKAGE/files/plugin-log.txt`) that adb can read.
class PluginLog {
  PluginLog._();
  static final lines = ValueNotifier<List<String>>(const []);
  static const _max = 300;

  static void add(String source, List<String> entries) {
    if (entries.isEmpty) return;
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final tag = source.isEmpty ? '' : '[$source] ';
    final next = [...lines.value, for (final e in entries) '$stamp $tag$e'];
    lines.value = next.length > _max ? next.sublist(next.length - _max) : next;
    for (final e in entries) {
      debugPrint('[plugin${source.isEmpty ? '' : ' $source'}] $e');
    }
    unawaited(_write());
  }

  static void clear() {
    lines.value = const [];
    unawaited(_write());
  }

  static Future<void> _write() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) await File('${dir.path}/plugin-log.txt').writeAsString(lines.value.join('\n'));
    } catch (_) {} // (best effort: the log in Settings is the one to rely on)
  }
}

/// The installed repositories (this device only: scripts are not synced between devices).
class JsPlugins {
  JsPlugins._();

  static final repos = ValueNotifier<List<PluginRepo>>(const []);
  static bool _loaded = false;

  static void load() {
    if (_loaded) return;
    _loaded = true;
    _read();
    AppSettings.plugins.addListener(_read);
  }

  static void _read() {
    try {
      final j = jsonDecode(AppSettings.plugins.value.isEmpty ? '[]' : AppSettings.plugins.value);
      repos.value = [
        if (j is List)
          for (final r in j) ?PluginRepo.fromJson(r),
      ];
    } catch (_) {
      repos.value = const [];
    }
  }

  static void _save(List<PluginRepo> next) {
    repos.value = next;
    AppSettings.plugins.set(jsonEncode([for (final r in next) r.toJson()]));
  }

  /// What an update does with a repository's plugins: the ones still at the same version are kept as they are,
  /// the new and changed ones are downloaded, the ones the repository no longer lists are dropped.
  @visibleForTesting
  static ({List<String> keep, List<String> fetch, List<String> drop}) planUpdate(
    List<JsPlugin> installed,
    List<({String id, String version, String url})> listed,
  ) {
    final have = {for (final p in installed) p.id: p};
    final keep = <String>[], fetch = <String>[];
    for (final e in listed) {
      final h = have[e.id];
      // (a plugin with no version can't be told apart from its update: it is always downloaded again)
      if (h != null && e.version.isNotEmpty && h.version == e.version && h.url == e.url) {
        keep.add(e.id);
      } else {
        fetch.add(e.id);
      }
    }
    final listedIds = {for (final e in listed) e.id};
    return (
      keep: keep,
      fetch: fetch,
      drop: [
        for (final p in installed)
          if (!listedIds.contains(p.id)) p.id,
      ],
    );
  }

  /// Reads the repository file at [url] and returns the repository with its plugins' scripts. With [existing] and
  /// [onlyChanged] the scripts that haven't changed version are not downloaded again.
  static Future<PluginRepo> _fetchRepo(String url, {PluginRepo? existing, bool onlyChanged = false}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) throw const FormatException('Paste a link starting with https://');
    final String text;
    try {
      text = await fetchText(url, timeout: const Duration(seconds: 20));
    } catch (e) {
      if (e is HttpError && (e.status == 404 || e.status == 410)) throw RepoGone(url);
      throw FormatException('Could not open that link ($e).');
    }
    final parsed = parseRepoFile(text, url);
    if (parsed.plugins.isEmpty) throw const FormatException('That repository lists no plugins.');
    final plan = planUpdate(onlyChanged ? (existing?.plugins ?? const []) : const [], [
      for (final e in parsed.plugins) (id: e.id, version: e.version, url: e.url),
    ]);
    final old = {for (final p in existing?.plugins ?? const <JsPlugin>[]) p.id: p};
    final plugins = <JsPlugin>[];
    for (final e in parsed.plugins) {
      if (plan.keep.contains(e.id)) {
        // same version: the saved script, with the listing's current name and note
        final o = old[e.id]!;
        plugins.add(JsPlugin(id: o.id, name: e.name, url: o.url, code: o.code, version: o.version, note: e.note, types: e.types));
        continue;
      }
      try {
        final code = e.vega
            ? await composeVegaPlugin(e.url, e.version, (u) => fetchText(u, timeout: const Duration(seconds: 20)))
            : await fetchText(e.url, timeout: const Duration(seconds: 20));
        if (code.length > _maxScript) continue;
        plugins.add(JsPlugin(id: e.id, name: e.name, url: e.url, code: code, version: e.version, note: e.note, types: e.types));
      } catch (_) {
        // a script that can't be downloaded now keeps its saved copy
        final o = old[e.id];
        if (o != null) plugins.add(o);
      }
    }
    if (plugins.isEmpty) throw const FormatException('None of the repository\'s scripts could be downloaded.');
    return PluginRepo(url: url, name: parsed.name.isEmpty ? uri.host : parsed.name, plugins: plugins);
  }

  /// Adds the repository at [input] (or fetches it again, which downloads every script anew).
  /// Returns what was installed. Throws a message fit to show.
  static Future<PluginRepo> add(String input) async {
    load();
    final url = normalizeRepoUrl(input);
    final repo = await _fetchRepo(url, existing: repos.value.where((r) => r.url == url).firstOrNull);
    final had = repos.value.any((r) => r.url == url);
    _save([
      for (final r in repos.value)
        if (r.url == url) repo else r,
      if (!had) repo,
    ]);
    return repo;
  }

  /// What the last automatic check did, for Settings.
  static final status = ValueNotifier<String?>(null);

  /// When Settings → Sources → Plugins → "Update automatically" is on and a day has passed: reads each repository
  /// and downloads only the plugins whose version changed. A repository that can't be reached keeps what it has.
  static Future<void> autoUpdateIfDue({bool force = false}) async {
    if (!force && !AppSettings.pluginAutoUpdate.value) return;
    load();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - AppSettings.pluginsChecked.value < const Duration(hours: 20).inMilliseconds) return;
    if (repos.value.isEmpty) return;
    AppSettings.pluginsChecked.set(now);
    final updated = <String>[];
    var failed = 0;
    final removed = <String>[];
    for (final r in [...repos.value]) {
      try {
        final next = await _fetchRepo(r.url, existing: r, onlyChanged: true);
        final before = {for (final p in r.plugins) p.id: p.code};
        updated.addAll([
          for (final p in next.plugins)
            if (before[p.id] != p.code) p.name,
        ]);
        _save([
          for (final x in repos.value)
            if (x.url == r.url) next else x,
        ]);
      } on RepoGone {
        // a repository file that was deleted: its plugins go with it (a repository that is only unreachable stays)
        removed.add(r.name);
        _save([
          for (final x in repos.value)
            if (x.url != r.url) x,
        ]);
      } catch (_) {
        failed++;
      }
    }
    status.value = [
      if (removed.isNotEmpty) 'Removed ${removed.join(', ')}: its repo.json is gone',
      if (updated.isNotEmpty)
        'Updated ${updated.length} plugin${updated.length == 1 ? '' : 's'}: ${updated.take(4).join(', ')}${updated.length > 4 ? '…' : ''}'
      else if (removed.isEmpty)
        'Plugins are up to date',
      if (failed > 0) 'could not reach $failed repositor${failed == 1 ? 'y' : 'ies'}',
    ].join(' · ');
  }

  static void remove(PluginRepo r) => _save([
    for (final x in repos.value)
      if (x.url != r.url) x,
  ]);
}

/// Stable, short id for a repository's link (not `hashCode`, which differs from run to run).
String _repoKey(String url) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(url)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

/// Every installed plugin as a source, in the order repositories were added.
List<FilmSource> get pluginSources {
  JsPlugins.load();
  return [
    for (final r in JsPlugins.repos.value)
      for (final p in r.plugins)
        FilmSource(
          id: 'js:${_repoKey(r.url)}:${p.id}',
          name: p.name,
          note: p.note.isEmpty ? 'Plugin from ${r.name}' : '${p.note} · plugin from ${r.name}',
          scraper: (q) => runJsPlugin(p.code, q, name: p.name),
          filmsOnly: !p.types.contains('tv'),
          showsOnly: !p.types.contains('movie'),
        ),
  ];
}

// ── running a plugin ──

/// What the script's global functions are. `getStreams(query)` is the plugin's own entry point.
const _prelude = r'''
var __cb = {}, __n = 0;
function http(url, opts) {
  return new Promise(function (resolve) {
    var id = ++__n;
    __cb[id] = resolve;
    sendMessage('http', JSON.stringify({ id: id, url: String(url), opts: opts || {} }));
  });
}
function __reply(id, r) { var f = __cb[id]; delete __cb[id]; if (f) f(r); }
var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function btoa(s) {
  s = String(s); var o = '';
  for (var i = 0; i < s.length; i += 3) {
    var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
    o += __b64[a >> 2] + __b64[((a & 3) << 4) | (b >> 4 || 0)] +
      (isNaN(b) ? '=' : __b64[((b & 15) << 2) | (c >> 6 || 0)]) + (isNaN(c) ? '=' : __b64[c & 63]);
  }
  return o;
}
function atob(s) {
  s = String(s).replace(/[^A-Za-z0-9+\/]/g, ''); var o = '';
  for (var i = 0; i < s.length; i += 4) {
    var a = __b64.indexOf(s[i]), b = __b64.indexOf(s[i + 1]), c = __b64.indexOf(s[i + 2]), d = __b64.indexOf(s[i + 3]);
    o += String.fromCharCode((a << 2) | (b >> 4));
    if (c >= 0) o += String.fromCharCode(((b & 15) << 4) | (c >> 2));
    if (d >= 0) o += String.fromCharCode(((c & 3) << 6) | d);
  }
  return o;
}
function __run(q) {
  try {
    Promise.resolve(getStreams(q)).then(
      function (r) { sendMessage('done', JSON.stringify({ ok: true, streams: r || [] })); },
      function (e) { sendMessage('done', JSON.stringify({ ok: false, error: String((e && e.message) || e) })); });
  } catch (e) { sendMessage('done', JSON.stringify({ ok: false, error: String((e && e.message) || e) })); }
}
// console.log / info / warn / error: kept in the plugin log (Settings shows it; a TV has no readable logcat)
console.log = console.info = console.warn = console.error = function () {
  var a = [];
  for (var i = 0; i < arguments.length; i++) a.push(String(arguments[i]));
  sendMessage('plog', JSON.stringify(a.join(' ')));
};
''';

JavascriptRuntime _newRuntime() {
  // a script that never ends is stopped by the engine (its native library has no memory limit)
  if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
    return QuickJsRuntime2(timeout: 20000);
  }
  return getJavascriptRuntime(xhr: false);
}

bool _deepBound = false;

/// Linux: loads the QuickJS library so that it uses its own functions before anyone else's.
///
/// mpv's bundled libmujs exports `js_malloc` too, with another meaning. Once mpv has loaded it, QuickJS's
/// calls to its own `js_malloc` land in mujs and the app crashes the first time a plugin runs. With
/// RTLD_DEEPBIND the library looks in itself first. The library is loaded under the same name flutter_js
/// asks for later, so it gets this already-loaded copy.
void _loadQuickJsDeepBound() {
  if (_deepBound || !Platform.isLinux) return;
  _deepBound = true;
  try {
    final dlopen = DynamicLibrary.process().lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32), Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
    final name = 'libquickjs_c_bridge_plugin.so'.toNativeUtf8();
    dlopen(name, 0x2 | 0x8); // RTLD_NOW | RTLD_DEEPBIND
    malloc.free(name);
  } catch (_) {}
}

String? _vegaRuntimeJs;

/// assets/plugins/vega_runtime.js: what a Vega provider runs on (see tool/vega_runtime).
Future<String> _vegaRuntime() async => _vegaRuntimeJs ??= await rootBundle.loadString('assets/plugins/vega_runtime.js');

String? _helpersJs;

/// assets/plugins/helpers.js: the title-matching functions every plugin can call.
Future<String> _helpers() async {
  if (_helpersJs != null) return _helpersJs!;
  try {
    return _helpersJs = await rootBundle.loadString('assets/plugins/helpers.js');
  } catch (_) {
    return '';
  }
}

/// Runs a plugin's `getStreams(query)` for [q] and returns what it found.
Future<List<FoundStream>> runJsPlugin(String code, FilmQuery q, {String name = ''}) async {
  final meta = await getTmdbMetadata(q.id, q.isTv);
  final query = {
    'tmdbId': q.tmdbId,
    'imdbId': meta.imdbId,
    'type': q.isTv ? 'tv' : 'movie',
    'isTv': q.isTv,
    'title': meta.title,
    'originalTitle': meta.originalTitle,
    'titles': meta.titles,
    'isAnime': meta.isAnime,
    'year': meta.year,
    'season': q.season,
    'episode': q.episode,
  };
  // QuickJS runs a script on whatever thread calls it, so a script stuck in a loop would freeze
  // the app until the engine's own 20-second limit stops it: it runs in an isolate of its own.
  _loadQuickJsDeepBound();
  final helpers = await _helpers();
  if (code.startsWith(vegaMarker)) code = '${await _vegaRuntime()}\n$code';
  final Map<String, Object?> res;
  try {
    if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
      res = await Isolate.run(() => _execute(code, query, helpers)).timeout(_runTimeout + const Duration(seconds: 5));
    } else {
      res = await _execute(code, query, helpers);
    }
  } on TimeoutException {
    PluginLog.add(name, ['stopped: no answer in ${(_runTimeout + const Duration(seconds: 5)).inSeconds} s']);
    rethrow;
  }
  final error = res['error'] as String?;
  final streams = parseStreams(res['streams']);
  PluginLog.add(name, [
    ...((res['log'] as List?) ?? const []).cast<String>(),
    if (error != null) 'ERROR: $error' else 'done: ${streams.length} stream${streams.length == 1 ? '' : 's'}',
  ]);
  if (error != null) throw StateError(error);
  return streams;
}

/// [_execute] for tests: runs [code] (after [helpers]) in a real engine and returns {streams, log, error?}.
@visibleForTesting
Future<Map<String, Object?>> executeScriptForTest(String code, Map<String, Object?> query, String helpers) {
  _loadQuickJsDeepBound();
  return _execute(code, query, helpers);
}

/// Runs the script in a fresh engine and returns the streams it answered with (as plain data).
/// Runs the script in a fresh engine. Returns {streams, log, error?}: what it answered, the lines it logged (kept even when it
/// fails or runs out of time), and the reason when it failed.
Future<Map<String, Object?>> _execute(String code, Map<String, Object?> query, String helpers) async {
  final logs = <String>[];
  final rt = _newRuntime();
  final done = Completer<Map<String, dynamic>>();
  var closed = false;
  // the engine runs a promise's next step only when asked: after every call into it, and often
  final pump = Timer.periodic(const Duration(milliseconds: 15), (_) {
    if (!closed) rt.executePendingJob();
  });
  try {
    rt.onMessage('plog', (a) {
      if (a is String && logs.length < 300) logs.add(a.length > 400 ? '${a.substring(0, 400)}…' : a);
      return null;
    });
    rt.onMessage('done', (a) {
      if (!done.isCompleted) done.complete(a is Map ? Map<String, dynamic>.from(a) : {'ok': false, 'error': 'bad answer'});
      return null;
    });
    rt.onMessage('http', (a) {
      final id = a is Map ? a['id'] : null;
      if (id is! int) return null;
      // (answered later, never inside the call from the script: the engine can't be re-entered)
      unawaited(() async {
        Map<String, Object?> res;
        try {
          res = await _request('${a['url']}', a['opts'] is Map ? Map<String, dynamic>.from(a['opts'] as Map) : const {});
        } catch (e) {
          res = {'status': 0, 'error': '$e', 'text': '', 'headers': <String, String>{}, 'url': '${a['url']}'};
        }
        if (closed) return;
        // (the reply is an object literal: JSON is valid JavaScript)
        rt.evaluate('__reply($id, ${jsonEncode(res)})');
        rt.executePendingJob();
      }());
      return null;
    });
    final pre = rt.evaluate(_prelude);
    if (pre.isError) throw StateError('engine: ${pre.stringResult}');
    if (helpers.isNotEmpty) {
      final h = rt.evaluate(helpers, sourceUrl: 'helpers.js');
      if (h.isError) throw StateError('helpers: ${h.stringResult}');
    }
    final loaded = rt.evaluate(code, sourceUrl: 'plugin.js');
    if (loaded.isError) throw StateError('script: ${loaded.stringResult}');
    final started = rt.evaluate(
      'typeof getStreams === "function" ? __run(${jsonEncode(query)}) : sendMessage("done", JSON.stringify({ok:false,error:"no getStreams function"}))',
    );
    if (started.isError) throw StateError('script: ${started.stringResult}');
    rt.executePendingJob();
    final r = await done.future.timeout(_runTimeout);
    if (r['ok'] != true) throw StateError('${r['error']}');
    return {'streams': r['streams'] is List ? r['streams'] as List : const [], 'log': logs};
  } catch (e) {
    return {'streams': const [], 'log': logs, 'error': e.toString().split('\n').first};
  } finally {
    closed = true;
    pump.cancel();
    try {
      rt.dispose();
    } catch (_) {}
  }
}

/// A plugin's answer as streams: `[{url, type?, quality?, server?, label?, audio?, headers?}]`.
/// Anything that isn't an http(s) link is left out.
@visibleForTesting
List<FoundStream> parseStreams(Object? v) {
  if (v is! List) return const [];
  final out = <FoundStream>[];
  for (final s in v) {
    if (s is! Map) continue;
    final url = s['url'];
    if (url is! String || !(url.startsWith('http://') || url.startsWith('https://'))) continue;
    final h = s['headers'];
    out.add(
      FoundStream(
        url: url,
        type: s['type'] is String ? s['type'] as String : null,
        quality: s['quality'] == null ? 'Auto' : '${s['quality']}',
        server: s['server'] == null ? 'Server' : '${s['server']}',
        label: s['label'] is String ? s['label'] as String : null,
        audio: audioOf(s['audio']),
        headers: h is Map ? {for (final e in h.entries) '${e.key}': '${e.value}'} : const {},
      ),
    );
  }
  return out;
}

// ── the script's network: web only, never this device's own network ──

/// Whether [a] is an address on this device or its local network, which a script may not reach
/// (TorrServer, routers, other apps).
@visibleForTesting
bool isPrivateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  if (b.length == 16) {
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7
    // ::ffff:a.b.c.d
    if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
      return isPrivateAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
    }
  }
  return false;
}

Future<void> _checkHost(Uri u) async {
  if (u.scheme != 'http' && u.scheme != 'https') throw StateError('only http and https links');
  final host = u.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.local') || host.endsWith('.localhost') || host.endsWith('.internal')) {
    throw StateError('this device\'s network is off limits');
  }
  final literal = InternetAddress.tryParse(host);
  final addrs = literal != null ? [literal] : await InternetAddress.lookup(host);
  if (addrs.isEmpty || addrs.any(isPrivateAddress)) throw StateError('this device\'s network is off limits');
}

Future<Map<String, Object?>> _request(String url, Map<String, dynamic> opts) async {
  var u = Uri.parse(url);
  final method = '${opts['method'] ?? 'GET'}'.toUpperCase();
  final headers = <String, String>{
    if (opts['headers'] is Map)
      for (final e in (opts['headers'] as Map).entries) '${e.key}': '${e.value}',
  };
  headers.putIfAbsent('User-Agent', () => sdkUA);
  final body = opts['body'] == null ? null : (opts['body'] is String ? opts['body'] as String : jsonEncode(opts['body']));
  final timeout = Duration(milliseconds: ((opts['timeout'] as num?)?.toInt() ?? 15000).clamp(1000, 20000));
  http.Response? res;
  // redirects are followed here, so each one is checked
  for (var hop = 0; hop < 6; hop++) {
    await _checkHost(u);
    final rq = http.Request(hop == 0 ? method : 'GET', u)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (hop == 0 && body != null) rq.body = body;
    final streamed = await netClient.send(rq).timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in streamed.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) throw StateError('answer too large');
    }
    res = http.Response.bytes(bytes, streamed.statusCode, headers: streamed.headers, request: rq);
    final loc = res.headers['location'];
    if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
      u = u.resolve(loc);
      continue;
    }
    break;
  }
  final r = res!;
  return {
    'status': r.statusCode,
    'url': '$u',
    'headers': {for (final e in r.headers.entries) e.key.toLowerCase(): e.value},
    'text': utf8.decode(r.bodyBytes, allowMalformed: true),
  };
}
