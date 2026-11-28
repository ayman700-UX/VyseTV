// Your Newznab indexers, asked from this device: what each can search by (its capabilities),
// searches page by page, and what each last said (a pause after its limit, the last problem,
// the API hits and grabs it says are left), kept on this device for Settings > Usenet.
//
// Requests carry your API key in their address, so no address, key or server text is ever
// logged, kept or shown: what is kept is keyed by a hash of the endpoint and key, and holds
// categories only. XML with a DOCTYPE or entities is refused, and answers stop at 4 MiB.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../net.dart';
import 'usenet_names.dart';
import 'usenet_play.dart';
import 'usenet_release.dart';
import 'usenet_sources.dart';

/// Why an indexer's last request failed, as its row says it: the key was refused, the indexer
/// couldn't be reached, or it answered something unexpected.
enum IndexerProblem { auth, unreachable, response }

/// What an indexer's row shows: a pause (its limit was reached), the last problem, and the API
/// hits and grabs it said were left (counts older than a day are not shown: they reset daily).
@immutable
class UsenetIndexerStatus {
  const UsenetIndexerStatus({this.pausedUntil, this.problem, this.apiHitsLeft, this.grabsLeft, this.leftAt});

  /// When its pause ends (in the past once it ended).
  final DateTime? pausedUntil;

  /// Why its last request failed; null after a success.
  final IndexerProblem? problem;

  /// The API hits and grabs it said are left today.
  final int? apiHitsLeft;
  final int? grabsLeft;

  /// When it said so.
  final DateTime? leftAt;
}

/// What an indexer can search by: the parameters of its film and TV searches, whether it has a
/// plain search, and how many results a page may hold.
@immutable
class NewznabCaps {
  const NewznabCaps({this.movieParams = const {'imdbid'}, this.tvParams = const {'imdbid', 'season', 'ep'}, this.searchAvailable = true, this.limit = 100});

  /// The film search's parameters (`q`, `imdbid`, `tmdbid`, `year`), lower case.
  final Set<String> movieParams;

  /// The TV search's parameters (`q`, `imdbid`, `tvdbid`, `season`, `ep`), lower case.
  final Set<String> tvParams;

  /// A plain search (`t=search`) is there, for title searches the film or TV search can't make.
  final bool searchAvailable;

  /// 1 to 100.
  final int limit;

  Map<String, Object?> toJson() => {'movie': movieParams.toList(), 'tv': tvParams.toList(), 'search': searchAvailable, 'limit': limit};

  static NewznabCaps fromJson(Map j) => NewznabCaps(
    movieParams: j['movie'] is List ? {for (final p in j['movie'] as List) '$p'} : const {'imdbid'},
    tvParams: j['tv'] is List ? {for (final p in j['tv'] as List) '$p'} : const {'imdbid', 'season', 'ep'},
    searchAvailable: j['search'] as bool? ?? true,
    limit: ((j['limit'] as num?)?.toInt() ?? 100).clamp(1, 100),
  );

  /// The capabilities a `t=caps` answer gives: a search type it lacks, or says isn't available,
  /// supports nothing.
  static NewznabCaps parse(String xml) {
    final root = Newznab._document(xml);
    if (root.localName != 'caps') throw const NewznabFailure(NewznabFailureKind.invalid);
    Set<String> params(String tag) {
      final e = root.findAllElements(tag).firstOrNull;
      if (e == null || e.getAttribute('available') != 'yes') return const {};
      return {
        for (final p in (e.getAttribute('supportedParams') ?? '').split(','))
          if (p.trim().isNotEmpty) p.trim().toLowerCase(),
      };
    }

    final max = int.tryParse((root.findAllElements('limits').firstOrNull?.getAttribute('max') ?? '').trim());
    return NewznabCaps(
      movieParams: params('movie-search'),
      tvParams: params('tv-search'),
      searchAvailable: root.findAllElements('search').firstOrNull?.getAttribute('available') == 'yes',
      limit: (max ?? 100).clamp(1, 100),
    );
  }
}

/// One page of a search: its releases, how many items it had (usable or not), and the total
/// the indexer reports, when it does.
@immutable
class NewznabPage {
  const NewznabPage(this.releases, this.items, this.total);
  final List<UsenetRelease> releases;
  final int items;
  final int? total;
}

/// What went wrong with an indexer request: a pause (its limit), the key refused, a quota
/// spent, a search it doesn't take, an API error, an HTTP error status, an answer that isn't
/// what was asked for or is too large, or no connection.
enum NewznabFailureKind { cooldown, auth, quota, unsupported, api, http, invalid, tooLarge, unreachable }

