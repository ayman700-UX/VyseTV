// Playing a release from Usenet: the engine's open request made from a stream and your
// settings, the time it may take, the automatic fallback to the next Usenet results, and what
// is said when it doesn't play.

import 'dart:async';
import 'dart:convert';

import '../app_settings.dart';
import '../sources/addons.dart';
import '../updates/updater.dart';
import 'usenet_engine.dart';
import 'usenet_release.dart';
import 'usenet_sources.dart';
import 'usenet_stats.dart' show UsenetStartupTrace;

class UsenetPlay {
  UsenetPlay._();

  /// VyseTV's own User-Agent, `VyseTV/<version>` ("dev" before the version is known): sent on
  /// NZB downloads and indexer searches unless Settings > Usenet names another.
  static String get defaultUserAgent {
    final v = Updater.instance.current.trim();
    return 'VyseTV/${v.isEmpty ? 'dev' : v}';
  }

  /// What NZB downloads say they are.
  static String get downloadUserAgent {
    final s = AppSettings.usenetDownloadUserAgent.value.trim();
    return s.isNotEmpty && validUserAgent(s) ? s : defaultUserAgent;
  }

  /// What indexer searches say they are.
  static String get searchUserAgent {
    final s = AppSettings.usenetSearchUserAgent.value.trim();
    return s.isNotEmpty && validUserAgent(s) ? s : defaultUserAgent;
  }

  /// At most 256 printable ASCII characters on one line.
  static bool validUserAgent(String s) => s.length <= 256 && RegExp(r'^[\x20-\x7E]*$').hasMatch(s);

  /// The engine settings each open carries, in range.
  static Map<String, Object?> config() {
    final missing = AppSettings.usenetMaxMissing.value.clamp(1, 50);
    return {
      'profile': const ['low-memory', 'balanced', 'throughput'].contains(AppSettings.usenetProfile.value) ? AppSettings.usenetProfile.value : 'balanced',
      'readAhead': AppSettings.usenetReadAhead.value.clamp(0, 512),
      'maxConnections': AppSettings.usenetMaxConnections.value.clamp(0, 4096),
      'fastMkvStartup': AppSettings.usenetFastMkv.value,
      'fastNzbFetch': AppSettings.usenetFastNzb.value,
      'cacheNzb': AppSettings.usenetCacheNzb.value,
      'allowPrivateNetwork': AppSettings.usenetAllowPrivate.value,
      'holeFilling': AppSettings.usenetHoleFilling.value,
      'maxMissingArticles': missing,
      'maxConsecutiveMissing': AppSettings.usenetMaxConsecutiveMissing.value.clamp(1, missing < 10 ? missing : 10),
    };
  }

  /// The providers [s] is read from: the addon's own, or yours (Settings > Usenet), in the
  /// hierarchy's order.
  static List<String> serversFor(AddonStream s) => s.usenetServers.isNotEmpty ? s.usenetServers : UsenetSourcesStore.current.value.serverUrls;

