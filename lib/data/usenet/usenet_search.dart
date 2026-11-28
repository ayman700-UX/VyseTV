// The built-in Usenet source: your Newznab indexers searched from this device for a film or an
// episode, their releases matched to it, filtered, ranked and labelled, as streams of
// Addon.usenet that play from your own providers.
//
// Every enabled indexer is asked at once (or, with "Search lower priorities only as fallback",
// one priority at a time until something is listed). The list shows once every indexer
// answered, or with what came after 5 seconds, and fills in from there. Titles are looked up
// on TMDB alongside (names, years, the TVDB id, a season's episode count, other series of the
// same name), so that indexers that only search by title can be asked, and so that what an
// indexer filed under the wrong id or a namesake is left out. Anime catalog ids are searched
// under IMDb's or TheTVDB's numbering, never under the catalog's own.
//
// A finished search is kept for 15 minutes (any change in Settings > Usenet makes it a new
// one). Releases known to be gone go last and say so, whenever the list is shown.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../catalog/tmdb.dart';
import '../net.dart';
import '../sources/addons.dart';
import 'newznab.dart';
import 'usenet_names.dart';
import 'usenet_play.dart';
import 'usenet_ranking.dart';
import 'usenet_release.dart';
import 'usenet_sources.dart';

/// What a badge on a Usenet result says, for its colour: played recently (green), gone for
/// good (grey), another episode of its upload failed (orange) or played (teal), a season pack
/// (purple), anything else (a whole Blu-ray: blue).
enum UsenetBadgeKind { available, unavailable, failed, played, pack, other }

/// A badge on a Usenet result: its text (English: AVAILABLE, UNAVAILABLE, E02 FAILED, E02
/// PLAYED, SEASON PACK, BLU-RAY…) and its kind.
@immutable
class UsenetBadge {
  const UsenetBadge(this.text, this.kind);
  final String text;
  final UsenetBadgeKind kind;

  /// Its colour (ARGB), as the label is drawn on it in white.
  int get color => switch (kind) {
    UsenetBadgeKind.unavailable => 0xFF6C757D,
    UsenetBadgeKind.available => 0xFF198754,
    UsenetBadgeKind.failed => 0xFFFD7E14,
    UsenetBadgeKind.played => 0xFF0AA2C0,
    UsenetBadgeKind.pack => 0xFF6F42C1,
    UsenetBadgeKind.other => 0xFF0B5ED7,
  };
}

/// A search's results: the arranged streams, and one note per indexer that failed.
typedef UsenetResults = ({List<AddonStream> streams, List<String> failures});

/// The built-in Usenet source's searches.
class UsenetSearch {
  UsenetSearch._();
  static final instance = UsenetSearch._();

  /// The group's name: in binge groups, and how other code knows the built-in results.
  static const groupName = 'Built-in Usenet';

  /// Every indexer search, once per indexer per stream search (re-asks by title included):
  /// its kind (`movie` or `show`), how it went (`answered`, `failed`, or `paused`: skipped or
  /// stopped by its limit), how many releases it gave and their NZB addresses (statistics
  /// listen; usenet_stats.dart).
  static void Function(String indexerId, String kind, String outcome, int releases, List<String> nzbUrls)? onSearch;

  /// The user's sources can search: an enabled provider and an enabled indexer
  /// (UsenetSources.usable). The caller checks the built-in addon is on.
  static bool get ready => UsenetSourcesStore.current.value.usable;

  /// How long the list waits for every indexer before showing what came.
  @visibleForTesting
  static Duration partialWait = const Duration(seconds: 5);

  /// How long a film's id results wait for its names and year before they are listed
  /// unchecked, how long a series' list may still change once its details come, and how long a
  /// season's episode count is waited for.
  @visibleForTesting
  static Duration lookupWait = const Duration(seconds: 3);

  /// How long an anime catalog id waits for its IMDb or TheTVDB numbering.
  @visibleForTesting
  static Duration animeWait = const Duration(seconds: 5);

  /// How long a finished search is reused.
  @visibleForTesting
  static Duration reuseFor = const Duration(minutes: 15);
  static const _maxSessions = 12;

  /// TMDB's API (tests answer for it).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String path, Map<String, String> query) tmdbGet = Tmdb.get;

  /// The anime databases' mapping of a catalog id ([prefix] kitsu, mal, anilist or anidb) to
  /// IMDb, TheTVDB and TheTVDB's numbering of each episode (tests answer for it).
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(String prefix, String id) animeMapping = _aniZip;

