// A release your indexers found, as the built-in Usenet source lists it, and what this device
// remembers of how releases went with your providers: gone or damaged (UNAVAILABLE, listed last,
// never tried by itself again), or played (AVAILABLE).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sources/addons.dart';
import 'usenet_names.dart';
import 'usenet_names.dart' as names show packSeasons;
import 'usenet_play.dart';

/// What an indexer said of a release, and how it was searched.
class UsenetRelease {
  UsenetRelease({
    required this.title,
    required this.nzbUrl,
    required this.indexerId,
    required this.indexerName,
    this.size = 0,
    this.publishedAt = 0,
    this.passworded = false,
    this.season,
    this.episode,
    this.series = false,
  });

  /// The release's name.
  final String title;

  /// Its NZB's address, as the indexer gave it (it carries your API key: never shown or kept).
  final String nzbUrl;
  final String indexerId;
  final String indexerName;

  /// Bytes (a pack's whole size), 0 when the indexer didn't say.
  final int size;

  /// When it was posted, in milliseconds since 1970; 0 when the indexer didn't say.
  final int publishedAt;

  /// The indexer says its archive needs a password: it can't be played.
  final bool passworded;

  /// The episode it was searched for: the engine picks that file in a pack, by the numbering
  /// release names go by.
  final int? season;
  final int? episode;

  /// Found by a series' search (its season packs are packs).
  final bool series;

  /// When it was posted, when the indexer said.
  DateTime? get published => publishedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(publishedAt) : null;

  /// Its resolution for filters and the plain sorts (2160, 1080, 720, 480, 360 or 0).
  late final int resolution = releaseResolution(title);

  /// What its name says for sorting.
  late final RankingFacts facts = RankingFacts.parse(title);

  /// What its name says for its details line.
  late final ReleaseLabels labels = ReleaseLabels.of(title);

  /// A cinema recording, telesync or screener.
  late final bool lowQuality = isLowQuality(title);

  /// A whole Blu-ray or DVD.
  late final bool fullDisc = isFullDisc(title);

  /// `BLU-RAY`, `UHD BLU-RAY`, `… ISO`, or null.
  late final String? blurayLabel = blurayLabelOf(title);

  /// The seasons its name says it holds; none for an episode or a film.
  late final List<int> packSeasons = names.packSeasons(title);

  /// A whole season or several, found by a series' search.
  bool get seasonPack => series && packSeasons.isNotEmpty;

  /// Whether one episode's share of it is known from [seasonEpisodes] (always, for an episode).
  bool episodeShareKnown(Map<int, int>? seasonEpisodes) =>
      packSeasons.isEmpty || (seasonEpisodes != null && packSeasons.every((s) => (seasonEpisodes[s] ?? 0) > 0));

  /// What one episode of it weighs: a pack's size shared by its seasons' episodes when each
  /// season's count is known, else its whole size.
  int episodeSize(Map<int, int>? seasonEpisodes) {
    if (packSeasons.isEmpty || seasonEpisodes == null || size <= 0) return size;
    var episodes = 0;
    for (final s in packSeasons) {
      final n = seasonEpisodes[s] ?? 0;
      if (n <= 0) return size;
      episodes += n;
    }
    return size ~/ episodes;
  }

  /// The same release as [indexerId]/[indexerName] list it.
  UsenetRelease of(String indexerId, String indexerName) => UsenetRelease(
    title: title,
    nzbUrl: nzbUrl,
    indexerId: indexerId,
    indexerName: indexerName,
    size: size,
    publishedAt: publishedAt,
    passworded: passworded,
    season: season,
    episode: episode,
    series: series,
  );

  /// The same release, found by a search for [season]/[episode] ([series]: a series' search).
  UsenetRelease searchedAs({int? season, int? episode, required bool series}) => UsenetRelease(
    title: title,
    nzbUrl: nzbUrl,
    indexerId: indexerId,
    indexerName: indexerName,
    size: size,
    publishedAt: publishedAt,
    passworded: passworded,
    season: season,
    episode: episode,
    series: series,
  );
}

/// How a release went before with your providers: played (AVAILABLE) or gone for good
/// (UNAVAILABLE).
enum UsenetMark { available, unavailable }