  /// The engine's open request for [s]. [season]/[episode]: the episode being played (a release
  /// found by an episode search carries its own, which win).
  static Map<String, Object?> request(AddonStream s, {int? season, int? episode}) {
    final r = s.usenetRelease is UsenetRelease ? s.usenetRelease as UsenetRelease : null;
    final se = r?.season ?? season, ep = r?.episode ?? episode;
    final headers = {...s.headers};
    if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) headers['User-Agent'] = downloadUserAgent;
    return {
      'cacheScope': 'unscoped',
      'nzbUrl': s.nzbUrl,
      'servers': serversFor(s),
      'headers': headers,
      'fileIdx': ?s.fileIdx,
      'fileMustInclude': ?s.fileMustInclude,
      if (ep != null && ep > 0) ...{'season': se ?? 0, 'episode': ep},
      'config': config(),
    };
  }

  /// Opens [s] in the engine within [allowance], and keeps what came of it: a release that is
  /// gone or damaged is remembered (listed last, never tried by itself again), one that opened
  /// counts as available.
  ///
  /// [trace]: the steps it took, for Settings > Usenet > Diagnostics.
  static Future<UsenetSession> open(AddonStream s, {int? season, int? episode, Duration allowance = const Duration(seconds: 120), UsenetStartupTrace? trace}) async {
    if (!UsenetEngine.supported) throw UsenetEngineError('Usenet engine is missing for this device', scope: UsenetFailureScope.engine);
    if (serversFor(s).isEmpty) {
      throw UsenetEngineError('No Usenet provider is set up. Add one in Settings > Usenet.', scope: UsenetFailureScope.engine, kind: 'provider');
    }
    trace?.mark('resolve_lock_acquired');
    // opened ahead on the sources list (Prefetch results): taken as it is, if still fresh
    final ahead = _takePrefetched(s, season, episode);
    if (ahead != null) {
      try {
        final session = await ahead.timeout(allowance);
        if (UsenetEngine.instance.owned == session.id) {
          trace
            ?..mark('prepared_session_reused')
            ..mark('engine_ready')
            ..mark('session_request')
            ..mark('session_response');
          onOpened?.call(s, session);
          return session;
        }
      } catch (_) {}
    }
    try {
      trace?.mark(UsenetEngine.instance.running ? 'engine_reused' : 'engine_starting');
      await UsenetEngine.instance.base();
      trace
        ?..mark('engine_ready')
        ..mark('session_request');
      final session = await UsenetEngine.instance.open(request(s, season: season, episode: episode), timeout: allowance);
      trace?.mark('session_response');
      onOpened?.call(s, session);
      return session;
    } on UsenetEngineError catch (e) {
      if (e.releaseIsBad) unplayable(s, e.kind!);
      rethrow;
    }
  }

  /// Statistics listen (Settings > Usenet > Statistics): a release opened in the engine, showed
  /// its first frame, or was found gone or damaged on your providers.
  static void Function(AddonStream s, UsenetSession session)? onOpened;
  static void Function(AddonStream s)? onPlayed;
  static void Function(AddonStream s, String kind)? onUnplayable;

  /// [s] showed its first frame: it plays with your providers.
  static void played(AddonStream s) {
    UsenetReleases.played(s);
    onPlayed?.call(s);
  }

  /// [s] is gone or damaged on your providers ([kind], the engine's word): remembered, listed
  /// last as UNAVAILABLE, never tried by itself again.
  static void unplayable(AddonStream s, String kind) {
    UsenetReleases.failed(s, kind);
    onUnplayable?.call(s, kind);
  }

  // ── Prefetch results (Settings > Usenet, off unless turned on) ──

  /// How long a release opened ahead is kept for a pick.
  static const prefetchFor = Duration(seconds: 120);

  static ({String key, Future<UsenetSession> session, DateTime at})? _prefetched;

  static String _prefetchKey(AddonStream s, int? season, int? episode) => '${UsenetFallback._key(s)}|${season ?? ''}|${episode ?? ''}|${jsonEncode(config())}';

  /// Opens [s] (the first Usenet result on the sources list) before it is picked, so picking it
  /// plays at once. Only with Prefetch results on, and only while nothing of ours is open in the
  /// engine (never under a video that plays). Failures are silent, but a release found gone is
  /// remembered as such.
  static void prefetch(AddonStream s, {int? season, int? episode}) {
    if (!AppSettings.usenetPrefetch.value || !UsenetEngine.supported || !s.usenet || serversFor(s).isEmpty) return;
    final key = _prefetchKey(s, season, episode);
    final p = _prefetched;
    if (p != null && p.key == key && DateTime.now().difference(p.at) < prefetchFor) return;
    if (UsenetEngine.instance.owned != null && UsenetEngine.instance.owned != _prefetchedId) return;
    final f = UsenetEngine.instance.open(request(s, season: season, episode: episode), timeout: const Duration(seconds: 60), ahead: true);
    _prefetched = (key: key, session: f, at: DateTime.now());
    f.then(
      (x) {
        if (_prefetched?.session == f) _prefetchedId = x.id;
      },
      onError: (Object e) {
        if (_prefetched?.session == f) _prefetched = null;
        if (e is UsenetEngineError && e.releaseIsBad) unplayable(s, e.kind!);
      },
    );
  }

  static String? _prefetchedId;

  static Future<UsenetSession>? _takePrefetched(AddonStream s, int? season, int? episode) {
    final p = _prefetched;
    if (p == null) return null;
    _prefetched = null;
    _prefetchedId = null;
    // (another release picked: its open calls the one ahead off, or lets it go once ready)
    return p.key == _prefetchKey(s, season, episode) && DateTime.now().difference(p.at) < prefetchFor ? p.session : null;
  }

  /// The sources list closed, or something else was picked: a release opened ahead and never
  /// played goes.
  static void cancelPrefetch() {
    final p = _prefetched;
    _prefetched = null;
    _prefetchedId = null;
    if (p == null) return;
    unawaited(UsenetEngine.instance.abortAhead());
    p.session.then((x) {
      if (UsenetEngine.instance.owned == x.id) unawaited(UsenetEngine.instance.release(x.id));
    }, onError: (Object _) {});
  }

  /// A few words for a failure, for lines like `<reason>. Trying the next…`.
  static String shortReason(Object e) {
    if (e is UsenetEngineError) {
      final k = e.kind;
      switch (k) {
        case 'missing-article':
          return 'Articles missing on your providers';
        case 'hole-limit':
          return 'Too many missing articles';
        case 'invalid-article':
          return 'Damaged articles';
        case 'provider-authentication':
          return 'Provider sign-in failed';
        case 'provider-quota':
          return 'Provider quota reached';
        case 'provider':
          return 'Provider unavailable';
        case 'blank-content':
          return 'Empty release';
      }
      if (e.message.contains('timed out')) return 'Took too long to open';
      final first = e.message.split('\n').first.trim();
      return first.length > 80 ? '${first.substring(0, 79)}…' : first;
    }
    if (e is TimeoutException) return 'Took too long to open';
    return 'Usenet stream could not be opened';
  }

  /// What the player says when a release stopped for good, by the engine's failure kind.
  static String? explanation(String? kind) => switch (kind) {
    'missing-article' || 'hole-limit' => 'This release is missing parts on your Usenet provider (removed, or an incomplete upload). Try another release.',
    'invalid-article' => "Parts of this release are damaged on your Usenet provider, or packed in a way that can't be streamed. Try another release.",
    'provider-authentication' => "Your Usenet provider refused the sign-in. Check its username and password in Settings > Usenet.",
    'provider-quota' => "Your Usenet provider's download quota is used up. Check your account with the provider.",
    'blank-content' => 'This release has no real video in it. Try another release.',
    _ => null,
  };

  /// What Stream info says of a Usenet release while it plays, from the engine's diagnostics:
  /// the release, the providers that served it (most bytes first; each with how much of what it
  /// was asked it had, when more than one was asked and some lacked articles), how complete it
  /// is, how soon the first provider answers, errors, and what stopped it.
  static Map<String, String> liveFacts(UsenetSession u, Map<String, Object?> d) {
    int n(Map<Object?, Object?> m, String k) => (m[k] as num?)?.toInt() ?? 0;
    String pct(int ok, int missing) => ok + missing == 0 ? '' : '${(ok * 100 / (ok + missing)).toStringAsFixed(1)}%';
    final mine = UsenetSourcesStore.current.value.providers;
    String nameOf(int i) {
      if (i < 0 || i >= u.servers.length) return '?';
      final url = u.servers[i];
      final p = mine.where((p) => p.serverUrl == url).firstOrNull;
      if (p != null && p.name.trim().isNotEmpty) return p.name.trim();
      final host = Uri.tryParse(url)?.host ?? '';
      return host.isEmpty ? '?' : host;
    }

    final asked = [
      for (final r in (d['providers'] as List? ?? const []).whereType<Map<Object?, Object?>>())
        if (n(r, 'articles') + n(r, 'missing') + n(r, 'errors') > 0) r,
    ];
    final byBytes = [...asked]..sort((a, b) => n(b, 'bytes').compareTo(n(a, 'bytes')));
    final inOrder = [...asked]..sort((a, b) => n(a, 'server').compareTo(n(b, 'server')));
    final someMissing = asked.any((r) => n(r, 'missing') > 0);
    final served = asked.fold(0, (t, r) => t + n(r, 'articles'));
    // (an article falls down your providers in order: what the last one asked lacked, none had)
    final missing = inOrder.isEmpty ? 0 : n(inOrder.last, 'missing');
    final filled = (d['filledArticles'] as num?)?.toInt() ?? 0;
    final ttfb = inOrder.map((r) => (r['ttfbMs'] as num?)?.toDouble() ?? 0).where((x) => x > 0).firstOrNull;
    final errors = asked.fold(0, (t, r) => t + n(r, 'errors'));
    final kind = '${d['streamFailure'] ?? ''}';
    final size = u.size;
    return {
      'Release': u.filename,
      if (size > 0) 'Size': size >= 1e9 ? '${(size / 1e9).toStringAsFixed(2)} GB' : '${(size / 1e6).round()} MB',
      'Providers': [
        for (final r in byBytes) asked.length > 1 && someMissing ? '${nameOf(n(r, 'server'))} ${pct(n(r, 'articles'), n(r, 'missing'))}' : nameOf(n(r, 'server')),
      ].join(', '),
      if (served + missing > 0) 'Articles': '${pct(served, missing)}  ($missing missing${filled > 0 ? ', $filled filled' : ''})',
      if (ttfb != null) 'First byte': '${ttfb.round()} ms',
      if (errors > 0) 'Errors': '$errors · ${[for (final r in asked) if (n(r, 'errors') > 0) nameOf(n(r, 'server'))].join(', ')}',
      if (kind.isNotEmpty) 'Stopped': shortReason(UsenetEngineError('', kind: kind)),
    };
  }

  /// The kinds that end a release for good while it plays.
  static const permanentKinds = {'missing-article', 'hole-limit', 'invalid-article', 'provider-authentication', 'provider-quota', 'blank-content'};
}