  static Future<Map<String, dynamic>?> _aniZip(String prefix, String id) async {
    final r = await netClient.get(Uri.https('api.ani.zip', '/mappings', {'${prefix}_id': id})).timeout(animeWait);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body);
    return j is Map<String, dynamic> ? j : null;
  }

  final _sessions = <String, _Session>{};

  static const _types = {'movie', 'series', 'tv', 'show'};

  /// Whether [t] can be searched at all (a title playable with no addon): your sources can
  /// search, and it is a film, or an episode with its numbers.
  static bool canSearch(AddonTarget t) {
    if (!ready) return false;
    final type = t.type.toLowerCase();
    if (!_types.contains(type)) return false;
    if (type == 'movie') return true;
    if (_animeIdOf(t, series: true) != null) return true;
    final s = t.imdbSeason ?? t.season, e = t.imdbEpisode ?? t.episode;
    return s != null && s >= 0 && e != null && e >= 1;
  }

  /// The built-in Usenet results for [t] as streams of [addon] (Addon.usenet), already
  /// arranged: ranked, filtered, release memory applied. Null when the title can't be
  /// searched: no usable ids or title, or a series without season and episode.
  /// [onSome]: each list as it is shown before the end, the whole arranged list each time (it
  /// shows once every indexer answered, or what came after 5 s; with "Show results as each
  /// indexer answers" as each answers). [refresh]: search again even if a search was kept.
  /// Never throws: failures come back in `failures`, one text per failed indexer, never a raw
  /// error.
  Future<UsenetResults?> search(Addon addon, AddonTarget t, {void Function(List<AddonStream> soFar)? onSome, bool refresh = false}) async {
    try {
      final config = UsenetSourcesStore.current.value;
      if (!config.usable || !canSearch(t)) return null;
      await Future.wait([UsenetReleases.load(), Newznab.instance.load()]);
      final title = _titleKey(t);
      final key = '$title|${sha256.convert(utf8.encode(jsonEncode(config.toJson())))}';
      // the same title searched with another configuration: that search ends
      for (final k in [for (final k in _sessions.keys) if (k.startsWith('$title|') && k != key) k]) {
        _sessions.remove(k)!.cancel();
      }
      var session = _sessions.remove(key);
      if (session != null && (refresh || (session.finished && !session.reusable))) {
        session.cancel();
        session = null;
      }
      session ??= _Session(addon, t, config)..start();
      _sessions[key] = session;
      while (_sessions.length > _maxSessions) {
        _sessions.remove(_sessions.keys.first)!.cancel();
      }
      final result = await session.attach(onSome == null ? null : (soFar) => onSome(arrange(soFar)));
      if (result == null) return null;
      return (streams: arrange(result.streams), failures: result.failures);
    } catch (_) {
      return (streams: const <AddonStream>[], failures: const <String>[]);
    }
  }

  /// Forgets the searches kept (a refresh of everything, or a reset).
  void forget() {
    for (final s in _sessions.values) {
      s.cancel();
    }
    _sessions.clear();
  }

  static String _titleKey(AddonTarget t) => [
    t.type.toLowerCase(),
    t.imdb,
    t.tmdb,
    t.kitsu,
    t.anime,
    t.raw,
    t.video,
    t.season,
    t.episode,
    t.imdbSeason,
    t.imdbEpisode,
    t.title,
    t.year,
  ].join('|');

  /// Re-arranges a list delivered earlier with the release memory as it is now: releases
  /// that failed since go last (and say UNAVAILABLE), ones that played go first when "Show
  /// available releases first" is on; the order is otherwise kept. [streams]: the built-in
  /// group's list.
  List<AddonStream> arrange(List<AddonStream> streams) {
    final first = UsenetSourcesStore.current.value.availableFirst;
    final ranks = {for (final s in streams) s: s.usenet ? UsenetReleases.rankOf(s, availableFirst: first) : 1};
    return stableSorted(streams, (a, b) => ranks[a]!.compareTo(ranks[b]!));
  }

  /// Badges for a Usenet result, built-in or from an addon, in display order: UNAVAILABLE or
  /// AVAILABLE (how it went with your providers), else E02 FAILED or E02 PLAYED (another
  /// episode of its upload), then SEASON PACK and BLU-RAY / UHD BLU-RAY (… ISO) for built-in
  /// results.
  static List<UsenetBadge> badgesOf(AddonStream s) {
    if (!s.usenet) return const [];
    // (asked on every build of a row: the answer stands until the memory or the providers
    // change, or a minute passes, when outcomes may have expired)
    final revision = UsenetReleases.changed.value * 100000000 + UsenetClock.nowMs() ~/ 60000;
    final servers = UsenetPlay.serversFor(s);
    final kept = _badges[s];
    if (kept != null && kept.$1 == revision && listEquals(kept.$2, servers)) return kept.$3;
    final out = _badgesOf(s);
    _badges[s] = (revision, servers, out);
    return out;
  }

  static final _badges = Expando<(int, List<String>, List<UsenetBadge>)>();

  static List<UsenetBadge> _badgesOf(AddonStream s) {
    final o = UsenetReleases.outcomeOf(s);
    final r = s.usenetRelease is UsenetRelease ? s.usenetRelease as UsenetRelease : null;
    final out = <UsenetBadge>[];
    if (o.failed) {
      out.add(const UsenetBadge('UNAVAILABLE', UsenetBadgeKind.unavailable));
    } else if (o.played) {
      out.add(const UsenetBadge('AVAILABLE', UsenetBadgeKind.available));
    } else {
      final sib = UsenetReleases.siblingOf(s);
      if (sib != null) {
        final e = 'E${'${sib.episode}'.padLeft(2, '0')}';
        out.add(sib.failed ? UsenetBadge('$e FAILED', UsenetBadgeKind.failed) : UsenetBadge('$e PLAYED', UsenetBadgeKind.played));
      }
    }
    if (r != null && r.seasonPack) out.add(const UsenetBadge('SEASON PACK', UsenetBadgeKind.pack));
    final disc = r?.blurayLabel;
    if (disc != null) out.add(UsenetBadge(disc, UsenetBadgeKind.other));
    return out;
  }

  /// Which release the next episode keeps to: a series' upload (its name without the episode
  /// number and name), a pack's or a film's own name. Null for a series name without numbers.
  static String? bingeGroupOf(String title, {required bool series}) {
    final name = title.trim().toLowerCase();
    if (name.isEmpty) return null;
    if (!series) return '$groupName|$name';
    final t = episodeTemplate(name);
    if (t != null) return '$groupName|${t.template}';
    if (packSeasons(name).isNotEmpty) return '$groupName|$name';
    return null;
  }

  /// An NZB address safe to keep (a "last link"): every indexer key of 8 characters or more,
  /// longest first, replaced by a reference to its indexer.
  static String keylessLink(String nzbUrl, List<UsenetIndexer> indexers) {
    final keyed = [for (final i in indexers) if (i.apiKey.length >= 8) i]..sort((a, b) => b.apiKey.length.compareTo(a.apiKey.length));
    var out = nzbUrl;
    for (final i in keyed) {
      out = out.replaceAll(i.apiKey, '{indexer-key:${i.id}}');
    }
    return out;
  }

  static final _keyRef = RegExp(r'\{indexer-key:([^}]+)\}');

  /// A kept link with today's keys put back, or null when an indexer it names was removed or
  /// has no key. A link naming none is used as it is.
  static String? keyedLink(String stored, List<UsenetIndexer> indexers) {
    var missing = false;
    final out = stored.replaceAllMapped(_keyRef, (m) {
      final i = indexers.where((x) => x.id == m[1]).firstOrNull;
      if (i == null || i.apiKey.isEmpty) {
        missing = true;
        return '';
      }
      return i.apiKey;
    });
    return missing ? null : out;
  }

  /// The indexer a kept link names first (credited in statistics), or null.
  static String? linkIndexer(String stored) => _keyRef.firstMatch(stored)?[1];

  static String _gb(int bytes) => '${(bytes / 1073741824).toStringAsFixed(2)} GB';

  /// What a result says of [r]: its name (`4K Remux • DV HDR10+ • HEVC • T1`, or `Usenet`
  /// when its name says nothing), its description (the release's name when
  /// [showReleaseNames], then audio, languages, size, bitrate, age, indexer, and the release
  /// group when names are hidden), and the size its badge shows (a pack's per episode, once
  /// known). [profile]: the sorting profile in use (its tier is named); [seasonEpisodes]: each
  /// season's episode count; [runtimeMinutes]: the film's or episode's runtime;
  /// [sizeBadges]: sizes show as badges, so an episode's or a film's isn't repeated.
  static ({String name, String description, int? videoSize}) describe(
    UsenetRelease r, {
    required bool showReleaseNames,
    RankingProfile? profile,
    Map<int, int>? seasonEpisodes,
    int? runtimeMinutes,
    bool sizeBadges = false,
  }) {
    final f = r.facts;
    final l = r.labels;
    final pixels = f.resolution > 0 ? f.resolution : r.resolution;
    final resolution = pixels >= 2160 ? '4K' : (pixels > 0 ? '${pixels}p' : null);
    final video = [?resolution, ?l.service, ?f.quality.label].join(' ');
    final visual = [
      if (f.visual.contains('DV')) 'DV',
      if (f.visual.contains('HDR10_PLUS')) 'HDR10+' else if (f.visual.contains('HDR')) 'HDR',
    ].join(' ');
    final codec = f.codec == 'UNKNOWN' ? '' : f.codec;
    final tierIndex = profile?.tierOf(f) ?? -1;
    final tier = tierIndex >= 0 ? 'T${tierIndex + 1}' : '';
    final nameParts = [video, visual, codec, tier].where((s) => s.isNotEmpty).toList();
    final pack = r.seasonPack;
    final share = r.episodeSize(seasonEpisodes);
    final shareKnown = pack && r.size > 0 && r.episodeShareKnown(seasonEpisodes) && share != r.size;
    final details = [
      ?l.audio,
      ?l.languagesLabel,
      ?sizeLabel(r, seasonEpisodes, sizeBadges: sizeBadges),
      ?bitrateLabel(shareKnown ? share : (pack ? 0 : r.size), runtimeMinutes, pack: pack),
      ?ageLabel(r),
      if (r.indexerName.trim().isNotEmpty) r.indexerName,
      if (!showReleaseNames) ?l.group,
    ].join(' • ');
    final videoSize = shareKnown ? share : r.size;
    return (
      name: nameParts.isEmpty ? 'Usenet' : nameParts.join(' • '),
      description: [if (showReleaseNames) r.title, if (details.isNotEmpty) details].join('\n'),
      videoSize: videoSize > 0 ? videoSize : null,
    );
  }

  /// The size on a result's details line: a pack says it is one, with an episode's share once
  /// its seasons are counted. [sizeBadges]: the size shows as a badge, so an episode's or a
  /// film's isn't repeated.
  static String? sizeLabel(UsenetRelease r, Map<int, int>? seasonEpisodes, {bool sizeBadges = false}) {
    if (r.size <= 0) return null;
    if (!r.seasonPack) return sizeBadges ? null : _gb(r.size);
    final share = r.episodeSize(seasonEpisodes);
    final whole = r.packSeasons.length == 1 ? 'season' : 'pack';
    if (share != r.size && r.episodeShareKnown(seasonEpisodes)) return '${_gb(r.size)} whole $whole (~${_gb(share)} per episode)';
    return '${_gb(r.size)} (whole $whole)';
  }

  /// `7.5 Mbps`, `72 Mbps` (`~` for a pack's episode), shown between 0.1 and 150 Mbps only:
  /// beyond, the runtime isn't this release's.
  static String? bitrateLabel(int bytes, int? minutes, {bool pack = false}) {
    if (minutes == null || minutes <= 0 || bytes <= 0) return null;
    final mbps = bytes * 8 / (minutes * 60) / 1e6;
    if (mbps < 0.1 || mbps > 150) return null;
    return '${pack ? '~' : ''}${mbps < 10 ? mbps.toStringAsFixed(1) : mbps.toStringAsFixed(0)} Mbps';
  }

  /// `3d`: days since it was posted, when known.
  static String? ageLabel(UsenetRelease r) {
    if (r.publishedAt <= 0) return null;
    final d = (UsenetClock.nowMs() - r.publishedAt) ~/ 86400000;
    return '${d < 0 ? 0 : d}d';
  }

  // ── what is searched ──

  static const _animePrefixes = {'kitsu', 'mal', 'anilist', 'anidb'};
  static final _imdbId = RegExp(r'^tt\d+$');

  /// An anime catalog's id for [t] (its prefix, id, and for an episode the catalog's number),
  /// or null when [t] isn't one.
  static ({String prefix, String id, int? episode})? _animeIdOf(AddonTarget t, {required bool series}) {
    for (final v in [t.video, t.raw]) {
      if (v == null) continue;
      final parts = v.trim().split(':');
      if (parts.length < 2 || !_animePrefixes.contains(parts[0].toLowerCase()) || int.tryParse(parts[1]) == null) continue;
      final prefix = parts[0].toLowerCase();
      if (!series) return parts.length == 2 ? (prefix: prefix, id: parts[1], episode: null) : null;
      if (parts.length == 3) {
        final n = int.tryParse(parts[2]);
        return n == null ? null : (prefix: prefix, id: parts[1], episode: n);
      }
      if (parts.length == 2 && t.video == null && t.episode != null) return (prefix: prefix, id: parts[1], episode: t.episode);
    }
    final k = t.kitsu;
    if (t.anime && k != null) return (prefix: 'kitsu', id: '$k', episode: series ? t.episode : null);
    return null;
  }

  /// [t] on IMDb (and TheTVDB) with their numbering, for an anime catalog's id; null when
  /// nothing maps it (it isn't searched then: the catalog's own numbers would name another
  /// episode).
  static Future<({String? imdb, String? tvdb, int? season, int? episode})?> _animeEquivalent(AddonTarget t, ({String prefix, String id, int? episode}) a, {required bool series}) async {
    bool numbered(int? s, int? e) => s != null && s >= 0 && e != null && e >= 1;
    // 1. the title's own IMDb id
    final raw = t.raw?.trim();
    if (raw != null && _imdbId.hasMatch(raw)) {
      if (!series) return (imdb: raw, tvdb: null, season: null, episode: null);
      if (numbered(t.imdbSeason, t.imdbEpisode)) return (imdb: raw, tvdb: null, season: t.imdbSeason, episode: t.imdbEpisode);
      if (numbered(t.season, t.episode)) return (imdb: raw, tvdb: null, season: t.season, episode: t.episode);
    }
    // 2. its details' IMDb id and numbering
    final imdb = t.imdb != null && _imdbId.hasMatch(t.imdb!) ? t.imdb : null;
    if (imdb != null) {
      if (!series) return (imdb: imdb, tvdb: null, season: null, episode: null);
      if (raw != null && numbered(t.imdbSeason, t.imdbEpisode)) return (imdb: imdb, tvdb: null, season: t.imdbSeason, episode: t.imdbEpisode);
    }
    // 3. the anime databases' mapping
    Map<String, dynamic>? j;
    try {
      j = await animeMapping(a.prefix, a.id).timeout(animeWait);
    } catch (_) {
      j = null;
    }
    if (j == null) return null;
    final ids = j['mappings'] is Map ? j['mappings'] as Map : const {};
    final mapped = '${ids['imdb_id'] ?? ''}'.trim();
    final found = imdb ?? (_imdbId.hasMatch(mapped) ? mapped : null);
    final tvdbId = int.tryParse('${ids['thetvdb_id'] ?? ''}');
    if (!series) return found == null ? null : (imdb: found, tvdb: null, season: null, episode: null);
    final n = a.episode;
    final episodes = j['episodes'] is Map ? j['episodes'] as Map : const {};
    final e = n == null ? null : episodes['$n'];
    if (e is! Map) return null;
    final s = (e['seasonNumber'] as num?)?.toInt(), ep = (e['episodeNumber'] as num?)?.toInt();
    if (!numbered(s, ep) || (found == null && tvdbId == null)) return null;
    return (imdb: found, tvdb: tvdbId?.toString(), season: s, episode: ep);
  }
}

