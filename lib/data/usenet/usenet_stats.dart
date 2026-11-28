// What your Usenet sources did, on this device: Settings > Usenet > Diagnostics.
//
// Source statistics count each indexer's searches, API requests, NZB downloads and how its
// releases went, and each provider's articles, bytes, misses and errors, per local day for 30
// days and in all. They are kept by source id only (an edited source keeps its counts): never a
// name, an address, a key or a password. One store for every profile, on this device only.
//
// The last startup report says how long the last Usenet stream took to start, step by step,
// from the app's own marks and the engine's.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'usenet_engine.dart';
import 'usenet_sources.dart';

/// The days the statistics count.
enum StatsPeriod {
  last7('LAST_7_DAYS', 'Last 7 days'),
  last30('LAST_30_DAYS', 'Last 30 days'),
  allTime('ALL_TIME', 'All time');

  const StatsPeriod(this.stored, this.label);
  final String stored;
  final String label;
}

/// The searches and playback the statistics count.
enum StatsContent {
  all('ALL', 'All'),
  movies('MOVIES', 'Movies'),
  shows('SHOWS', 'Shows');

  const StatsContent(this.stored, this.label);
  final String stored;
  final String label;
}

/// An indexer's counts over a period.
@immutable
class IndexerCounts {
  const IndexerCounts([this.values = const {}]);
  final Map<String, int> values;
  int _v(String k) => values[k] ?? 0;

  /// Title searches that asked it.
  int get searches => _v('searches');

  /// Searches it answered with no matching release.
  int get emptySearches => _v('emptySearches');
  int get failedSearches => _v('failedSearches');

  /// Searches skipped while it was paused for a limit, or that ran into one.
  int get pausedSearches => _v('pausedSearches');

  /// Matching releases it returned.
  int get releases => _v('releases');

  /// HTTP requests sent to it (search pages, capabilities, key checks).
  int get requests => _v('requests');
  int get failedRequests => _v('failedRequests');

  /// Requests it refused for a limit (HTTP 429, or a spent quota).
  int get limitedRequests => _v('limitedRequests');
  int get answered => _v('answered');

  /// The answered requests' time from sending to the whole answer, summed.
  int get responseMs => _v('responseMs');

  /// NZB downloads for releases that opened (an NZB from the engine's cache is no download).
  int get grabs => _v('grabs');

  /// Its releases that showed a first frame.
  int get played => _v('played');

  /// Its releases that failed for good (gone, incomplete, damaged, empty).
  int get unavailable => _v('unavailable');

  bool get isEmpty => values.values.every((v) => v == 0);

  int get answeredSearches => searches - failedSearches - pausedSearches;

  /// Answered searches that found something.
  int get withResults {
    final a = answeredSearches;
    return a <= 0 ? 0 : (a - emptySearches).clamp(0, a);
  }

  /// The share of answered searches with results, in percent; null with none answered.
  int? get resultsPercent => answeredSearches <= 0 ? null : (withResults * 100 / answeredSearches).round();

  /// Releases per search that found any.
  int get averageReleases => withResults == 0 ? 0 : (releases / withResults).round();

  int? get averageResponseMs => answered > 0 ? (responseMs / answered).round() : null;
}

/// A provider's counts over a period.
@immutable
class ProviderCounts {
  const ProviderCounts([this.values = const {}]);
  final Map<String, int> values;
  int _v(String k) => values[k] ?? 0;

  /// Engine sessions that used it, opens it refused included.
  int get sessions => _v('sessions');

  /// Opens refused because of articles it lacked or broke.
  int get failedOpens => _v('failedOpens');

  /// Articles it served.
  int get articles => _v('articles');

  /// Bytes it served, decoded.
  int get bytes => _v('bytes');

  /// Articles it didn't have.
  int get missing => _v('missing');

  /// Connection, sign-in, quota and broken-transfer errors.
  int get errors => _v('errors');

  /// Time to the first byte, summed over [ttfbSessions] sessions.
  int get ttfbMs => _v('ttfbMs');
  int get ttfbSessions => _v('ttfbSessions');

  bool get isEmpty => values.values.every((v) => v == 0);

  /// Articles served of those asked for, in percent to one decimal; null when none was asked.
  double? get completion => articles + missing > 0 ? (articles * 1000 / (articles + missing)).round() / 10 : null;

  int? get firstByteMs => ttfbSessions > 0 ? (ttfbMs / ttfbSessions).round() : null;

  double get gib => bytes / 1073741824;
}

/// One source's counts: in all, and per local day for the last 30 days, each split into
/// movies, shows and other (capability and key checks).
class _Record {
  _Record(this.since, this.touchedAt);
  int since;
  int touchedAt;
  final total = <String, Map<String, int>>{};
  final days = <int, Map<String, Map<String, int>>>{};