/// The automatic fallback after a Usenet release that won't play (Settings > Usenet > Automatic
/// Usenet fallback, off unless turned on): the Usenet results listed after the one picked, in
/// the list's order, never back to the top. At most [AppSettings.usenetFallbackMax] of them,
/// within two minutes of opening in all (the first pick 60 s, each next one 30 s); the time
/// spent watching doesn't count.
class UsenetFallback {
  UsenetFallback(List<AddonStream> shown, AddonStream picked) : _queue = _after(shown, picked) {
    _attempted.add(_key(picked));
  }

  static List<AddonStream> _after(List<AddonStream> list, AddonStream picked) {
    final at = list.indexWhere((s) => identical(s, picked));
    final i = at >= 0 ? at : list.indexWhere((s) => _key(s) == _key(picked));
    return i >= 0 ? list.sublist(i + 1) : list;
  }

  final List<AddonStream> _queue;
  final _attempted = <String>{};
  final _failedProviders = <String>{};
  bool _engineFailed = false;
  int attempts = 0;
  Duration spent = Duration.zero;
  String? lastFailure;
  String? lastReason;

  static const total = Duration(seconds: 120);
  static const first = Duration(seconds: 60);
  static const each = Duration(seconds: 30);

  /// Whether a fallback is on for this pick at all (read again each time: turning it off stops
  /// it).
  bool get enabled => AppSettings.usenetFallback.value;