typedef _SeriesLookup = ({int? id, Map<String, dynamic>? details});

/// One search of one title with one configuration: running, or finished and kept.
class _Session {
  _Session(this.addon, this.target, this.config);
  final Addon addon;
  final AddonTarget target;
  final UsenetSources config;

  final _done = Completer<UsenetResults?>();
  final _listeners = <void Function(List<AddonStream>)>[];
  List<AddonStream>? _latest;
  int? _finishedAt;
  bool _cancelled = false;

  bool get finished => _done.isCompleted;

  /// Finished with something listed, within the time a search is reused.
  bool get reusable {
    final at = _finishedAt;
    return at != null && (_latest?.isNotEmpty ?? false) && UsenetClock.nowMs() - at <= UsenetSearch.reuseFor.inMilliseconds;
  }

  void cancel() => _cancelled = true;

  Future<UsenetResults?> attach(void Function(List<AddonStream>)? onSome) async {
    if (onSome == null) return _done.future;
    final latest = _latest;
    if (latest != null && !finished) onSome(latest);
    _listeners.add(onSome);
    try {
      return await _done.future;
    } finally {
      _listeners.remove(onSome);
    }
  }

  void start() {
    unawaited(
      _Run(this).run().then(
        (r) {
          _finishedAt = UsenetClock.nowMs();
          if (!_done.isCompleted) _done.complete(r);
        },
        onError: (Object _) {
          _finishedAt = UsenetClock.nowMs();
          if (!_done.isCompleted) _done.complete((streams: _latest ?? const <AddonStream>[], failures: const <String>[]));
        },
      ),
    );
  }