  static void _add(Map<String, Map<String, int>> parts, String part, Map<String, int> delta) {
    final into = parts.putIfAbsent(part, () => <String, int>{});
    delta.forEach((k, v) {
      if (v != 0) into[k] = (into[k] ?? 0) + v;
    });
  }

  void add(int day, String part, Map<String, int> delta, int now) {
    touchedAt = now;
    _add(total, part, delta);
    _add(days.putIfAbsent(day, () => <String, Map<String, int>>{}), part, delta);
  }

  static List<String> _parts(StatsContent c) => switch (c) {
    StatsContent.all => const ['movie', 'show', 'other'],
    StatsContent.movies => const ['movie'],
    StatsContent.shows => const ['show'],
  };

  static void _sumInto(Map<String, int> out, Map<String, Map<String, int>> parts, List<String> which) {
    for (final p in which) {
      parts[p]?.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
    }
  }

  Map<String, int> sum(StatsPeriod period, StatsContent content, int today) {
    final out = <String, int>{};
    final which = _parts(content);
    if (period == StatsPeriod.allTime) {
      _sumInto(out, total, which);
    } else {
      final from = today - (period == StatsPeriod.last7 ? 6 : 29);
      days.forEach((day, parts) {
        if (day >= from) _sumInto(out, parts, which);
      });
    }
    return out;
  }

  Map<String, int> on(int day, StatsContent content) {
    final out = <String, int>{};
    final parts = days[day];
    if (parts != null) _sumInto(out, parts, _parts(content));
    return out;
  }

  static Map<String, Object?> _partsJson(Map<String, Map<String, int>> parts) => {
    for (final e in parts.entries)
      if (e.value.values.any((v) => v != 0)) e.key: {for (final c in e.value.entries) if (c.value != 0) c.key: c.value},
  };

  static Map<String, Map<String, int>> _partsFrom(Object? j) {
    final out = <String, Map<String, int>>{};
    if (j is! Map) return out;
    j.forEach((part, counts) {
      if (part is! String || counts is! Map) return;
      final m = <String, int>{};
      counts.forEach((k, v) {
        if (k is String && v is num && v.isFinite) m[k] = v.toInt();
      });
      if (m.isNotEmpty) out[part] = m;
    });
    return out;
  }

  Map<String, Object?> toJson() => {
    'since': since,
    'touchedAt': touchedAt,
    'total': _partsJson(total),
    'days': {for (final e in days.entries) if (e.value.isNotEmpty) '${e.key}': _partsJson(e.value)},
  };

  static _Record? fromJson(Object? j) {
    if (j is! Map || j['since'] is! num || j['touchedAt'] is! num) return null;
    final r = _Record((j['since'] as num).toInt(), (j['touchedAt'] as num).toInt());
    r.total.addAll(_partsFrom(j['total']));
    final days = j['days'];
    if (days is Map) {
      days.forEach((k, v) {
        final day = int.tryParse('$k');
        if (day != null) r.days[day] = _partsFrom(v);
      });
    }
    return r;
  }
}

/// A release a search listed: which indexer, for what kind of content, and when it last played
/// or failed for good.
class _Listed {
  _Listed(this.indexerId, this.part, [this.outcomeAt]);
  final String indexerId;
  final String part;
  int? outcomeAt;
}

/// The source statistics. Events come in from the indexer client, the searches, the engine and
/// the player; Settings reads them back by source id.
class UsenetStats {
  UsenetStats._();
  static final instance = UsenetStats._();

  static const _key = 'device.usenet.sourceStats';
  static const _periodKey = 'device.usenet.statsPeriod';
  static const _contentKey = 'device.usenet.statsContent';

  static const maxSources = 32;
  static const forgetAfterDays = 180;
  static const keepDays = 30;
  static const writeEvery = Duration(milliseconds: 5000);
  static const outcomeWindow = Duration(hours: 12);
  static const maxListed = 4000;
  static const maxKnown = 64;

  /// The kinds that make a release unavailable for good.
  static const unavailableKinds = {'missing-article', 'hole-limit', 'invalid-article', 'blank-content'};

  /// The kinds a provider is to blame for, when it lacked or broke an article.
  static const providerFailureKinds = {'missing-article', 'hole-limit', 'invalid-article'};

  final _revision = ValueNotifier<int>(0);

  /// Bumped on every change, so what is on screen shows it at once.
  ValueListenable<int> get revision => _revision;

  final _period = ValueNotifier<StatsPeriod>(StatsPeriod.last30);
  final _content = ValueNotifier<StatsContent>(StatsContent.all);

  /// The period and content Settings shows (they survive Reset statistics).
  ValueListenable<StatsPeriod> get period => _period;
  ValueListenable<StatsContent> get content => _content;

  final _indexers = <String, _Record>{};
  final _providers = <String, _Record>{};
  bool _loaded = false;
  Future<void>? _loading;
  final _early = <void Function()>[]; // events that came before the store was read