  /// The time the next preparation may take.
  Duration allowance({required bool initial}) {
    if (!enabled) return total;
    final left = total - spent;
    final per = initial ? first : each;
    return left < per ? left : per;
  }

  static String _key(AddonStream s) {
    final servers = [...UsenetPlay.serversFor(s)]..sort();
    final headers = s.headers.entries.map((e) => '${e.key}=${e.value}').toList()..sort();
    return 'nzb:${s.nzbUrl}|${s.fileIdx ?? ''}|${s.fileMustInclude ?? ''}|${headers.join('&')}|${servers.join(',')}';
  }

  static String _providersOf(AddonStream s) => ([...UsenetPlay.serversFor(s)]..sort()).join(',');

  bool _eligible(AddonStream s) =>
      s.usenet && s.playable && !_attempted.contains(_key(s)) && !_failedProviders.contains(_providersOf(s)) && !UsenetReleases.isUnplayable(s);

  bool get canAdvance =>
      enabled && !_engineFailed && spent < total && attempts < AppSettings.usenetFallbackMax.value.clamp(1, 50) && _queue.any(_eligible);

  /// The next release to try, or null.
  AddonStream? next() {
    if (!canAdvance) return null;
    final s = _queue.firstWhere(_eligible);
    _attempted.add(_key(s));
    attempts++;
    return s;
  }

  /// [s] failed to open with [e] after [took]: what that says about the rest.
  void failed(AddonStream s, Object e, Duration took) {
    spent += took;
    lastFailure = e is UsenetEngineError ? e.message : 'Usenet preparation failed';
    lastReason = UsenetPlay.shortReason(e);
    if (e is UsenetEngineError) {
      if (e.scope == UsenetFailureScope.engine) _engineFailed = true;
      if (e.scope == UsenetFailureScope.provider) _failedProviders.add(_providersOf(s));
    }
  }

  /// [s] opened after [took].
  void opened(Duration took) => spent += took;

  /// "Damaged articles. Trying the next release (2)…"
  String nextMessage() {
    final r = lastReason?.replaceAll(RegExp(r'[.\s]+$'), '');
    return r == null || r.isEmpty ? 'Trying the next release ($attempts)…' : '$r. Trying the next release ($attempts)…';
  }

  /// Why nothing played.
  String get failureMessage => spent >= total ? 'Usenet preparation time budget exhausted: ${lastFailure ?? ''}'.trim() : (lastFailure ?? 'Usenet stream could not be opened');

  // ── from the sources list to the player ──

  static final _handoff = <String, UsenetFallback>{};

  /// The list [picked] was chosen from, for the player to carry on down (the sources page sets
  /// it as the pick is made).
  static void hand(List<AddonStream> shown, AddonStream picked) {
    if (!picked.usenet) return;
    _handoff[_key(picked)] = UsenetFallback(shown, picked);
    while (_handoff.length > 8) {
      _handoff.remove(_handoff.keys.first);
    }
  }

  /// The fallback made for [picked] on the sources list, or a fresh one with nothing after it.
  static UsenetFallback take(AddonStream picked) => _handoff.remove(_key(picked)) ?? UsenetFallback(const [], picked);
}