/// Why an indexer request failed, in words that never hold anything the server said (it can
/// echo the key).
@immutable
class NewznabFailure implements Exception {
  const NewznabFailure(this.kind, {this.status = 0, this.blockedUntil = 0});
  final NewznabFailureKind kind;

  /// The HTTP status, for [NewznabFailureKind.http].
  final int status;

  /// When a pause ends (ms since 1970), for [NewznabFailureKind.cooldown].
  final int blockedUntil;

  @override
  String toString() => switch (kind) {
    NewznabFailureKind.cooldown => 'Indexer limit reached',
    NewznabFailureKind.auth => 'Indexer authentication failed',
    NewznabFailureKind.quota => 'Indexer rate limit reached',
    NewznabFailureKind.unsupported => 'Indexer does not support this search',
    NewznabFailureKind.api => 'Indexer returned an API error',
    NewznabFailureKind.http => 'Indexer returned HTTP $status',
    NewznabFailureKind.invalid => 'Invalid indexer response',
    NewznabFailureKind.tooLarge => 'Indexer response is too large',
    NewznabFailureKind.unreachable => 'Could not reach indexer',
  };
}

class _State {
  _State({this.caps, this.capsAt = 0, this.blockedUntil = 0, this.problem, this.apiHits, this.grabs, this.leftAt = 0, this.touchedAt = 0});
  NewznabCaps? caps;
  int capsAt;
  int blockedUntil;
  IndexerProblem? problem;
  int? apiHits;
  int? grabs;
  int leftAt;
  int touchedAt;

  Map<String, Object?> toJson() => {
    if (caps != null) 'caps': caps!.toJson(),
    if (capsAt > 0) 'capsAt': capsAt,
    if (blockedUntil > 0) 'blockedUntil': blockedUntil,
    if (problem != null) 'problem': problem!.name,
    'apiHits': ?apiHits,
    'grabs': ?grabs,
    if (leftAt > 0) 'leftAt': leftAt,
    'touchedAt': touchedAt,
  };

  static _State fromJson(Map j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return _State(
      caps: j['caps'] is Map ? NewznabCaps.fromJson(j['caps'] as Map) : null,
      capsAt: n('capsAt'),
      blockedUntil: n('blockedUntil'),
      problem: IndexerProblem.values.where((p) => p.name == j['problem']).firstOrNull,
      apiHits: (j['apiHits'] as num?)?.toInt(),
      grabs: (j['grabs'] as num?)?.toInt(),
      leftAt: n('leftAt'),
      touchedAt: n('touchedAt'),
    );
  }
}

class _Response {
  _Response(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final String body;
}

class _TooLarge implements Exception {}

class _SeasonEntry {
  _SeasonEntry(this.releases, this.at);
  final Future<List<UsenetRelease>> releases;
  final int at;
}

/// Your Newznab indexers asked from this device: capabilities, searches, what each last said,
/// and Settings' Test indexer.
class Newznab {
  Newznab._();
  static final instance = Newznab._();

  /// Every HTTP request actually sent to an indexer, with its kind (`movie` or `show` for
  /// search pages, null for capabilities and key checks), how it went (`answered`, `failed`,
  /// `limited`) and how long it took (statistics listen; usenet_stats.dart).
  static void Function(String indexerId, String? kind, String outcome, int ms)? onRequest;

  static const _storeKey = 'device.usenet.indexers';
  static const maxBody = 4 * 1024 * 1024;
  static const capsFor = Duration(days: 7);
  static const _keepState = Duration(days: 30);
  static const _maxStates = 100;
  static const _countsFresh = Duration(hours: 24);
  static const _seasonFor = Duration(hours: 2);
  static const _maxSeasons = 50;

  /// Connect 10 s, read 20 s, the whole request 25 s.
  @visibleForTesting
  static Duration connectTimeout = const Duration(seconds: 10);
  @visibleForTesting
  static Duration readTimeout = const Duration(seconds: 20);

  /// The whole request, answer read.
  @visibleForTesting
  static Duration callTimeout = const Duration(seconds: 25);

  final _changed = ValueNotifier<int>(0);

  /// Bumped on every change of what indexers' rows show.
  ValueListenable<int> get changed => _changed;

  Map<String, _State>? _states;
  Future<void>? _loading;
  Future<void> _saving = Future.value();
  Timer? _pauseEnds;
  HttpClient? _http;
  final _seasons = <String, _SeasonEntry>{};

  // ── where an indexer is ──

  /// The endpoint as a string, as state keys and request addresses take it: the API URL as you
  /// wrote it when there is no API path, else the URL with the path added.
  static String endpointOf(UsenetIndexer i) => i.apiPath.trim().isEmpty ? i.apiUrl.trim() : (i.endpoint?.toString() ?? i.apiUrl.trim());