  void _emit(List<AddonStream> streams) {
    _latest = streams;
    for (final l in [..._listeners]) {
      try {
        l(streams);
      } catch (_) {}
    }
  }
}

class _Answer {
  _Answer(this.indexer, this.found, this.failure);
  final UsenetIndexer indexer;
  final List<UsenetRelease>? found;
  final String? failure;
}

class _Cooldown implements Exception {
  _Cooldown(this.until);
  final int until;
}

class _Event {
  const _Event(this.name);
  final String name;
}

const _waitOver = _Event('wait over');
const _counted = _Event('counted');
const _factsKnown = _Event('facts known');

/// The work of one search.
class _Run {
  _Run(this.session)
      : config = session.config,
        target = session.target,
        series = session.target.type.toLowerCase() != 'movie';

  final _Session session;
  final UsenetSources config;
  final AddonTarget target;
  final bool series;
  final _nz = Newznab.instance;

  String get kind => series ? 'show' : 'movie';
  bool cancelled() => session._cancelled;

  late UsenetSearchRequest base;

  /// The numbering searched with, which the engine picks a pack's file by.
  int? searchedSeason, searchedEpisode;
  String? lookupImdb, lookupTvdb;

  late final Future<_SeriesLookup?>? seriesLookup;
  late final Future<UsenetSearchRequest?> metadata;
  UsenetSearchRequest? _metadataValue;
  bool _metadataDone = false;
  int? runtime;