  bool _dirty = false;
  int? _lastWrite;
  Future<void> _writes = Future<void>.value();

  // in memory only: NZB addresses carry API keys
  final _listed = <String, _Listed>{};
  final _byUrl = <String, String>{};
  final _byAccount = <String, String>{};
  final _names = <String, String>{};

  /// Tests: the time events happen at.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  int get _now => clock().millisecondsSinceEpoch;

  /// The local day [t] falls on, counted from 1970-01-01.
  static int dayOf(DateTime t) {
    final l = t.toLocal();
    return DateTime.utc(l.year, l.month, l.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  }

  int get _today => dayOf(clock());

  // ── loading and saving ──

  /// Reads the store (once; events before it are counted when it is in).
  Future<void> load() => _loading ??= () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _period.value = StatsPeriod.values.where((p) => p.stored == prefs.getString(_periodKey)).firstOrNull ?? StatsPeriod.last30;
      _content.value = StatsContent.values.where((c) => c.stored == prefs.getString(_contentKey)).firstOrNull ?? StatsContent.all;
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) _read(raw);
    } catch (_) {
      // unreadable counts start empty
    }
    _loaded = true;
    final early = [..._early];
    _early.clear();
    for (final e in early) {
      e();
    }
    _revision.value++;
  }();

  void _read(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return;
      for (final (table, name) in [(_indexers, 'indexers'), (_providers, 'providers')]) {
        final m = j[name];
        if (m is! Map) continue;
        m.forEach((id, v) {
          final r = _Record.fromJson(v);
          if (id is String && r != null) table[id] = r;
        });
      }
    } catch (_) {
      _indexers.clear();
      _providers.clear();
    }
  }

  /// Runs [count] now, or once the store is in.
  void _when(void Function() count) {
    if (_loaded) {
      count();
    } else {
      _early.add(count);
      unawaited(load());
    }
  }

  /// A count changed: shown at once, written now if the last write was 5 s ago or more.
  void _changed() {
    _revision.value++;
    _dirty = true;
    final last = _lastWrite;
    if (last == null || _now - last >= writeEvery.inMilliseconds) _write();
  }

  void _write() {
    _prune();
    final text = jsonEncode({
      'v': 1,
      'indexers': {for (final e in _indexers.entries) e.key: e.value.toJson()},
      'providers': {for (final e in _providers.entries) e.key: e.value.toJson()},
    });
    _dirty = false;
    _lastWrite = _now;
    _writes = _writes.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).setString(_key, text);
      } catch (_) {}
    });
  }

  /// Sources untouched for 180 days go, then all but the 32 most recently touched of each kind;
  /// days before the last 30 go (their counts stay in the totals).
  void _prune() {
    final now = _now;
    final from = _today - (keepDays - 1);
    for (final table in [_indexers, _providers]) {
      table.removeWhere((_, r) => now - r.touchedAt > forgetAfterDays * Duration.millisecondsPerDay);
      if (table.length > maxSources) {
        final byAge = table.entries.toList()..sort((a, b) => b.value.touchedAt.compareTo(a.value.touchedAt));
        for (final e in byAge.skip(maxSources)) {
          table.remove(e.key);
        }
      }
      for (final r in table.values) {
        r.days.removeWhere((day, _) => day < from);
      }
    }
  }

  /// Writes what is held (the app going to the background, the statistics opening).
  Future<void> flush() async {
    await load();
    if (_dirty) _write();
    await _writes;
  }

  /// Clears every count (Reset statistics); the period and content chosen stay.
  Future<void> reset() async {
    await load();
    _indexers.clear();
    _providers.clear();
    _dirty = false;
    _writes = _writes.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).remove(_key);
      } catch (_) {}
    });
    _revision.value++;
    await _writes;
  }

  /// Clears everything, the period and content chosen too (an account reset, the Danger Zone).
  Future<void> clearAll() async {
    await reset();
    _listed.clear();
    _byUrl.clear();
    _byAccount.clear();
    _names.clear();
    _period.value = StatsPeriod.last30;
    _content.value = StatsContent.all;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_periodKey);
      await prefs.remove(_contentKey);
    } catch (_) {}
    _revision.value++;
  }

  Future<void> setPeriod(StatsPeriod p) async {
    _period.value = p;
    try {
      await (await SharedPreferences.getInstance()).setString(_periodKey, p.stored);
    } catch (_) {}
  }

  Future<void> setContent(StatsContent c) async {
    _content.value = c;
    try {
      await (await SharedPreferences.getInstance()).setString(_contentKey, c.stored);
    } catch (_) {}
  }

  // ── counting ──

  void _count(Map<String, _Record> table, String id, String part, Map<String, int> delta) {
    final now = _now;
    table.putIfAbsent(id, () => _Record(now, now)).add(_today, part, delta, now);
  }

  /// movie, show, or other (no content kind: capabilities, key checks).
  static String _part(String? kind) {
    final k = kind?.trim().toLowerCase() ?? '';
    if (k.isEmpty) return 'other';
    return k == 'movie' ? 'movie' : 'show';
  }

  /// An HTTP request sent to [indexerId]: [outcome] 'answered' (after [ms]), 'failed' or
  /// 'limited' (HTTP 429 or a spent quota). [kind]: the search's ('movie' or 'show'), null for
  /// capabilities and key checks. Requests a pause kept from being sent are not requests.
  void indexerRequest(String indexerId, String? kind, String outcome, int ms) => _when(() {
    final delta = switch (outcome) {
      'answered' => {'requests': 1, 'answered': 1, 'responseMs': max(0, ms)},
      'failed' => {'requests': 1, 'failedRequests': 1},
      'limited' => {'requests': 1, 'limitedRequests': 1},
      _ => null,
    };
    if (delta == null) return;
    _count(_indexers, indexerId, _part(kind), delta);
    _changed();
  });

  /// A title search that asked [indexerId] (once per indexer per search): [outcome] 'answered'
  /// with [releases] matching releases (their NZB addresses in [nzbUrls]), 'failed', or 'paused'
  /// (skipped for a limit, or it ran into one). [kind]: 'movie', anything else is a show.
  void indexerSearch(String indexerId, String kind, String outcome, int releases, List<String> nzbUrls) => _when(() {
    final part = kind.trim().toLowerCase() == 'movie' ? 'movie' : 'show';
    final delta = switch (outcome) {
      'answered' => {'searches': 1, 'releases': max(0, releases), if (releases <= 0) 'emptySearches': 1},
      'failed' => {'searches': 1, 'failedSearches': 1},
      'paused' => {'searches': 1, 'pausedSearches': 1},
      _ => null,
    };
    if (delta == null) return;
    if (outcome == 'answered') {
      for (final url in nzbUrls) {
        final was = _listed.remove(url);
        _listed[url] = _Listed(indexerId, part, was?.outcomeAt);
      }
      while (_listed.length > maxListed) {
        _listed.remove(_listed.keys.first);
      }
    }
    _count(_indexers, indexerId, part, delta);
    _changed();
  });

  static final _keyPlaceholder = RegExp(r'(?:\{|%7B)indexer-key(?::|%3A)([^}%]+)(?:\}|%7D)', caseSensitive: false);

  /// The indexer a release came from: the search that listed it, or the indexer its kept link
  /// names (`{indexer-key:<id>}` where its key goes), with the kind from [contentType].
  _Listed? _attribute(String url, String? contentType) {
    final known = _listed.remove(url);
    if (known != null) {
      _listed[url] = known;
      return known;
    }
    final m = _keyPlaceholder.firstMatch(url);
    if (m == null) return null;
    final listed = _Listed(Uri.decodeComponent(m.group(1)!), _part(contentType));
    _listed[url] = listed;
    while (_listed.length > maxListed) {
      _listed.remove(_listed.keys.first);
    }
    return listed;
  }

  /// A release opened and the engine downloaded its NZB (it wasn't in the engine's cache).
  void grab(String nzbUrl, {String? contentType}) => _when(() {
    final l = _attribute(nzbUrl, contentType);
    if (l == null) return;
    _count(_indexers, l.indexerId, l.part, const {'grabs': 1});
    _changed();
  });

  /// A release showed its first frame. With "unavailable", at most once per release in 12 h.
  void played(String nzbUrl, {String? contentType}) => _outcome(nzbUrl, contentType, 'played');

  /// A release failed for good: [failureKind] one of [unavailableKinds] (others count nothing).
  void unavailable(String nzbUrl, String failureKind, {String? contentType}) {
    if (unavailableKinds.contains(failureKind)) _outcome(nzbUrl, contentType, 'unavailable');
  }

  void _outcome(String url, String? contentType, String what) => _when(() {
    final l = _attribute(url, contentType);
    if (l == null) return;
    final now = _now;
    final at = l.outcomeAt;
    if (at != null && now - at < outcomeWindow.inMilliseconds) return;
    l.outcomeAt = now;
    _count(_indexers, l.indexerId, l.part, {what: 1});
    _changed();
  });

  /// What the engine reported for a session as it closed, or for an open it [refused] with
  /// [failureKind]: per provider (by its place in [servers]) articles, bytes, missing, errors and
  /// time to first byte. [contentKind]: 'show' when the open had an episode, else 'movie'.
  void providerReport(List<String> servers, List<Map<String, Object?>> report, {required bool refused, String? failureKind, String? contentKind}) {
    if (report.isEmpty) return;
    _when(() {
      final blame = refused && providerFailureKinds.contains(failureKind);
      // two listings of one provider (an addon's, with another password) are one here
      final sessions = <String, Map<String, int>>{};
      for (final r in report) {
        final i = r['server'];
        if (i is! num || i < 0 || i >= servers.length) continue;
        final id = _providerId(servers[i.toInt()]);
        if (id == null) continue;
        int n(String k) {
          final v = r[k];
          return v is num && v.isFinite ? max(0, v.toInt()) : 0;
        }

        final t = r['ttfbMs'];
        final ttfb = t is num && t.isFinite && t > 0 ? t.round() : null;
        final counts = {'articles': n('articles'), 'bytes': n('bytes'), 'missing': n('missing'), 'errors': n('errors'), 'ttfbMs': ttfb ?? 0, 'ttfbSessions': ttfb != null ? 1 : 0};
        // an open refused before anything was asked of this provider didn't use it
        if (refused && counts['articles']! + counts['missing']! + counts['errors']! == 0) continue;
        final known = sessions[id];
        if (known == null) {
          sessions[id] = counts;
        } else {
          // a session measures one first byte per provider: the first listing's
          final first = known['ttfbSessions']! > 0;
          counts.forEach((k, v) {
            if (first && (k == 'ttfbMs' || k == 'ttfbSessions')) return;
            known[k] = known[k]! + v;
          });
        }
      }
      if (sessions.isEmpty) return;
      final part = _part(contentKind);
      sessions.forEach((id, counts) {
        final failedHere = blame && counts['missing']! + counts['errors']! > 0;
        _count(_providers, id, part, {...counts, 'sessions': 1, if (failedHere) 'failedOpens': 1});
      });
      _changed();
    });
  }

  /// The account an engine server address is for: the host in lower case (an IPv6 one in
  /// brackets), the port (563 for nntps, 119 for nntp when none), and the username. The
  /// password, connections and priority don't count.
  static String? accountOf(String serverUrl) {
    final u = Uri.tryParse(serverUrl);
    if (u == null || u.host.isEmpty) return null;
    var host = u.host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    if (host.contains(':')) host = '[$host]';
    final port = u.hasPort ? u.port : (u.scheme.toLowerCase() == 'nntps' ? 563 : 119);
    final user = u.userInfo.split(':').first;
    var name = user;
    try {
      name = Uri.decodeComponent(user);
    } catch (_) {}
    return '$host:$port\n$name';
  }

  String? _providerId(String serverUrl) {
    final exact = _byUrl[serverUrl];
    if (exact != null) return exact;
    final account = accountOf(serverUrl);
    return account == null ? null : _byAccount[account];
  }

  /// Your providers as the configuration has them now (every read and save of it): sessions
  /// opened with an address from before an edit still count for the edited provider.
  void knownProviders(List<UsenetProvider> providers) {
    void put(Map<String, String> m, String k, String v) {
      m.remove(k);
      m[k] = v;
      while (m.length > maxKnown) {
        m.remove(m.keys.first);
      }
    }

    for (final p in providers) {
      final url = p.serverUrl;
      put(_byUrl, url, p.id);
      final account = accountOf(url);
      if (account != null) put(_byAccount, account, p.id);
      put(_names, p.id, p.name);
    }
  }

  /// What to call an engine server: its provider's name, else its host, else "?".
  String providerLabel(String serverUrl) {
    final id = _providerId(serverUrl);
    final name = id == null ? null : _names[id];
    if (name != null && name.trim().isNotEmpty) return name;
    final host = Uri.tryParse(serverUrl)?.host ?? '';
    return host.isEmpty ? '?' : host;
  }

  // ── reading ──

  /// [indexerId]'s counts in [period] for [content] (the chosen ones when left out).
  IndexerCounts indexer(String indexerId, {StatsPeriod? period, StatsContent? content}) {
    final r = _indexers[indexerId];
    return r == null ? const IndexerCounts() : IndexerCounts(r.sum(period ?? _period.value, content ?? _content.value, _today));
  }

  /// [indexerId]'s counts today alone.
  IndexerCounts indexerToday(String indexerId, {StatsContent? content}) {
    final r = _indexers[indexerId];
    return r == null ? const IndexerCounts() : IndexerCounts(r.on(_today, content ?? _content.value));
  }

  ProviderCounts provider(String providerId, {StatsPeriod? period, StatsContent? content}) {
    final r = _providers[providerId];
    return r == null ? const ProviderCounts() : ProviderCounts(r.sum(period ?? _period.value, content ?? _content.value, _today));
  }

  /// When [id] (an indexer or a provider) was first counted, or last reset.
  DateTime? since(String id) {
    final r = _indexers[id] ?? _providers[id];
    return r == null ? null : DateTime.fromMillisecondsSinceEpoch(r.since);
  }

  /// Tests: forgets everything in memory, as a fresh start of the app.
  @visibleForTesting
  void debugRestart() {
    _indexers.clear();
    _providers.clear();
    _listed.clear();
    _byUrl.clear();
    _byAccount.clear();
    _names.clear();
    _early.clear();
    _loaded = false;
    _loading = null;
    _dirty = false;
    _lastWrite = null;
    _writes = Future<void>.value();
    _period.value = StatsPeriod.last30;
    _content.value = StatsContent.all;
    clock = DateTime.now;
  }
}