  /// What an indexer's state is kept under: a hash of its endpoint and key (an edited URL or
  /// key starts afresh; no secret is kept).
  static String stateKey(UsenetIndexer i) => sha256.convert(utf8.encode('${endpointOf(i)}\n${i.apiKey}')).toString();

  static Uri _set(Uri u, Map<String, String> values) {
    final params = <String, List<String>>{
      for (final e in u.queryParametersAll.entries)
        if (!values.containsKey(e.key)) e.key: e.value,
    };
    for (final e in values.entries) {
      params[e.key] = [e.value];
    }
    return u.replace(queryParameters: params);
  }

  /// The endpoint with `apikey`, `t` = [action] and `o=xml` set (its own parameters kept).
  static Uri? baseUrl(UsenetIndexer i, String action) {
    final e = i.endpoint;
    if (e == null) return null;
    return _set(e, {'apikey': i.apiKey, 't': action, 'o': 'xml'});
  }

  /// The search address for [r] with [caps], or null when no search can be made: by an id the
  /// indexer takes (an episode's only when it narrows to season and episode), else by title.
  /// [wholeSeason]: a season's by id, without the episode.
  static Uri? searchUrl(UsenetIndexer i, UsenetSearchRequest r, NewznabCaps caps, {int offset = 0, bool wholeSeason = false}) {
    final params = r.series ? caps.tvParams : caps.movieParams;
    var t = r.series ? 'tvsearch' : 'movie';
    String? idName, idValue;
    final imdb = r.imdbId, tvdb = r.tvdbId, tmdb = r.tmdbId;
    if (r.series && !(params.contains('season') && params.contains('ep'))) {
      // an indexer that can't narrow an id search to an episode is never asked for a whole series
    } else if (imdb != null && params.contains('imdbid')) {
      idName = 'imdbid';
      idValue = imdb.startsWith('tt') ? imdb.substring(2) : imdb;
    } else if (r.series && tvdb != null && params.contains('tvdbid')) {
      idName = 'tvdbid';
      idValue = tvdb;
    } else if (tmdb != null && params.contains('tmdbid')) {
      idName = 'tmdbid';
      idValue = tmdb;
    }
    if (wholeSeason && (!r.series || idName == null)) return null;
    final set = <String, String>{};
    if (idName != null) {
      set[idName] = idValue!;
    } else {
      final q = r.title == null ? '' : queryTitle(r.title!);
      if (q.isEmpty) return null;
      if (!params.contains('q')) {
        if (!caps.searchAvailable) return null;
        t = 'search';
      }
      final s = r.season, e = r.episode;
      set['q'] = r.series && s != null && e != null ? '$q S${'$s'.padLeft(2, '0')}E${'$e'.padLeft(2, '0')}' : q;
      if (!r.series && r.year != null && params.contains('year')) set['year'] = '${r.year}';
    }
    if (r.series) {
      if (r.season == null || r.episode == null) return null;
      if (params.contains('season')) set['season'] = '${r.season}';
      if (params.contains('ep') && !wholeSeason) set['ep'] = '${r.episode}';
    }
    set['cat'] = r.series ? '5000' : '2000';
    set['limit'] = '${caps.limit.clamp(1, 100)}';
    set['offset'] = '$offset';
    final base = baseUrl(i, t);
    return base == null ? null : _set(base, set);
  }

  /// Whether [url] searches by an id.
  static bool isIdSearch(Uri url) => const ['imdbid', 'tvdbid', 'tmdbid'].any(url.queryParameters.containsKey);

  /// Whether [e] says the indexer refused the search's parameters (not the key, not a limit,
  /// not a failure of its own): Newznab 200–203, or HTTP 4xx but 401, 403, 408 and 429.
  static bool isSearchRejection(Object e) {
    if (e is! NewznabFailure) return false;
    if (e.kind == NewznabFailureKind.unsupported) return true;
    return e.kind == NewznabFailureKind.http && e.status >= 400 && e.status <= 499 && !const {401, 403, 408, 429}.contains(e.status);
  }

  // ── XML ──

  static final _unsafe = RegExp(r'<!(?:DOCTYPE|ENTITY)', caseSensitive: false);

  /// The root of an indexer's XML, after refusing a DOCTYPE or entities; a Newznab error
  /// document throws its kind.
  static XmlElement _document(String xml) {
    if (_unsafe.hasMatch(xml)) throw const NewznabFailure(NewznabFailureKind.invalid);
    final XmlElement root;
    try {
      root = XmlDocument.parse(xml).rootElement;
    } catch (_) {
      throw const NewznabFailure(NewznabFailureKind.invalid);
    }
    if (root.localName == 'error') {
      final code = root.getAttribute('code')?.trim();
      if (const {'429', '500', '501'}.contains(code)) throw const NewznabFailure(NewznabFailureKind.quota);
      if (const {'100', '101', '102'}.contains(code)) throw const NewznabFailure(NewznabFailureKind.auth);
      if (const {'200', '201', '202', '203'}.contains(code)) throw const NewznabFailure(NewznabFailureKind.unsupported);
      throw const NewznabFailure(NewznabFailureKind.api);
    }
    return root;
  }