  /// A series' details, when they came within a few seconds of the start: which series of its
  /// name each release is.
  UsenetSearchRequest? facts;
  bool factsDone = false;
  Future<void>? factsLookup;

  /// Each season's episode count, once a pack was found and TMDB answered in time.
  Map<int, int>? counts;
  bool countsDone = false;
  Future<void>? countsLookup;

  final releases = <UsenetRelease>[];
  final failures = <String>[];
  List<AddonStream> shown = const [];

  Future<UsenetResults?> run() async {
    if (!await _plan()) return null;
    seriesLookup = series ? _lookSeriesUp().catchError((Object _) => null) : null;
    metadata = _metadata().then(
      (m) {
        _metadataValue = m;
        _metadataDone = true;
        return m;
      },
      onError: (Object _) {
        final m = _fallback();
        _metadataValue = m;
        _metadataDone = true;
        return m;
      },
    );
    if (series) {
      factsLookup = metadata.timeout(UsenetSearch.lookupWait, onTimeout: () => null).then((m) {
        facts = m;
        factsDone = true;
      }, onError: (Object _) => factsDone = true);
    }
    final enabled = [for (final i in config.indexers) if (i.enabled) i];
    final tiers = <List<UsenetIndexer>>[];
    if (config.indexerFallback) {
      for (final p in {for (final i in enabled) i.priority}.toList()..sort()) {
        tiers.add([for (final i in enabled) if (i.priority == p) i]);
      }
    } else {
      tiers.add(enabled);
    }
    for (var n = 0; n < tiers.length; n++) {
      if (cancelled()) break;
      await _tier(tiers[n]);
      if (n == tiers.length - 1 || _arranged().isNotEmpty) break;
    }
    return (streams: shown, failures: failures);
  }

  // ── what is asked ──