/// The rows of a statistics card, in Settings' words.
abstract final class UsenetStatRows {
  static String _date(DateTime? t) => t == null ? '—' : DateFormat.yMMMd().format(t);

  static String _withToday(int n, int today) => today > 0 ? '$n · $today today' : '$n';

  /// An indexer's card: empty when there is nothing for the filters ("No data yet").
  static List<(String, String)> indexer(IndexerCounts c, IndexerCounts today, StatsPeriod period, DateTime? since) {
    if (c.isEmpty) return const [];
    final parts = [if (c.failedSearches > 0) '${c.failedSearches} failed', if (c.pausedSearches > 0) '${c.pausedSearches} paused'];
    final percent = c.resultsPercent;
    final avg = c.averageResponseMs;
    return [
      ('Searches', parts.isEmpty ? '${c.searches}' : '${c.searches} (${parts.join(', ')})'),
      if (percent != null) ('Searches with results', '$percent% · ${c.averageReleases} ${c.averageReleases == 1 ? 'release' : 'releases'} on average'),
      ('API requests', _withToday(c.requests, today.requests)),
      if (avg != null) ('Average response', '$avg ms'),
      ('Limit answers', '${c.limitedRequests}'),
      ('Failed requests', '${c.failedRequests}'),
      ('NZB downloads', _withToday(c.grabs, today.grabs)),
      ('Played / unavailable', '${c.played} / ${c.unavailable}'),
      if (period == StatsPeriod.allTime) ('Since', _date(since)),
    ];
  }