  /// A quota or key error an error status carries in its body, or null.
  static NewznabFailure? _knownError(String body) {
    try {
      _document(body);
    } on NewznabFailure catch (e) {
      if (e.kind == NewznabFailureKind.quota || e.kind == NewznabFailureKind.auth) return e;
    } catch (_) {}
    return null;
  }

  /// A key check's search passes on any results, or on a refusal of its parameters only (the
  /// key was taken); anything else fails (a login page beside public capabilities).
  static void _keyCheck(String xml) {
    final XmlElement root;
    try {
      root = _document(xml);
    } on NewznabFailure catch (e) {
      if (e.kind == NewznabFailureKind.unsupported) return;
      rethrow;
    }
    if (root.localName != 'rss') throw const NewznabFailure(NewznabFailureKind.invalid);
  }

  static final _rfc1123 = RegExp(
    r'^(?:[A-Za-z]{3,9},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC?|Z|[A-Za-z]{3}|[+-]\d{2}:?\d{2})?$',
  );
  static const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  static const _zones = {'EST': -5, 'EDT': -4, 'CST': -6, 'CDT': -5, 'MST': -7, 'MDT': -6, 'PST': -8, 'PDT': -7};

  /// An RFC 1123 date (`Fri, 09 Oct 2026 12:00:00 +0000`), in ms since 1970, or null.
  static int? parseRfc1123(String s) {
    final m = _rfc1123.firstMatch(s.trim());
    if (m == null) return null;
    final month = _months.indexOf(m[2]!.toLowerCase());
    if (month < 0) return null;
    final day = int.parse(m[1]!), year = int.parse(m[3]!), hour = int.parse(m[4]!), minute = int.parse(m[5]!);
    final second = int.parse(m[6] ?? '0');
    if (day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
    var offset = 0;
    final zone = m[7];
    if (zone != null && zone.length >= 3 && (zone.startsWith('+') || zone.startsWith('-'))) {
      final digits = zone.substring(1).replaceAll(':', '');
      offset = (int.parse(digits.substring(0, 2)) * 60 + int.parse(digits.substring(2))) * (zone.startsWith('-') ? -1 : 1);
    } else if (zone != null && _zones.containsKey(zone.toUpperCase())) {
      offset = _zones[zone.toUpperCase()]! * 60;
    } else if (zone != null && !const {'GMT', 'UT', 'UTC', 'Z'}.contains(zone.toUpperCase())) {
      return null;
    }
    return DateTime.utc(year, month + 1, day, hour, minute, second).millisecondsSinceEpoch - offset * 60000;
  }

  static final _isoInstant = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false);

  /// When an item was posted: an RFC 1123 date, an ISO instant, or seconds (or milliseconds)
  /// since 1970; 0 when none of them.
  static int parsePosted(String? s) {
    final v = s?.trim() ?? '';
    if (v.isEmpty) return 0;
    final rfc = parseRfc1123(v);
    if (rfc != null) return rfc;
    if (_isoInstant.hasMatch(v)) {
      final d = DateTime.tryParse(v);
      if (d != null) return d.millisecondsSinceEpoch;
    }
    final n = int.tryParse(v);
    if (n != null && n > 0 && n < 9223372036854775 /* Long.MAX / 1000 */ ) return n < 100000000000 ? n * 1000 : n;
    return 0;
  }

  static final _passworded = {'1', '2', 'true', 'yes'};

  /// The elements under [e] of local name [local], in any namespace (`newznab:attr`,
  /// `torznab:attr`, `attr`).
  static Iterable<XmlElement> _named(XmlElement e, String local) => e.descendants.whereType<XmlElement>().where((x) => x.name.local == local);