  Future<bool> _plan() async {
    final t = target;
    final anime = UsenetSearch._animeIdOf(t, series: series);
    if (anime != null) {
      final eq = await UsenetSearch._animeEquivalent(t, anime, series: series);
      if (eq == null) return false;
      lookupImdb = eq.imdb;
      lookupTvdb = eq.tvdb;
      base = UsenetSearchRequest(imdbId: eq.imdb, tvdbId: series ? eq.tvdb : null, season: eq.season, episode: eq.episode, series: series);
      if (series) {
        searchedSeason = eq.season;
        searchedEpisode = eq.episode;
      }
      return !series || (eq.season != null && eq.episode != null);
    }
    final imdb = t.imdb != null && UsenetSearch._imdbId.hasMatch(t.imdb!.trim()) ? t.imdb!.trim() : null;
    final tmdb = t.tmdb != null && t.tmdb! > 0 ? '${t.tmdb}' : null;
    if (imdb == null && tmdb == null && (t.title?.trim().isEmpty ?? true)) return false;
    final season = series ? (t.imdbSeason ?? t.season) : null;
    final episode = series ? (t.imdbEpisode ?? t.episode) : null;
    if (series && (season == null || season < 0 || episode == null || episode < 1)) return false;
    lookupImdb = imdb;
    base = UsenetSearchRequest(imdbId: imdb, tmdbId: tmdb, season: season, episode: episode, series: series);
    searchedSeason = season;
    searchedEpisode = episode;
    return true;
  }

  /// The title's TMDB id: its own, or found by its IMDb or TheTVDB id.
  Future<int?> _tmdbId() async {
    final own = int.tryParse(base.tmdbId ?? '');
    if (own != null) return own;
    for (final (id, source) in [(lookupImdb, 'imdb_id'), (lookupTvdb, 'tvdb_id')]) {
      if (id == null) continue;
      final j = await UsenetSearch.tmdbGet('/find/$id', {'external_source': source});
      final list = j[series ? 'tv_results' : 'movie_results'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final n = ((list.first as Map)['id'] as num?)?.toInt();
        if (n != null) return n;
      }
    }
    return null;
  }

  Future<_SeriesLookup?> _lookSeriesUp() async {
    final int? id;
    try {
      id = await _tmdbId();
    } catch (_) {
      return null;
    }
    if (id == null) return (id: null, details: null);
    Map<String, dynamic>? details;
    try {
      details = await UsenetSearch.tmdbGet('/tv/$id', {'append_to_response': 'external_ids'});
    } catch (_) {
      details = null;
    }
    return (id: id, details: details);
  }

  static int? _year(Object? date) => date is String && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
  static String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// A request by title when TMDB can't be asked: the title's own name and year.
  UsenetSearchRequest? _fallback() {
    final title = _text(target.title);
    if (title == null) return null;
    return UsenetSearchRequest(
      imdbId: base.imdbId,
      tmdbId: base.tmdbId,
      tvdbId: base.tvdbId,
      title: title,
      year: target.year,
      season: base.season,
      episode: base.episode,
      series: series,
    );
  }

  /// The title's names, years and ids from TMDB.
  Future<UsenetSearchRequest?> _metadata() async {
    Map<String, dynamic>? details, movie;
    int? id;
    if (series) {
      final lookup = await seriesLookup!;
      if (lookup == null) return _fallback();
      id = lookup.id;
      details = lookup.details;
    } else {
      id = await _tmdbId();
      if (id == null) return _fallback();
      movie = await UsenetSearch.tmdbGet('/movie/$id', {'append_to_response': 'alternative_titles,translations,external_ids'});
    }
    final info = movie ?? details;
    final external = info?['external_ids'] is Map ? info!['external_ids'] as Map : const {};
    final foundImdb = _text(external['imdb_id']);
    final imdb = base.imdbId ?? (foundImdb != null && UsenetSearch._imdbId.hasMatch(foundImdb) ? foundImdb : null);
    final title = _text(movie?['title']) ?? _text(details?['title']) ?? _text(details?['name']) ?? _text(target.title);
    Future<List<UsenetNamesake>?>? namesakes;
    if (series && title != null) {
      namesakes = () async {
        try {
          final j = await UsenetSearch.tmdbGet('/search/tv', {'query': title});
          final results = j['results'] is List ? j['results'] as List : const [];
          return [
            for (final r in results.whereType<Map>())
              if ((r['id'] as num?)?.toInt() != id && (sameName(_text(r['name']), title) || sameName(_text(r['original_name']), title)))
                UsenetNamesake(
                  year: _year(r['first_air_date']),
                  countries: [for (final c in (r['origin_country'] as List? ?? const [])) '$c'],
                  votes: (r['vote_count'] as num?)?.toInt() ?? 0,
                ),
          ];
        } catch (_) {
          return null;
        }
      }();
    }
    final tvdb = series ? (base.tvdbId ?? (external['tvdb_id'] == null ? null : '${external['tvdb_id']}')) : null;
    final original = _text(movie?['original_title']) ?? _text(details?['original_title']) ?? _text(details?['original_name']);
    List<String>? others;
    if (movie != null) {
      final alt = movie['alternative_titles'] is Map ? (movie['alternative_titles'] as Map)['titles'] : null;
      final tr = movie['translations'] is Map ? (movie['translations'] as Map)['translations'] : null;
      if (alt is List && tr is List) {
        others = <String>[];
        for (final x in [
          for (final a in alt.whereType<Map>()) _text(a['title']),
          for (final x in tr.whereType<Map>()) x['data'] is Map ? _text((x['data'] as Map)['title']) : null,
        ]) {
          if (x != null && !others.contains(x)) others.add(x);
        }
      }
    }
    final year = _year(movie?['release_date']) ?? _year(details?['release_date']) ?? _year(details?['first_air_date']) ?? target.year;
    int? seasonYear;
    for (final s in (details?['seasons'] as List? ?? const []).whereType<Map>()) {
      if ((s['season_number'] as num?)?.toInt() == base.season) seasonYear = _year(s['air_date']);
    }
    final runs = details?['episode_run_time'];
    final last = details?['last_episode_to_air'];
    runtime = (movie?['runtime'] as num?)?.toInt() ??
        (runs is List && runs.isNotEmpty ? (runs.first as num?)?.toInt() : null) ??
        (last is Map ? (last['runtime'] as num?)?.toInt() : null);
    return UsenetSearchRequest(
      imdbId: imdb,
      tmdbId: id?.toString() ?? base.tmdbId,
      tvdbId: tvdb,
      title: title,
      originalTitle: original != null && title != null && original.toLowerCase() != title.toLowerCase() ? original : null,
      otherTitles: others,
      year: year,
      seasonYear: seasonYear,
      lastYear: _year(details?['last_air_date']),
      countries: [for (final c in (details?['origin_country'] as List? ?? const [])) '$c'],
      namesakes: namesakes == null ? null : await namesakes,
      votes: (details?['vote_count'] as num?)?.toInt(),
      season: base.season,
      episode: base.episode,
      series: series,
    );
  }