  /// A provider's card: empty when there is nothing for the filters.
  static List<(String, String)> provider(ProviderCounts c, StatsPeriod period, DateTime? since) {
    if (c.isEmpty) return const [];
    final completion = c.completion;
    final firstByte = c.firstByteMs;
    return [
      ('Articles served', '${c.articles}'),
      if (completion != null) ('Completion', '${completion.toStringAsFixed(1)}% (${c.missing} missing)'),
      ('Errors', '${c.errors}'),
      ('Downloaded', '${c.gib.toStringAsFixed(2)} GiB'),
      if (firstByte != null) ('First byte', '$firstByte ms'),
      ('Sessions', c.failedOpens > 0 ? '${c.sessions} (${c.failedOpens} failed to open)' : '${c.sessions}'),
      if (period == StatsPeriod.allTime) ('Since', _date(since)),
    ];
  }
}

// ───────────────────────── The last startup ─────────────────────────

/// The app's marks for one Usenet startup, in milliseconds from when the release was picked:
/// make one as the resolve starts and mark each step once (later marks of a name are ignored).
///
/// Marks the startup card reads: `resolve_lock_acquired`, `engine_reused` or
/// `engine_starting`, `engine_ready`, `session_request`, `session_response`, `resolved`,
/// `prepared_session_reused` (a prepared session was used), `prepare` (the player was handed
/// the stream), `first_load`, `tracks_known`, `decoder_ready`, `player_ready`, `first_frame`;
/// and the duration `decoder_init_duration`.
class UsenetStartupTrace {
  UsenetStartupTrace();
  final _clock = Stopwatch()..start();
  final marks = <String, double>{};