/// How another episode of the same upload last went: [episode] failed (a [blank] one: a fake
/// post, which this one likely is too) or played.
@immutable
class UsenetSibling {
  const UsenetSibling(this.episode, {required this.failed, this.blank = false});
  final int episode;
  final bool failed;
  final bool blank;
}

class _Entry {
  const _Entry(this.kind, this.at, this.providers, {this.episode, this.posted});
  final String kind;
  final int at;
  final String providers;
  final int? episode;
  final int? posted;

  _Entry withEpisode(int episode) => _Entry(kind, at, providers, episode: episode, posted: posted);

  Map<String, Object?> toJson() => {'kind': kind, 'at': at, 'providers': providers, 'episode': ?episode, 'posted': ?posted};

  static _Entry? fromJson(Object? j) {
    if (j is! Map || j['kind'] is! String || j['at'] is! num || j['providers'] is! String) return null;
    return _Entry(
      j['kind'] as String,
      (j['at'] as num).toInt(),
      j['providers'] as String,
      episode: (j['episode'] as num?)?.toInt(),
      posted: (j['posted'] as num?)?.toInt(),
    );
  }
}

/// What this device remembers of releases, for your providers of the time: kept under hashes of
/// the NZB's address (exact within one indexer), of the name and size in MB (the same upload on
/// another indexer; a pack by its name alone), and of the upload's name without its episode
/// (its other episodes). No address, key, name or password is kept. Shared by every profile.
class UsenetReleases {
  UsenetReleases._();

  static const _storeKey = 'device.usenet.outcomes';
  static const _oldKey = 'device.usenet.releases';

  /// Engine failures the same release repeats with the same providers.
  static const failureKinds = {'missing-article', 'hole-limit', 'invalid-article', 'blank-content'};
  static const _blank = 'blank-content';
  static const _played = 'played';

  static const unavailableFor = Duration(days: 30);
  static const availableFor = Duration(days: 14);
  static const _replayed = Duration(hours: 24);
  static const _episodeInterval = Duration(days: 8);
  static const _postingSlack = Duration(days: 2);
  static const maxEntries = 2000;
  static const _mb = 1000000;

  /// Bumped on every change, so lists on screen can be arranged and labelled again.
  static final changed = ValueNotifier<int>(0);

  static Map<String, _Entry>? _entries;
  static Future<void>? _loading;
  static Future<void> _saving = Future.value();