  /// Each season's episode count, asked once the first pack shows up; never waited for long.
  void _countSeasons() {
    final lookup = seriesLookup;
    if (lookup == null || countsLookup != null) return;
    countsLookup = lookup
        .then((l) {
          final out = <int, int>{};
          for (final s in (l?.details?['seasons'] as List? ?? const []).whereType<Map>()) {
            final n = (s['season_number'] as num?)?.toInt(), c = (s['episode_count'] as num?)?.toInt();
            if (n != null && c != null && c > 0) out[n] = c;
          }
          return out.isEmpty ? null : out;
        })
        .timeout(UsenetSearch.lookupWait, onTimeout: () => null)
        .then((c) {
          counts = c;
          countsDone = true;
        }, onError: (Object _) => countsDone = true);
  }

  // ── one indexer ──

  List<UsenetRelease> _seriesChecked(List<UsenetRelease> found) {
    final show = facts ?? (_metadataDone ? _metadataValue : null);
    if (show == null) return found;
    return seriesResultsOf(show, found, (r) => r.title, (r) => r.packSeasons);
  }

  Future<List<UsenetRelease>> _confirmed(List<UsenetRelease> found) async {
    if (found.isEmpty) return found;
    UsenetSearchRequest? movie;
    try {
      movie = await metadata.timeout(UsenetSearch.lookupWait, onTimeout: () => null);
    } catch (_) {
      movie = null;
    }
    if (movie == null) return found;
    return filmResultsOf(movie, found, (r) => r.title);
  }

  Future<List<UsenetRelease>> _clientSearch(UsenetIndexer i, UsenetSearchRequest r, NewznabCaps caps, int limit) async {
    try {
      return await _nz.search(i, r, caps, limit, kind: kind, cancelled: cancelled);
    } on NewznabFailure catch (e) {
      if (e.kind == NewznabFailureKind.cooldown) throw _Cooldown(e.blockedUntil);
      rethrow;
    }
  }