  void mark(String name) => marks.putIfAbsent(name, () => _clock.elapsedMicroseconds / 1000);

  /// A step's own length rather than a moment ([name] is a duration: `decoder_init_duration`).
  void duration(String name, Duration d) => marks.putIfAbsent(name, () => d.inMicroseconds / 1000);
}

/// How the last Usenet stream started.
@immutable
class UsenetStartupReport {
  const UsenetStartupReport({required this.fastMkv, required this.fastNzb, required this.recordedAt, required this.marks, required this.engine});
  final bool fastMkv;
  final bool fastNzb;
  final DateTime recordedAt;
  final Map<String, double> marks;

  /// The engine's own report: the open's `startup`, then its session diagnostics.
  final Map<String, Object?> engine;

  Map<String, Object?> toJson() => {
    'fastMkvStartup': fastMkv,
    'fastNzbFetch': fastNzb,
    'recordedAtMs': recordedAt.millisecondsSinceEpoch,
    'marksMs': marks,
    'engine': engine,
  };

  static UsenetStartupReport? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['recordedAtMs'];
    final marks = j['marksMs'];
    return UsenetStartupReport(
      fastMkv: j['fastMkvStartup'] == true,
      fastNzb: j['fastNzbFetch'] != false,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(at is num ? at.toInt() : 0),
      marks: {
        if (marks is Map)
          for (final e in marks.entries)
            if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble(),
      },
      engine: j['engine'] is Map ? (j['engine'] as Map).cast<String, Object?>() : const {},
    );
  }

  UsenetStartupReport withEngine(Map<String, Object?> e) => UsenetStartupReport(fastMkv: fastMkv, fastNzb: fastNzb, recordedAt: recordedAt, marks: marks, engine: e);
}