  /// The releases of a search answer, with [i]'s id and name.
  static NewznabPage parseReleases(String xml, UsenetIndexer i) {
    final root = _document(xml);
    if (root.localName != 'rss') throw const NewznabFailure(NewznabFailureKind.invalid);
    final endpoint = Uri.tryParse(endpointOf(i));
    final items = root.findAllElements('item').toList();
    final releases = <UsenetRelease>[];
    for (final item in items) {
      String text(String tag) => item.findAllElements(tag).firstOrNull?.innerText.trim() ?? '';
      final attrs = <String, String>{
        for (final a in _named(item, 'attr'))
          if (a.getAttribute('name') != null) a.getAttribute('name')!.toLowerCase(): a.getAttribute('value') ?? '',
      };
      final enclosures = item.findAllElements('enclosure').toList();
      final nzb = enclosures.where((e) => (e.getAttribute('type') ?? '').toLowerCase().contains('nzb')).firstOrNull;
      final href = nzb != null && (nzb.getAttribute('url') ?? '').trim().isNotEmpty
          ? nzb.getAttribute('url')!.trim()
          : (enclosures.isEmpty ? text('link') : '');
      if (href.isEmpty) continue;
      Uri? url;
      try {
        url = endpoint == null ? Uri.parse(href) : endpoint.resolve(href);
      } catch (_) {
        url = null;
      }
      if (url == null || (url.scheme != 'http' && url.scheme != 'https') || url.host.isEmpty) continue;
      final title = text('title');
      if (title.isEmpty) continue;
      var posted = parsePosted(attrs['usenetdate']);
      if (posted == 0) posted = parsePosted(text('pubDate'));
      var size = int.tryParse((attrs['size'] ?? '').trim()) ?? int.tryParse((nzb?.getAttribute('length') ?? '').trim()) ?? 0;
      if (size < 0) size = 0;
      releases.add(
        UsenetRelease(
          title: title,
          nzbUrl: url.toString(),
          indexerId: i.id,
          indexerName: i.name,
          size: size,
          publishedAt: posted,
          passworded: _passworded.contains((attrs['password'] ?? '').trim().toLowerCase()),
        ),
      );
    }
    final total = int.tryParse((_named(root, 'response').firstOrNull?.getAttribute('total') ?? '').trim());
    return NewznabPage(releases, items.length, total);
  }

  // ── what each indexer last said ──