  /// Reads what was remembered (once).
  static Future<void> load() => _loading ??= () async {
    final entries = <String, _Entry>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storeKey);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          for (final e in j.entries) {
            final entry = _Entry.fromJson(e.value);
            if (entry != null) entries['${e.key}'] = entry;
          }
        }
      }
      if (prefs.containsKey(_oldKey)) await prefs.remove(_oldKey);
    } catch (_) {}
    // (a record made while loading is kept over what was read)
    _entries = {...entries, ...?_entries};
    changed.value++;
  }();

  static Map<String, _Entry> get _map => _entries ??= <String, _Entry>{};

  static String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

  static String? _name(String? title) {
    final n = title?.trim().toLowerCase();
    return n == null || n.isEmpty ? null : n;
  }

  /// The keys of a release at each size of [megabytes].
  static List<String> _keys(String? nzbUrl, String? title, List<int?> megabytes) {
    final name = _name(title);
    final titles = <String>[];
    if (name != null) {
      if (packSeasons(name).isNotEmpty) {
        titles.add('t:${_sha('$name\npack')}');
      } else {
        for (final m in {for (final m in megabytes) if (m != null && m > 0) m}) {
          titles.add('t:${_sha('$name\n${m}MB')}');
        }
      }
    }
    return [if (nzbUrl != null && nzbUrl.trim().isNotEmpty) 'u:${_sha(nzbUrl)}', ...titles];
  }

  /// The upload's key and this release's episode, for a single episode's name.
  static (String, int)? _siblingKey(String? title) {
    final name = _name(title);
    if (name == null) return null;
    final t = episodeTemplate(name);
    return t == null ? null : ('s:${_sha(t.template)}', t.episode);
  }

  /// Your providers' addresses (scheme, host and port: credentials, connections and priorities
  /// don't change what they hold).
  static String providersKey(List<String> servers) {
    final last = _lastServers;
    if (last != null && listEquals(last, servers)) return _lastProviders;
    final parts = <String>{};
    for (final s in servers) {
      final u = Uri.tryParse(s);
      if (u == null || u.host.isEmpty) {
        parts.add('');
        continue;
      }
      final host = u.host.contains(':') ? '[${u.host}]' : u.host;
      parts.add('${u.scheme}://$host:${u.hasPort ? u.port : -1}');
    }
    _lastServers = [...servers];
    return _lastProviders = _sha((parts.toList()..sort()).join('\n'));
  }

  // (a list asks with the same providers for every release)
  static List<String>? _lastServers;
  static String _lastProviders = '';

  static _Entry? _find(String? nzbUrl, String? title, int? size, List<String> servers, int? posted) {
    final providers = providersKey(servers);
    final mb = size != null && size > 0 ? size ~/ _mb : null;
    final keys = _keys(nzbUrl, title, mb == null ? const [null] : [mb - 1, mb, mb + 1]);
    _Entry? best;
    for (final k in keys) {
      final e = _map[k];
      if (e == null) continue;
      if (e.providers != providers && e.kind != _blank) continue;
      final p = e.posted;
      if (posted != null && p != null && (posted - p).abs() > _postingSlack.inMilliseconds) continue;
      if (best == null || e.at > best.at) best = e;
    }
    return best;
  }

  /// How a release last went with [servers]: failed for good within 30 days, or played within
  /// 14 (a later outcome replaces an earlier one).
  static ({bool failed, bool played}) outcome({String? nzbUrl, String? title, int? size, required List<String> servers, int? posted}) {
    final e = _find(nzbUrl, title, size, servers, posted);
    if (e == null) return (failed: false, played: false);
    final age = UsenetClock.nowMs() - e.at;
    return (
      failed: failureKinds.contains(e.kind) && age <= unavailableFor.inMilliseconds,
      played: e.kind == _played && age <= availableFor.inMilliseconds,
    );
  }

  /// How another episode of this release's upload went with [servers]: episodes posted together
  /// are removed, or kept, together. Null for packs and names of several episodes, when only
  /// this episode was tried, and for a repost (posted further apart than a week per episode).
  static UsenetSibling? sibling({String? title, required List<String> servers, int? posted}) {
    final sk = _siblingKey(title);
    if (sk == null) return null;
    final (key, episode) = sk;
    final e = _map[key];
    final other = e?.episode;
    if (e == null || other == null || other == episode) return null;
    if (e.providers != providersKey(servers) && e.kind != _blank) return null;
    final window = (episode - other).abs() * _episodeInterval.inMilliseconds + _postingSlack.inMilliseconds;
    final p = e.posted;
    if (posted == null || p == null || (posted - p).abs() > window) return null;
    final age = UsenetClock.nowMs() - e.at;
    if (failureKinds.contains(e.kind) && age <= unavailableFor.inMilliseconds) return UsenetSibling(other, failed: true, blank: e.kind == _blank);
    if (e.kind == _played && age <= availableFor.inMilliseconds) return UsenetSibling(other, failed: false);
    return null;
  }

  /// Remembers that a release failed with an engine failure [kind]; kinds other input or time
  /// can fix (sign-in, quota, a read error) are not remembered.
  static void record({String? nzbUrl, String? title, int? size, required List<String> servers, required String kind, int? posted}) {
    if (!failureKinds.contains(kind)) return;
    _when(() => _put(nzbUrl, title, size, servers, kind, posted));
  }

  /// Remembers that a release showed its first frame. Not written again within a day, unless
  /// its upload's newest outcome is another episode's.
  static void recordPlayed({String? nzbUrl, String? title, int? size, required List<String> servers, int? posted}) {
    _when(() {
      final known = _find(nzbUrl, title, size, servers, posted);
      final sk = _siblingKey(title);
      final siblingsKnow = sk == null || (_map[sk.$1]?.kind == _played && _map[sk.$1]?.episode == sk.$2 && _map[sk.$1]?.posted == posted);
      if (known != null && known.kind == _played && UsenetClock.nowMs() - known.at < _replayed.inMilliseconds && siblingsKnow) return;
      _put(nzbUrl, title, size, servers, _played, posted);
    });
  }

  /// Runs [f] once what was remembered is read.
  static void _when(void Function() f) {
    if (_entries != null && _loading != null) {
      f();
    } else {
      unawaited(load().then((_) => f()));
    }
  }

  static void _put(String? nzbUrl, String? title, int? size, List<String> servers, String kind, int? posted) {
    final keys = _keys(nzbUrl, title, [size == null ? null : size ~/ _mb]);
    if (keys.isEmpty) return;
    final now = UsenetClock.nowMs();
    final entry = _Entry(kind, now, providersKey(servers), posted: posted);
    for (final k in keys) {
      _map[k] = entry;
    }
    final sk = _siblingKey(title);
    if (sk != null) _map[sk.$1] = entry.withEpisode(sk.$2);
    _map.removeWhere((_, e) => now - e.at > unavailableFor.inMilliseconds);
    if (_map.length > maxEntries) {
      final oldest = _map.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in oldest.take(_map.length - maxEntries)) {
        _map.remove(e.key);
      }
    }
    _save();
    changed.value++;
  }

  static void _save() {
    final text = jsonEncode({for (final e in _map.entries) e.key: e.value.toJson()});
    _saving = _saving.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).setString(_storeKey, text);
      } catch (_) {}
    });
  }

  /// Waits for what was remembered to be written (tests).
  @visibleForTesting
  static Future<void> flushed() => _saving;

  /// Drops what is held in memory, as a restart does (tests).
  @visibleForTesting
  static void debugForget() {
    _entries = null;
    _loading = null;
  }

  // ── a stream's release ──

  static UsenetRelease? _release(AddonStream s) => s.usenetRelease is UsenetRelease ? s.usenetRelease as UsenetRelease : null;
  static String? _titleOf(AddonStream s) => _release(s)?.title ?? s.release;
  static int? _sizeOf(AddonStream s) => _release(s)?.size ?? s.sizeBytes;
  static int? _postedOf(AddonStream s) {
    final p = _release(s)?.publishedAt ?? 0;
    return p > 0 ? p : null;
  }

  /// How [s] went before with the providers it plays from now.
  static ({bool failed, bool played}) outcomeOf(AddonStream s) {
    if (!s.usenet) return (failed: false, played: false);
    return outcome(nzbUrl: s.nzbUrl, title: _titleOf(s), size: _sizeOf(s), servers: UsenetPlay.serversFor(s), posted: _postedOf(s));
  }

  /// How another episode of [s]'s upload went, for an untried [s].
  static UsenetSibling? siblingOf(AddonStream s) {
    if (!s.usenet) return null;
    return sibling(title: _titleOf(s), servers: UsenetPlay.serversFor(s), posted: _postedOf(s));
  }

  /// Where [s] goes in its list by how it went: 0 played (with [availableFirst] on), 2 failed
  /// for good or another episode of its upload was a fake post, else 1.
  static int rankOf(AddonStream s, {required bool availableFirst}) {
    final o = outcomeOf(s);
    if (o.failed) return 2;
    if (!o.played && (siblingOf(s)?.blank ?? false)) return 2;
    if (o.played && availableFirst) return 0;
    return 1;
  }

  /// How [s] went before, with your providers as they are now, or null.
  static UsenetMark? markOf(AddonStream s) {
    final o = outcomeOf(s);
    return o.failed ? UsenetMark.unavailable : (o.played ? UsenetMark.available : null);
  }

  /// [s] failed for good with the providers it plays from (listed last, skipped by the
  /// automatic fallback).
  static bool isUnplayable(AddonStream s) => outcomeOf(s).failed;

  /// [s] showed its first frame: AVAILABLE for two weeks.
  static void played(AddonStream s) {
    if (!s.usenet) return;
    recordPlayed(nzbUrl: s.nzbUrl, title: _titleOf(s), size: _sizeOf(s), servers: UsenetPlay.serversFor(s), posted: _postedOf(s));
  }

  /// [s] is gone or damaged on your providers ([kind], the engine's failure kind): UNAVAILABLE
  /// for 30 days.
  static void failed(AddonStream s, String kind) {
    if (!s.usenet) return;
    record(nzbUrl: s.nzbUrl, title: _titleOf(s), size: _sizeOf(s), servers: UsenetPlay.serversFor(s), kind: kind, posted: _postedOf(s));
  }

  /// Forgets everything (Settings' reset).
  static Future<void> clear() async {
    _entries = <String, _Entry>{};
    _loading = Future.value();
    changed.value++;
    _saving = _saving.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_storeKey);
        await prefs.remove(_oldKey);
      } catch (_) {}
    });
    await _saving;
  }
}