/// One row of a startup card.
@immutable
class DiagRow {
  const DiagRow(this.label, this.value, {this.highlight = false});
  final String label;
  final String value;
  final bool highlight;
}

/// One startup card: its title, rows, and a note under them.
@immutable
class DiagCard {
  const DiagCard(this.title, this.rows, {this.note});
  final String title;
  final List<DiagRow> rows;
  final String? note;
}

/// The last startup report, kept on this device (only the last; it survives restarts).
class UsenetDiagnostics {
  UsenetDiagnostics._();
  static final instance = UsenetDiagnostics._();

  static const _key = 'device.usenet.lastStartup';

  final _last = ValueNotifier<UsenetStartupReport?>(null);

  /// The last report, null before any (reading it starts with [ensureLoaded]).
  ValueListenable<UsenetStartupReport?> get last => _last;
  Future<void>? _loading;

  /// Reads the kept report, once.
  Future<void> ensureLoaded() => _loading ??= () async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null && raw.isNotEmpty && _last.value == null) _last.value = UsenetStartupReport.fromJson(jsonDecode(raw));
    } catch (_) {}
  }();

  /// Keeps how [session] started (call at its first frame): the app's marks from [trace] and
  /// the engine's startup report; then, when the engine answers within 5 s, its fuller session
  /// diagnostics in place of the latter. Fast MKV startup and Fast NZB fetch as set now.
  Future<void> record(UsenetSession session, UsenetStartupTrace trace, {bool fetchEngine = true}) async {
    final report = UsenetStartupReport(
      fastMkv: AppSettings.usenetFastMkv.value,
      fastNzb: AppSettings.usenetFastNzb.value,
      recordedAt: DateTime.now(),
      marks: Map.unmodifiable(trace.marks),
      engine: session.startup,
    );
    await keep(report);
    if (!fetchEngine) return;
    final more = await UsenetEngine.instance.diagnostics(session.id, timeout: const Duration(seconds: 5));
    if (more != null && identical(_last.value, report)) await keep(report.withEngine(more));
  }

  /// Keeps [report] as the last one.
  Future<void> keep(UsenetStartupReport report) async {
    _loading ??= Future<void>.value();
    _last.value = report;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(report.toJson()));
    } catch (_) {}
  }

  /// Forgets it (an account reset, the Danger Zone).
  Future<void> clear() async {
    _loading ??= Future<void>.value();
    _last.value = null;
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  @visibleForTesting
  void debugRestart() {
    _last.value = null;
    _loading = null;
  }

  // ── the cards ──

  static const _dash = '—';

  static String _ms(Object? x) => x is num && x.isFinite && x >= 0 ? '${x.round()} ms' : _dash;

  static Map<String, double> _numbers(Object? m) => {
    if (m is Map)
      for (final e in m.entries)
        if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble(),
  };

  static String _span(Map<String, double> m, String from, String to) {
    final a = m[from], b = m[to];
    if (a == null || b == null || !a.isFinite || !b.isFinite || b - a < 0) return _dash;
    return '${(b - a).round()} ms';
  }

  static String _mib(Object? bytes) => bytes is num && bytes.isFinite ? '${(bytes / 1048576).toStringAsFixed(1)} MiB' : _dash;

  static String _count(Object? n) => n is num && n.isFinite ? '${n.toInt()}' : _dash;

  /// The cards for [r], in order: summary, engine, NZB stages, cache. Without a report only
  /// the summary, saying how to get one.
  static List<DiagCard> cards(UsenetStartupReport? r) {
    if (r == null) {
      return const [DiagCard('Last Usenet startup', [], note: 'Play a Usenet stream to see its startup timings here.')];
    }
    final m = r.marks;
    final engine = r.engine;
    final em = _numbers(engine['marksMs']);
    final ed = _numbers(engine['durationsMs']);
    String onOff(bool b) => b ? 'On' : 'Off';

    final prefetch = em.containsKey('warmup_skipped_connection_limit')
        ? 'Skipped: fewer than 3 connections'
        : em.containsKey('head_article_ready') && em.containsKey('tail_article_ready')
        ? 'Head and tail ready'
        : em.containsKey('warmup_started')
        ? 'Started; partly ready or budget limited'
        : !r.fastMkv
        ? 'Off'
        : 'Not applicable';
    double? longest;
    final ranges = engine['ranges'];
    if (ranges is List) {
      for (final x in ranges.whereType<Map>()) {
        final first = x['firstByteMs'], start = x['startMs'];
        if (first is num && start is num && first >= 0) {
          final wait = (first - start).toDouble();
          if (longest == null || wait > longest) longest = wait;
        }
      }
    }

    final cache = engine['nzbCache'] is Map ? engine['nzbCache'] as Map : const {};
    final lookup = cache['lookup'];
    final lookupText = switch (lookup) {
      'hit' => 'Hit — reused from disk',
      'disabled' => 'Off',
      'miss' => switch (cache['reason']) {
        'expired' => 'Miss — expired',
        'invalid' => 'Miss — invalid cached file',
        'disk_error' => 'Disk access failed',
        _ => 'Miss — not cached',
      },
      _ => _dash,
    };
    final write = cache['write'];
    final writeText = switch (write) {
      'saved' => 'Saved',
      'oversized' => 'Skipped — exceeds 64 MiB',
      'cancelled' => 'Not saved — cancelled',
      'invalid' => 'Not saved — invalid NZB',
      'disk_error' => 'Disk access failed',
      'busy' => 'Skipped — cache busy',
      _ => _dash,
    };
    final store = engine['store'] is Map ? engine['store'] as Map : const {};

    return [
      DiagCard('Last Usenet startup', [
        DiagRow('When', DateFormat.yMd().add_jms().format(r.recordedAt)),
        DiagRow('Fast MKV startup', onOff(r.fastMkv)),
        DiagRow('Fast NZB fetch', onOff(r.fastNzb)),
        DiagRow('Resolve to first frame', _ms(m['first_frame']), highlight: true),
        DiagRow('Engine startup / reuse', _span(m, 'resolve_lock_acquired', 'engine_ready')),
        DiagRow('Engine already running', onOff(m.containsKey('engine_reused') || m.containsKey('prepared_session_reused'))),
        DiagRow('Open Usenet session', _span(m, 'session_request', 'session_response')),
        DiagRow('Player handoff', _span(m, 'resolved', 'prepare')),
        DiagRow('Prepare to first frame', _span(m, 'prepare', 'first_frame')),
        DiagRow('Video decoder setup', _ms(m['decoder_init_duration'])),
      ]),
      DiagCard(
        'Usenet startup · Engine',
        [
          DiagRow('Startup prefetch', prefetch),
          DiagRow('NZB loading (including cache)', _span(em, 'pool_created', 'nzb_loaded')),
          DiagRow('Select and probe video', _span(em, 'nzb_loaded', 'content_selected')),
          DiagRow('RAR continuation discovery', _ms(engine['archiveDiscoveryMs'])),
          DiagRow('Longest request wait', _ms(longest)),
          DiagRow('Head article ready', _span(em, 'warmup_started', 'head_article_ready')),
          DiagRow('Tail article ready', _span(em, 'warmup_started', 'tail_article_ready')),
          DiagRow('Session open to media bytes', _ms(em['first_media_bytes'])),
        ],
        note: 'Some work overlaps, so these details do not add up to the total. — means not measured or not applicable.',
      ),
      DiagCard(
        'Usenet startup · NZB stages',
        [
          DiagRow('Provider pool setup', _span(em, 'provider_setup_started', 'pool_created')),
          DiagRow('First NNTP metadata wait', _span(em, 'first_nntp_request', 'first_nntp_metadata')),
          DiagRow('NZB cache lookup', _span(em, 'nzb_cache_lookup_started', 'nzb_cache_lookup_finished')),
          DiagRow('NZB request to headers', _span(em, 'nzb_fetch_started', 'nzb_response_headers')),
          DiagRow('NZB body read time', _ms(ed['nzb_body_read'])),
          DiagRow('NZB parse / decompress work', _ms(ed['nzb_parse_work'])),
          DiagRow('NZB index and write', _span(em, 'nzb_index_started', 'nzb_index_finished')),
          DiagRow('Cache filesystem work', _ms(ed['nzb_cache_io'])),
          DiagRow('Cache reopen', _span(em, 'nzb_index_finished', 'nzb_cache_bound')),
        ],
        note: 'Body reads overlap downloading and parsing. Parse work leaves out the time reading the body; filesystem work is part of index and write. These are wall-clock times.',
      ),
      DiagCard('Usenet startup · Cache', [
        DiagRow('NZB disk cache', lookupText),
        DiagRow('NZB cache write', writeText),
        DiagRow('Cached NZB size', lookup == 'hit' || write == 'saved' ? _mib(cache['bytes']) : _dash),
        DiagRow('Article cache hits', _count(store['cacheHits'])),
        DiagRow('Downloads shared', _count(store['sharedJoins'])),
        DiagRow('Article downloads started', _count(store['downloads'])),
        DiagRow('Downloads cancelled', _count(store['cancellations'])),
        DiagRow('Article buffers allocated', _mib(engine['articleSlabsBytes'])),
      ]),
    ];
  }
}