  /// Asks again when a search found nothing: by title after an id search (thin coverage),
  /// then by the original title (Latin script only), each only when the ones before found
  /// nothing.
  Future<List<UsenetRelease>?> _askAgain(UsenetIndexer i, UsenetSearchRequest searched, NewznabCaps caps, int limit) async {
    final url = Newznab.searchUrl(i, searched, caps);
    if (url == null) return null;
    final md = await metadata;
    if (md == null) return null;
    final byTitle = md.withoutIds();
    final original = md.originalTitle;
    final attempts = [
      if (Newznab.isIdSearch(url)) byTitle,
      if (original != null && hasLatinLetter(original)) byTitle.named(original, md.title),
    ];
    for (final a in attempts) {
      if (Newznab.searchUrl(i, a, caps) == null) continue;
      try {
        var found = await _clientSearch(i, a, caps, limit);
        if (series) found = _seriesChecked(found);
        if (found.isNotEmpty) return found;
      } on _Cooldown {
        rethrow;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<_Answer> _searchIndexer(UsenetIndexer i) async {
    try {
      final NewznabCaps caps;
      try {
        caps = await _nz.capabilities(i);
      } on NewznabFailure catch (e) {
        if (e.kind == NewznabFailureKind.cooldown) throw _Cooldown(e.blockedUntil);
        rethrow;
      }
      final canSearchId = Newznab.searchUrl(i, base, caps) != null;
      final request = canSearchId ? base : await metadata;
      if (request == null) throw StateError('Metadata unavailable');
      final limit = config.fetchFor(i);
      var found = await _clientSearch(i, request, caps, limit);
      if (series) {
        found = _seriesChecked(found);
      } else if (canSearchId) {
        found = await _confirmed(found);
      }
      if (found.isEmpty) found = await _askAgain(i, request, caps, limit) ?? found;
      found = [for (final r in found) r.searchedAs(season: searchedSeason, episode: searchedEpisode, series: series)];
      _record(i, 'answered', found);
      return _Answer(i, found, null);
    } on _Cooldown catch (e) {
      _record(i, 'paused', const []);
      return _Answer(i, null, '${i.name}: indexer limit reached, paused until ${Newznab.clock(DateTime.fromMillisecondsSinceEpoch(e.until))}.');
    } catch (_) {
      _record(i, 'failed', const []);
      return _Answer(i, null, '${i.name}: indexer search failed. Check the API URL, key and limits.');
    }
  }

  void _record(UsenetIndexer i, String outcome, List<UsenetRelease> found) {
    try {
      UsenetSearch.onSearch?.call(i.id, kind, outcome, found.length, [for (final r in found) r.nzbUrl]);
    } catch (_) {}
  }

  // ── the list ──

  List<UsenetRelease> _listed() {
    final f = series ? facts : null;
    if (f == null) return releases;
    return withoutNamesakeReleases(f, seriesResultsOf(f, releases, (r) => r.title, (r) => r.packSeasons), (r) => r.title, (r) => r.packSeasons);
  }

  bool _factsChangeList() => _listed().length != releases.length;

  List<UsenetRelease> _arranged() {
    final servers = config.serverUrls;
    final ranks = <String, int>{};
    for (final r in releases) {
      final posted = r.publishedAt > 0 ? r.publishedAt : null;
      final o = UsenetReleases.outcome(nzbUrl: r.nzbUrl, title: r.title, size: r.size, servers: servers, posted: posted);
      final blank = !o.failed && !o.played && (UsenetReleases.sibling(title: r.title, servers: servers, posted: posted)?.blank ?? false);
      ranks[r.nzbUrl] = o.failed || blank ? 2 : (o.played && config.availableFirst ? 0 : 1);
    }
    var listed = _listed();
    if (config.hideDuplicates) listed = UsenetArrange.withoutDuplicates(listed, config, seasonEpisodes: counts, series: series);
    return UsenetArrange.arrange(listed, config, seasonEpisodes: counts, series: series, rank: (r) => ranks[r.nzbUrl] ?? 1);
  }

  void _show() {
    final arranged = _arranged();
    if (arranged.isEmpty) return;
    final profile = RankingPresets.active(config);
    shown = [for (final r in arranged) _stream(r, profile)];
    session._emit(shown);
  }

  Future<void> _tier(List<UsenetIndexer> tier) async {
    final events = StreamController<Object>();
    void add(Object e) {
      if (!events.isClosed) events.add(e);
    }

    var pending = tier.length;
    for (final i in tier) {
      unawaited(_searchIndexer(i).then(add));
    }
    var waiting = !config.progressiveResults;
    final timer = waiting ? Timer(UsenetSearch.partialWait, () => add(_waitOver)) : null;
    var countsShown = false, factsShown = false;
    var countsWatched = false;
    void watchCounts() {
      final c = countsLookup;
      if (c == null || countsWatched || countsDone) return;
      countsWatched = true;
      unawaited(c.then((_) => add(_counted)));
    }

    watchCounts();
    final facts = factsLookup;
    if (facts != null && !factsDone) unawaited(facts.then((_) => add(_factsKnown)));
    final it = StreamIterator(events.stream);
    try {
      while (pending > 0 && !cancelled() && await it.moveNext()) {
        final e = it.current;
        if (identical(e, _waitOver)) {
          waiting = false;
          _show();
        } else if (identical(e, _counted)) {
          countsShown = true;
          if (!waiting && counts != null) _show();
        } else if (identical(e, _factsKnown)) {
          factsShown = true;
          if (!waiting && _factsChangeList()) _show();
        } else if (e is _Answer) {
          pending--;
          final failure = e.failure;
          if (failure != null) {
            failures.add(failure);
          } else {
            releases.addAll(e.found!);
            if (releases.any((r) => r.packSeasons.isNotEmpty)) {
              _countSeasons();
              watchCounts();
            }
            if (!waiting) _show();
          }
        }
      }
      timer?.cancel();
      if (cancelled()) return;
      if (waiting) _show();
      final c = countsLookup;
      if (!countsShown && c != null && !countsDone) {
        await c;
        if (counts != null) _show();
      }
      final f = factsLookup;
      if (!factsShown && f != null && !factsDone) {
        await f;
        if (_factsChangeList()) _show();
      }
    } finally {
      timer?.cancel();
      unawaited(it.cancel());
      unawaited(events.close());
    }
  }

  // ── a release as a stream ──

  AddonStream _stream(UsenetRelease r, RankingProfile? profile) {
    final d = UsenetSearch.describe(r, showReleaseNames: config.showReleaseNames, profile: profile, seasonEpisodes: counts, runtimeMinutes: runtime);
    return AddonStream(
      addon: session.addon,
      url: '',
      text: d.description.isEmpty ? d.name : '${d.name}\n${d.description}',
      name: d.name,
      description: d.description,
      filename: r.title,
      bingeGroup: UsenetSearch.bingeGroupOf(r.title, series: series),
      sizeBytes: d.videoSize,
      nzbUrl: r.nzbUrl,
      usenetRelease: r,
    );
  }
}