  /// Reads what was kept of your indexers (once).
  Future<void> load() => _loading ??= () async {
    final states = <String, _State>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_storeKey);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          for (final e in j.entries) {
            if (e.value is Map) states['${e.key}'] = _State.fromJson(e.value as Map);
          }
        }
      }
    } catch (_) {}
    _states = {...states, ...?_states};
    _schedulePauseEnd();
    _changed.value++;
  }();

  Map<String, _State> get _map => _states ??= <String, _State>{};

  _State _touch(String key) {
    final now = UsenetClock.nowMs();
    final s = _map.putIfAbsent(key, _State.new);
    s.touchedAt = now;
    return s;
  }

  void _save() {
    final now = UsenetClock.nowMs();
    _map.removeWhere((_, s) => now - s.touchedAt > _keepState.inMilliseconds);
    if (_map.length > _maxStates) {
      final byAge = _map.entries.toList()..sort((a, b) => a.value.touchedAt.compareTo(b.value.touchedAt));
      for (final e in byAge.take(_map.length - _maxStates)) {
        _map.remove(e.key);
      }
    }
    final text = jsonEncode({for (final e in _map.entries) e.key: e.value.toJson()});
    _saving = _saving.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).setString(_storeKey, text);
      } catch (_) {}
    });
    _schedulePauseEnd();
    _changed.value++;
  }

  /// Rows say "Paused until…" until the earliest pause ends; then they change.
  void _schedulePauseEnd() {
    _pauseEnds?.cancel();
    final now = UsenetClock.nowMs();
    final ends = [for (final s in _map.values) if (s.blockedUntil > now) s.blockedUntil];
    if (ends.isEmpty) return;
    _pauseEnds = Timer(Duration(milliseconds: ends.reduce(min) - now + 50), () {
      _changed.value++;
      _schedulePauseEnd();
    });
  }

  /// Pauses the indexer of [key] for [d] (a pause only ever grows); its end.
  int _pause(String key, Duration d) {
    final s = _touch(key);
    s.blockedUntil = max(s.blockedUntil, UsenetClock.nowMs() + d.inMilliseconds);
    _save();
    return s.blockedUntil;
  }

  void _setProblem(String key, IndexerProblem? p) {
    final s = _map[key];
    if (s == null && p == null) return;
    if (s != null && s.problem == p) return;
    _touch(key).problem = p;
    _save();
  }

  /// What [i]'s row shows.
  UsenetIndexerStatus status(UsenetIndexer i) {
    if (_loading == null) unawaited(load());
    final s = _map[stateKey(i)];
    if (s == null) return const UsenetIndexerStatus();
    final fresh = s.leftAt > 0 && UsenetClock.nowMs() - s.leftAt < _countsFresh.inMilliseconds;
    return UsenetIndexerStatus(
      pausedUntil: s.blockedUntil > 0 ? DateTime.fromMillisecondsSinceEpoch(s.blockedUntil) : null,
      problem: s.problem,
      apiHitsLeft: fresh ? s.apiHits : null,
      grabsLeft: fresh ? s.grabs : null,
      leftAt: fresh ? DateTime.fromMillisecondsSinceEpoch(s.leftAt) : null,
    );
  }

  /// "14:05".
  static String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// [i]'s row line: its pause, else its last problem, else the counts it said are left; null
  /// when there is nothing to say.
  String? statusLine(UsenetIndexer i) {
    final s = status(i);
    final paused = s.pausedUntil;
    if (paused != null && paused.isAfter(UsenetClock.now())) return 'Paused until ${clock(paused)}: limit reached';
    switch (s.problem) {
      case IndexerProblem.auth:
        return 'Last request failed: API key rejected';
      case IndexerProblem.unreachable:
        return 'Last request failed: could not reach the indexer';
      case IndexerProblem.response:
        return 'Last request failed: unexpected response';
      case null:
        break;
    }
    final hits = s.apiHitsLeft, grabs = s.grabsLeft, at = s.leftAt;
    if ((hits == null && grabs == null) || at == null) return null;
    final parts = [
      if (hits != null) '$hits API ${hits == 1 ? 'hit' : 'hits'} left',
      if (grabs != null) '$grabs ${grabs == 1 ? 'grab' : 'grabs'} left',
    ];
    return '${parts.join(', ')} (as of ${clock(at)})';
  }

  /// Forgets every indexer's state, capabilities and the season searches held (Danger Zone).
  Future<void> clear() async {
    _states = <String, _State>{};
    _loading = Future.value();
    _seasons.clear();
    _pauseEnds?.cancel();
    _changed.value++;
    _saving = _saving.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).remove(_storeKey);
      } catch (_) {}
    });
    await _saving;
  }

  /// Waits for what was kept to be written (tests).
  @visibleForTesting
  Future<void> flushed() => _saving;

  /// Drops what is held in memory, as a restart does (tests).
  @visibleForTesting
  void debugForget() {
    _states = null;
    _loading = null;
    _seasons.clear();
    _pauseEnds?.cancel();
  }

  // ── requests ──

  HttpClient _client() => _http ??= resilientHttpClient()
    ..connectionTimeout = connectTimeout
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = null;

  Future<_Response> _send(Uri url) async {
    final req = await _client().getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, UsenetPlay.searchUserAgent);
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final res = await req.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(readTimeout)) {
      if (bytes.length + chunk.length > maxBody) throw _TooLarge();
      bytes.add(chunk);
    }
    return _Response(res.statusCode, res.headers, utf8.decode(bytes.takeBytes(), allowMalformed: true));
  }

  void _count(UsenetIndexer i, String? kind, String outcome, int ms) {
    try {
      onRequest?.call(i.id, kind, outcome, ms < 0 ? 0 : ms);
    } catch (_) {}
  }

  /// `Retry-After` as a wait: seconds, or an HTTP date; null when absent or past.
  static Duration? retryAfter(String? value, {int? now}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    final n = int.tryParse(v);
    if (n != null) return n > 0 ? Duration(seconds: n) : null;
    final at = parseRfc1123(v);
    if (at == null) return null;
    final d = at - (now ?? UsenetClock.nowMs());
    return d > 0 ? Duration(milliseconds: d) : null;
  }

  static int? _remaining(HttpHeaders h, List<String> names) {
    for (final name in names) {
      final v = h.value(name);
      if (v == null) continue;
      final n = int.tryParse(v.trim());
      if (n != null) return n < 0 ? 0 : n;
    }
    return null;
  }

  /// One request to [i], read by [parse]. Refused here while [i] is paused (unless [live]: a
  /// test from Settings); pauses it when its limit is reached; keeps its problem and counts.
  Future<T> _request<T>(UsenetIndexer i, Uri url, FutureOr<T> Function(String body) parse, {String? kind, bool live = false}) async {
    await load();
    final key = stateKey(i);
    final blocked = _map[key]?.blockedUntil ?? 0;
    if (!live && blocked > UsenetClock.nowMs()) throw NewznabFailure(NewznabFailureKind.cooldown, blockedUntil: blocked);
    final watch = Stopwatch()..start();
    _Response res;
    try {
      res = await _send(url).timeout(callTimeout);
    } on _TooLarge {
      _count(i, kind, 'failed', watch.elapsedMilliseconds);
      _setProblem(key, IndexerProblem.response);
      throw const NewznabFailure(NewznabFailureKind.tooLarge);
    } catch (_) {
      _count(i, kind, 'failed', watch.elapsedMilliseconds);
      _setProblem(key, IndexerProblem.unreachable);
      throw const NewznabFailure(NewznabFailureKind.unreachable);
    }
    final ms = watch.elapsedMilliseconds;
    final wait = retryAfter(res.headers.value('retry-after'));
    if (res.status == 429) {
      _count(i, kind, 'limited', ms);
      final capped = wait == null ? const Duration(seconds: 60) : (wait > const Duration(minutes: 15) ? const Duration(minutes: 15) : wait);
      throw NewznabFailure(NewznabFailureKind.cooldown, blockedUntil: _pause(key, capped));
    }
    try {
      if (res.status < 200 || res.status > 299) {
        final known = _knownError(res.body);
        if (known != null) throw known;
        if (res.status == 401 || res.status == 403) throw const NewznabFailure(NewznabFailureKind.auth);
        throw NewznabFailure(NewznabFailureKind.http, status: res.status);
      }
      final T value;
      try {
        value = await parse(res.body);
      } on NewznabFailure {
        rethrow;
      } catch (_) {
        throw const NewznabFailure(NewznabFailureKind.invalid);
      }
      final hits = _remaining(res.headers, const ['X-RateLimit-Daily-Remaining', 'x-api-remaining']);
      final grabs = _remaining(res.headers, const ['X-DNZBLimit-Daily-Remaining', 'x-grab-remaining']);
      if (hits == 0 || grabs == 0) _pause(key, const Duration(minutes: 15));
      if (hits != null || grabs != null) {
        final s = _touch(key);
        s.problem = null;
        s.apiHits = hits;
        s.grabs = grabs;
        s.leftAt = UsenetClock.nowMs();
        _save();
      } else {
        _setProblem(key, null);
      }
      _count(i, kind, 'answered', ms);
      return value;
    } on NewznabFailure catch (e) {
      switch (e.kind) {
        case NewznabFailureKind.quota:
          _count(i, kind, 'limited', ms);
          throw NewznabFailure(NewznabFailureKind.cooldown, blockedUntil: _pause(key, wait ?? const Duration(minutes: 30)));
        case NewznabFailureKind.auth:
          _count(i, kind, 'failed', ms);
          _setProblem(key, IndexerProblem.auth);
          rethrow;
        default:
          _count(i, kind, 'failed', ms);
          _setProblem(key, IndexerProblem.response);
          rethrow;
      }
    }
  }

  /// What [i] can search by: kept for 7 days (and used beyond when a fresh copy can't be had),
  /// asked again when [live].
  Future<NewznabCaps> capabilities(UsenetIndexer i, {bool live = false}) async {
    await load();
    final key = stateKey(i);
    final kept = _map[key];
    final cached = kept?.caps;
    if (!live && cached != null && UsenetClock.nowMs() - kept!.capsAt < capsFor.inMilliseconds) return cached;
    final url = baseUrl(i, 'caps');
    if (url == null) throw const NewznabFailure(NewznabFailureKind.invalid);
    try {
      final caps = await _request(i, url, NewznabCaps.parse, live: live);
      final s = _touch(key);
      s.caps = caps;
      s.capsAt = UsenetClock.nowMs();
      _save();
      return caps;
    } catch (_) {
      if (!live && cached != null) return cached;
      rethrow;
    }
  }

  static Future<NewznabPage> _pageOf(String body, UsenetIndexer i) =>
      body.length > 65536 ? Isolate.run(() => parseReleases(body, i)) : Future.value(parseReleases(body, i));

  /// The releases of a search, page by page from [first], up to [results] (0: every page):
  /// it stops at the reported total, at a short page without one, and at a page that repeats
  /// an earlier one. A failed later page keeps what was read.
  Future<List<UsenetRelease>> pages(
    UsenetIndexer i,
    Uri first,
    UsenetSearchRequest r,
    NewznabCaps caps,
    int results, {
    bool wholeSeason = false,
    String? kind,
    bool Function()? cancelled,
  }) async {
    final limit = caps.limit.clamp(1, 100);
    var offset = 0;
    final releases = <UsenetRelease>[];
    final seenUrls = <String>{};
    final seenPages = <String>{};
    while (results == 0 || offset < results) {
      if (cancelled?.call() ?? false) break;
      final pageSize = results == 0 ? limit : min(limit, results - offset);
      final base = offset == 0 ? first : searchUrl(i, r, caps, offset: offset, wholeSeason: wholeSeason);
      if (base == null) break;
      final url = _set(base, {'limit': '$pageSize'});
      ({NewznabPage page, String hash}) got;
      try {
        got = await _request(i, url, (body) async => (page: await _pageOf(body, i), hash: sha256.convert(utf8.encode(body)).toString()), kind: kind);
      } catch (_) {
        if (offset == 0) rethrow;
        break;
      }
      final page = got.page;
      if (page.items == 0 || !seenPages.add(got.hash)) break;
      final fresh = [for (final x in page.releases) if (seenUrls.add(x.nzbUrl)) x];
      if (page.releases.isNotEmpty && fresh.isEmpty) break;
      releases.addAll(results > 0 ? fresh.take(pageSize) : fresh);
      if (offset > 0x7FFFFFFF - pageSize) break;
      offset += pageSize;
      final total = page.total;
      if (total != null ? offset >= total : page.items < pageSize) break;
    }
    return releases;
  }

  /// [r]'s releases on [i]: the episode's search, then, for an episode, its season's packs and
  /// episodes found by a season search by id (held 2 hours, read once for a whole season).
  Future<List<UsenetRelease>> search(UsenetIndexer i, UsenetSearchRequest r, NewznabCaps caps, int results, {String? kind, bool Function()? cancelled}) async {
    final season = r.series ? _captured(_seasonSearch(i, r, caps, results, kind, cancelled)) : null;
    final url = searchUrl(i, r, caps);
    if (url == null) {
      if (season == null) return const [];
      final s = await season;
      if (s.error != null) throw s.error!;
      return s.value!;
    }
    final List<UsenetRelease> episodes;
    try {
      final idSearch = isIdSearch(url);
      episodes = [for (final x in await pages(i, url, r, caps, results, kind: kind, cancelled: cancelled)) if (releaseMatches(x.title, r, idSearch: idSearch)) x];
    } catch (_) {
      final s = season == null ? null : await season;
      if (s != null && s.error == null && s.value!.isNotEmpty) return s.value!;
      rethrow;
    }
    final packs = season == null ? const <UsenetRelease>[] : ((await season).value ?? const <UsenetRelease>[]);
    final seen = <String>{};
    return [for (final x in [...episodes, ...packs]) if (seen.add(x.nzbUrl)) x];
  }

  static Future<({List<UsenetRelease>? value, Object? error})> _captured(Future<List<UsenetRelease>> f) =>
      f.then((v) => (value: v, error: null), onError: (Object e) => (value: null, error: e));

  Future<List<UsenetRelease>> _seasonSearch(UsenetIndexer i, UsenetSearchRequest r, NewznabCaps caps, int results, String? kind, bool Function()? cancelled) async {
    final url = searchUrl(i, r, caps, wholeSeason: true);
    if (url == null) return const [];
    final key = '$url#$results';
    final now = UsenetClock.nowMs();
    var entry = _seasons.remove(key);
    if (entry != null && now - entry.at > _seasonFor.inMilliseconds) entry = null;
    if (entry == null) {
      final read = pages(i, url, r, caps, results, wholeSeason: true, kind: kind, cancelled: cancelled).then(
        (v) {
          // a search ended part way is not kept
          if (cancelled?.call() ?? false) _seasons.remove(key);
          return v;
        },
        onError: (Object e) {
          if (isSearchRejection(e)) return const <UsenetRelease>[];
          _seasons.remove(key);
          throw e;
        },
      );
      entry = _SeasonEntry(read, now);
    }
    _seasons[key] = entry;
    while (_seasons.length > _maxSeasons) {
      _seasons.remove(_seasons.keys.first);
    }
    final found = await entry.releases;
    return [
      for (final x in found)
        if (releaseMatches(x.title, r, idSearch: true, requireNumbering: true)) x.indexerId == i.id && x.indexerName == i.name ? x : x.of(i.id, i.name),
    ];
  }

  // ── Test indexer ──

  static const testPassed = 'Indexer connection succeeded.';
  static const testFailed = 'Could not connect. Check the API URL, key and indexer limits.';

  /// Settings' Test indexer: its capabilities, then a one-result search (two API hits), both
  /// asked now whatever a pause or the kept capabilities say. Passes when the search answers
  /// with results or refuses only its parameters (the key was taken).
  Future<({bool ok, String message})> test(UsenetIndexer i) async {
    if (i.problem != null) return (ok: false, message: testFailed);
    try {
      await capabilities(i, live: true);
      final url = baseUrl(i, 'search');
      if (url == null) return (ok: false, message: testFailed);
      await _request(i, _set(url, {'limit': '1'}), _keyCheck, live: true);
      return (ok: true, message: testPassed);
    } on NewznabFailure catch (e) {
      return (
        ok: false,
        message: switch (e.kind) {
          NewznabFailureKind.auth => 'The indexer rejected the API key. $testFailed',
          NewznabFailureKind.unreachable => 'Could not reach the indexer. Check the API URL.',
          NewznabFailureKind.cooldown => 'Indexer limit reached: paused until ${clock(DateTime.fromMillisecondsSinceEpoch(e.blockedUntil))}.',
          _ => testFailed,
        },
      );
    } catch (_) {
      return (ok: false, message: testFailed);
    }
  }
}
