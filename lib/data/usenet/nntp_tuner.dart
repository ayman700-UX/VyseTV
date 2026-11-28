// Settings > Usenet > a provider's "Tune connections": how many connections the account accepts
// from this network, which of the provider's ports is fastest from here, and how many
// connections reach full speed. It downloads real test articles (a public speed-test post) the
// way the engine does while playing: the same sign-in, the same addresses, the same number of
// requests in flight per connection.
//
// Nothing is saved here: the dialog offers the result and saves it only when you apply it.
// Playback never runs it, and it counts in no statistics. Only categories leave this file, as
// with Test provider: raw errors can echo a password back.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'nntp.dart';
import 'usenet_sources.dart';

/// What a run is busy with.
enum TunePhase {
  /// Signing in more and more connections, all held, until the provider refuses one.
  limit,

  /// Measuring the speed on each of the provider's ports.
  port,

  /// Measuring the speed with more and more connections on the port chosen.
  connections,
}

/// One speed measured: on [port] (with or without TLS), with the [connections] that actually
/// signed in.
class TuneReading {
  const TuneReading({required this.port, required this.tls, required this.connections, required this.mbps});
  final int port;
  final bool tls;
  final int connections;

  /// Megabits a second (decimal).
  final double mbps;

  @override
  String toString() => 'Port $port, $connections connections: ${mbps.toStringAsFixed(0)} Mbps';
}

/// Where a run is: [phase] null before anything was measured (connecting).
class TuneProgress {
  const TuneProgress({this.phase, this.count = 0, this.port, this.tls, this.readings = const []});
  final TunePhase? phase;

  /// [TunePhase.limit]: connections accepted so far; otherwise the connections being measured.
  final int count;
  final int? port;
  final bool? tls;
  final List<TuneReading> readings;
}

/// Why a run ended without a result.
enum TuneFailure {
  /// No connection signed in ([TuneFailed.result] says how it failed, as Test provider would).
  connect,

  /// The test post's list of articles couldn't be downloaded.
  testData,

  /// The provider lacks the test articles, so no speed can be measured.
  missingArticles,

  /// Too little arrived to measure a speed.
  tooSlow,
}

/// How a run ended.
sealed class TuneOutcome {
  const TuneOutcome(this.readings);

  /// Every speed measured, on every port, in order.
  final List<TuneReading> readings;
}

/// A result: what to set, and what was found on the way.
final class TuneSucceeded extends TuneOutcome {
  const TuneSucceeded({
    required this.limit,
    required this.tried,
    required this.port,
    required this.tls,
    required this.connections,
    required this.fastestConnections,
    required this.mbps,
    required this.downloadedBytes,
    required List<TuneReading> readings,
  }) : super(readings);

  /// The connections the account accepted before it refused one; null when none was refused.
  final int? limit;

  /// Connections tried for the limit (the limit and the one refused, or as many as were held).
  final int tried;

  /// The port and TLS setting to use.
  final int port;
  final bool tls;

  /// The connection allowance to use: raised only when clearly faster, lowered only to stay
  /// under the limit.
  final int connections;

  /// The fewest connections within 95% of the best speed.
  final int fastestConnections;

  /// The speed at [connections] (or the nearest count measured below it).
  final double mbps;

  /// NNTP bytes received in all (the test post's NZB not counted).
  final int downloadedBytes;

  /// The mean speed of the readings at [fastestConnections] on the port chosen.
  double get fastestMbps {
    final at = [for (final r in readings) if (r.port == port && r.tls == tls && r.connections == fastestConnections) r.mbps];
    return at.isEmpty ? 0 : at.reduce((a, b) => a + b) / at.length;
  }

  /// Whether it says to change anything of [p].
  bool differsFrom(UsenetProvider p) => p.port != port || p.tls != tls || p.connections != connections;
}

final class TuneFailed extends TuneOutcome {
  const TuneFailed(this.failure, {this.result, List<TuneReading> readings = const []}) : super(readings);
  final TuneFailure failure;

  /// For [TuneFailure.connect]: how the connection failed.
  final NntpResult? result;
}

/// Stopped before a result: nothing was changed.
final class TuneStopped extends TuneOutcome {
  const TuneStopped([super.readings = const []]);
}

/// Stops a run: the dialog's Stop, Back, or the dialog going away.
class TuneCancel {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// How long each part of a run takes (tests shorten them).
class TuneTiming {
  const TuneTiming({
    this.step = const Duration(milliseconds: 8000),
    this.warmup = const Duration(milliseconds: 1500),
    this.settle = const Duration(milliseconds: 2500),
    this.minStep = const Duration(milliseconds: 3000),
    this.poll = const Duration(milliseconds: 100),
    this.readTimeout = const Duration(seconds: 15),
    this.signOutWait = const Duration(seconds: 2),
    this.signIn = const Duration(seconds: 10),
    this.minDrainMs = 3000,
    this.maxDrainMs = 15000,
  });

  /// The measured window of a step.
  final Duration step;

  /// Downloading before the window starts (not measured).
  final Duration warmup;

  /// The pause after a step, so the provider has counted its connections closed.
  final Duration settle;

  /// The least a step runs before it may end early with enough data.
  final Duration minStep;
  final Duration poll;

  /// The longest wait for a reply while downloading.
  final Duration readTimeout;

  /// The longest wait for the goodbyes of idle connections signed out together.
  final Duration signOutWait;

  /// Each connection's time to connect (all of the provider's addresses), and its longest
  /// wait for each reply while signing in: as Test provider.
  final Duration signIn;
  final int minDrainMs;
  final int maxDrainMs;
}

class NntpTuner {
  NntpTuner({this.timing = const TuneTiming(), this.testNzbUrl = defaultTestNzb, this.userAgent = 'VyseTV/dev', Random? random}) : _random = random ?? Random();

  final TuneTiming timing;

  /// The test post's NZB: a public speed-test upload of about 1 GB.
  final String testNzbUrl;

  /// What the NZB download says it is (always the app's own, never a custom one).
  final String userAgent;
  final Random _random;

  static const defaultTestNzb = 'https://sabnzbd.org/tests/test_download_1GB.nzb';
  static const probeCap = 100;
  static const maxProbe = 200;
  static const probeBatch = 8;
  static const portConnections = 8;
  static const goodEnough = .95;
  static const portWin = 1.10;
  static const gain = 1.03;
  static const ladder = [4, 8, 12, 16, 24, 32, 48, 64, 80, 100, 128, 160, 200];
  static const maxStepBytes = 262144000;
  static const minArticles = 50;
  static const missingSample = 10;
  static const testNzbMaxBytes = 4 * 1024 * 1024;

  // one run at a time: a new one waits until the last has let all its connections go
  static Future<void> _tail = Future.value();

  /// Measures [provider] (its saved values) and answers what to set. [depth]: requests in flight
  /// per connection, as the engine keeps them (2 for Low memory, else 4). Stopped through
  /// [cancel], it signs everything out properly first and answers [TuneStopped].
  Future<TuneOutcome> run(UsenetProvider provider, {required bool allowPrivate, required int depth, void Function(TuneProgress progress)? onProgress, TuneCancel? cancel}) {
    final before = _tail;
    final done = Completer<void>();
    _tail = done.future;
    final c = cancel ?? TuneCancel();
    return () async {
      await before;
      try {
        return await _Run(this, provider, allowPrivate: allowPrivate, depth: max(1, depth), onProgress: onProgress, cancel: c).go();
      } finally {
        done.complete();
      }
    }();
  }

  // ── the rules, by themselves ──

  /// How many connections the limit check goes up to: at least 100, at most 200.
  static int probeCapFor(int allowance) => min(max(probeCap, allowance), maxProbe);

  /// Connections that may be used: the limit less a tenth (at least one less), or as many as
  /// were held when no limit was found.
  static int usableFor(int? limit, int tried) => limit == null ? tried : max(1, limit - max(1, limit ~/ 10));

  /// The ports to measure: the saved one first, then 563 and 443 for TLS (a TLS provider never
  /// moves to a plain port), or 119 without.
  static List<(int, bool)> portsFor(int port, bool tls) {
    final out = <(int, bool)>[(port, tls)];
    for (final p in tls ? const [(563, true), (443, true)] : const [(119, false)]) {
      if (!out.contains(p)) out.add(p);
    }
    return out;
  }

  /// The connection counts to measure: the ladder below [usable], then [usable].
  static List<int> ladderFor(int usable) => [
    for (final n in ladder)
      if (n < usable) n,
    usable,
  ];

  /// Whether more connections stopped paying: the last two each below 3% over the best before it.
  static bool stopsRising(List<double> rising) {
    if (rising.length < 3) return false;
    bool flat(int k) => rising[k] < gain * rising.sublist(0, k).reduce(max);
    return flat(rising.length - 1) && flat(rising.length - 2);
  }

  /// The mean speed per connection count.
  static Map<int, double> averages(Iterable<TuneReading> readings) {
    final sums = <int, (double, int)>{};
    for (final r in readings) {
      final s = sums[r.connections] ?? (0.0, 0);
      sums[r.connections] = (s.$1 + r.mbps, s.$2 + 1);
    }
    return {for (final e in sums.entries) e.key: e.value.$1 / e.value.$2};
  }

  /// The fewest connections whose mean is within 95% of the best mean; null when nothing was
  /// fast at all.
  static int? fastest(Iterable<TuneReading> readings) {
    final avg = averages(readings);
    if (avg.isEmpty) return null;
    final best = avg.values.reduce(max);
    if (best <= 0) return null;
    final counts = avg.keys.toList()..sort();
    return counts.firstWhere((n) => avg[n]! >= best * goodEnough);
  }

  /// The allowance to recommend. Raised to [fastest] only when the saved [allowance] was clearly
  /// slower in both the first readings ([initial]) and the repeats; with a [limit], kept under
  /// it; never lowered otherwise (unused connections cost nothing and help seeks).
  static int recommend({required int allowance, required int fastest, required int? limit, required int tried, required Map<int, double> initial, required Map<int, double> repeats}) {
    bool faster(Map<int, double> m) {
      final a = m[allowance], f = m[fastest];
      return a != null && f != null && a < f * goodEnough;
    }

    final wanted = fastest > allowance && faster(initial) && faster(repeats) ? fastest : allowance;
    return limit == null ? wanted : min(wanted, usableFor(limit, tried));
  }

  /// How long the end of a step may wait for the replies still due: twice what is in flight at
  /// the speed measured, 3 to 15 s.
  static int drainBudgetMs(int sessions, int depth, double avgBodyBytes, double bytesPerSecond, {int minMs = 3000, int maxMs = 15000}) {
    if (sessions <= 0 || depth <= 0 || avgBodyBytes <= 0 || bytesPerSecond <= 0 || !avgBodyBytes.isFinite || !bytesPerSecond.isFinite) return minMs;
    final ms = 2 * sessions * depth * avgBodyBytes / bytesPerSecond * 1000;
    return ms.round().clamp(minMs, maxMs);
  }

  /// The article ids an NZB names, in order: each segment's text, trimmed, without its < >.
  static List<String> messageIds(String nzb) {
    String text(String s) =>
        s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
    return [
      for (final m in RegExp(r'<segment\b[^>]*>([\s\S]*?)</segment>').allMatches(nzb))
        if (text(m.group(1)!).trim().replaceAll(RegExp(r'^<|>$'), '').trim() case final id when id.isNotEmpty) id,
    ];
  }

  /// The test post's article ids; empty when it couldn't be had (anything but a 2xx, nothing in
  /// it, more than 4 MiB).
  Future<List<String>> fetchTestIds(TuneCancel cancel) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = userAgent;
    unawaited(cancel.whenCancelled.then((_) => client.close(force: true)));
    try {
      final req = await client.getUrl(Uri.parse(testNzbUrl)).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode > 299) {
        unawaited(res.drain<void>().catchError((Object _) {}));
        return const [];
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        body.add(chunk);
        if (body.length > testNzbMaxBytes) return const [];
      }
      if (body.isEmpty) return const [];
      return messageIds(utf8.decode(body.takeBytes(), allowMalformed: true));
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}

/// A run stopped by the user (thrown to unwind; everything is let go on the way).
class _Stopped implements Exception {}

/// A run that can't go on.
class _Failed implements Exception {
  _Failed(this.failure, [this.result]);
  final TuneFailure failure;
  final NntpResult? result;
}

/// One connection opened, or how it failed.
typedef _Opened = ({NntpSession? session, NntpResult? failure});

class _Run {
  _Run(this.tuner, this.provider, {required this.allowPrivate, required this.depth, required this.onProgress, required this.cancel});
  final NntpTuner tuner;
  final UsenetProvider provider;
  final bool allowPrivate;
  final int depth;
  final void Function(TuneProgress)? onProgress;
  final TuneCancel cancel;

  TuneTiming get t => tuner.timing;

  late List<InternetAddress> _addresses;
  List<String> _ids = const [];
  int _counter = 0;
  final _readings = <TuneReading>[];
  int _downloaded = 0;

  // how the last step went
  TuneFailure? _stepFailure;
  NntpResult? _stepResult;

  bool get _cancelled => cancel.cancelled;

  void _checkCancel() {
    if (_cancelled) throw _Stopped();
  }

  void _report(TunePhase? phase, int count, {int? port, bool? tls}) =>
      onProgress?.call(TuneProgress(phase: phase, count: count, port: port, tls: tls, readings: List.unmodifiable(_readings)));

  final _sleepers = <Completer<void>>{};

  /// Waits [d], or less when the run is stopped meanwhile.
  Future<void> _sleep(Duration d) async {
    if (d <= Duration.zero || _cancelled) return;
    final done = Completer<void>();
    _sleepers.add(done);
    final timer = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    timer.cancel();
    _sleepers.remove(done);
  }

  void _wakeSleepers() {
    for (final s in [..._sleepers]) {
      if (!s.isCompleted) s.complete();
    }
  }

  NntpTarget _target(int port, bool tls) => NntpTarget(host: provider.host, port: port, tls: tls, username: provider.username, password: provider.password);

  String _nextId() => _ids[_counter++ % _ids.length];

  Future<TuneOutcome> go() async {
    unawaited(cancel.whenCancelled.then((_) => _wakeSleepers()));
    try {
      return await _go();
    } on _Stopped {
      return TuneStopped(List.unmodifiable(_readings));
    } on _Failed catch (f) {
      return TuneFailed(f.failure, result: f.result, readings: List.unmodifiable(_readings));
    }
  }

  Future<TuneOutcome> _go() async {
    _report(null, 0);
    try {
      _addresses = await dialableAddresses(provider.host, allowPrivate: allowPrivate);
    } on NntpFailure catch (f) {
      throw _Failed(TuneFailure.connect, f.result);
    }
    _checkCancel();
    final testIds = tuner.fetchTestIds(cancel);

    // 1. the connection limit, on the saved port
    final allowance = provider.connections;
    final (limit, tried) = await _probeLimit(_target(provider.port, provider.tls), NntpTuner.probeCapFor(allowance));
    await _sleep(t.settle);
    _checkCancel();

    // 2. the test articles
    _ids = await testIds;
    _checkCancel();
    if (_ids.length < NntpTuner.minArticles) throw _Failed(TuneFailure.testData);
    _counter = tuner._random.nextInt(_ids.length);
    final usable = NntpTuner.usableFor(limit, tried);

    // 3. the port
    for (final (port, tls) in NntpTuner.portsFor(provider.port, provider.tls)) {
      final r = await _measure(TunePhase.port, port, tls, min(NntpTuner.portConnections, usable));
      if (r == null && _stepFailure == TuneFailure.missingArticles) throw _Failed(TuneFailure.missingArticles);
    }
    final lastFailure = _stepFailure, lastResult = _stepResult;
    final working = [for (final r in _readings) if (r.mbps > 0) r];
    if (working.isEmpty) throw _Failed(lastFailure ?? TuneFailure.tooSlow, lastFailure == TuneFailure.connect ? lastResult : null);
    final count = working.map((r) => r.connections).reduce(min);
    final comparable = <(int, bool), TuneReading>{};
    for (final w in working) {
      final key = (w.port, w.tls);
      if (w.connections == count) {
        comparable.putIfAbsent(key, () => w);
        continue;
      }
      final again = await _measure(TunePhase.port, w.port, w.tls, count);
      if (again != null && again.connections == count) comparable[key] = again;
    }
    final saved = (provider.port, provider.tls);
    var chosen = saved;
    if (comparable.containsKey(saved) || !working.any((r) => (r.port, r.tls) == saved)) {
      final best = comparable.values.reduce((a, b) => b.mbps > a.mbps ? b : a);
      final mine = comparable[saved];
      chosen = mine != null && best.mbps < mine.mbps * NntpTuner.portWin ? saved : (best.port, best.tls);
    }
    final (port, tls) = chosen;

    // 4. more and more connections on it
    final rising = <double>[];
    for (final n in NntpTuner.ladderFor(usable)) {
      final r = await _measure(TunePhase.connections, port, tls, n);
      rising.add(r?.mbps ?? 0);
      if (r == null && _stepFailure == TuneFailure.connect) break;
      if (NntpTuner.stopsRising(rising)) break;
    }
    List<TuneReading> onPort() => [for (final r in _readings) if (r.port == port && r.tls == tls) r];
    if (allowance <= usable && !onPort().any((r) => r.connections == allowance)) {
      await _measure(TunePhase.connections, port, tls, allowance);
    }

    // 5. the decision
    final initial = NntpTuner.averages(onPort());
    final candidate = NntpTuner.fastest(onPort());
    if (candidate == null) throw _Failed(TuneFailure.tooSlow);
    final repeats = <int, double>{};
    if (candidate > allowance && initial.containsKey(allowance)) {
      for (final n in [allowance, candidate]) {
        final r = await _measure(TunePhase.connections, port, tls, n);
        if (r != null && r.connections == n) repeats[n] = r.mbps;
      }
    }
    final last = onPort();
    final fastestFinal = NntpTuner.fastest(last);
    if (fastestFinal == null) throw _Failed(TuneFailure.tooSlow);
    final recommended = NntpTuner.recommend(allowance: allowance, fastest: fastestFinal, limit: limit, tried: tried, initial: initial, repeats: repeats);
    final avg = NntpTuner.averages(last);
    final below = (avg.keys.where((n) => n < recommended).toList()..sort()).lastOrNull;
    final mbps = avg[recommended] ?? (below != null ? avg[below] : null) ?? avg[fastestFinal]!;
    return TuneSucceeded(
      limit: limit,
      tried: tried,
      port: port,
      tls: tls,
      connections: recommended,
      fastestConnections: fastestFinal,
      mbps: mbps,
      downloadedBytes: _downloaded,
      readings: List.unmodifiable(_readings),
    );
  }

  /// Signs in [probeCap] connections at most, eight at a time, all held, until the provider
  /// refuses one. The limit counts only when the provider said so (refused) both in the batch
  /// and in one more try; timeouts and lost greetings leave it unknown.
  Future<(int?, int)> _probeLimit(NntpTarget target, int cap) async {
    final held = <NntpSession>[];
    int? limit;
    try {
      while (held.length < cap) {
        _checkCancel();
        _report(TunePhase.limit, held.length);
        final batch = await _openMany(target, min(NntpTuner.probeBatch, cap - held.length));
        held.addAll([for (final o in batch) if (o.session != null) o.session!]);
        final failures = [for (final o in batch) if (o.failure != null) o.failure!];
        if (failures.isEmpty) continue;
        if (held.isEmpty) throw _Failed(TuneFailure.connect, failures.first);
        final retry = (await _openMany(target, 1)).single;
        if (retry.session != null) {
          held.add(retry.session!);
          continue;
        }
        if (retry.failure == NntpResult.refused && failures.contains(NntpResult.refused)) limit = held.length;
        break;
      }
    } finally {
      await _signOut(held);
    }
    return (limit, limit != null ? limit + 1 : held.length);
  }

  /// Opens [n] connections at once. When the run is stopped meanwhile, those not signed in
  /// yet are closed, those that did are signed out, and the run stops.
  Future<List<_Opened>> _openMany(NntpTarget target, int n) async {
    _checkCancel();
    final abort = NntpAbort();
    unawaited(cancel.whenCancelled.then((_) => abort.abort()));
    final opened = await Future.wait([
      for (var i = 0; i < n; i++)
        NntpSession.open(target, _addresses, budget: t.signIn, readTimeout: t.signIn, abort: abort).then<_Opened>(
          (s) => (session: s, failure: null),
          onError: (Object e) => (session: null, failure: e is NntpFailure ? e.result : NntpResult.unreachable),
        ),
    ]);
    if (_cancelled) {
      await _signOut([for (final o in opened) if (o.session != null) o.session!]);
      throw _Stopped();
    }
    return opened;
  }

  /// Says goodbye on every idle connection at once, then waits for the goodbyes (2 s in all)
  /// and closes them: a provider counts a connection closed without QUIT for minutes.
  Future<void> _signOut(List<NntpSession> sessions) async {
    if (sessions.isEmpty) return;
    for (final s in sessions) {
      s.trySend('QUIT');
    }
    final clock = Stopwatch()..start();
    await Future.wait([
      for (final s in sessions)
        () async {
          final left = t.signOutWait - clock.elapsed;
          if (left > Duration.zero) {
            s.readTimeout = left;
            try {
              await s.line();
            } catch (_) {}
          }
          s.close();
        }(),
    ]);
  }

  /// One measuring step: [n] connections on [port], downloading test articles with [depth]
  /// requests each in flight; a warm-up, then the measured window. Null with [_stepFailure]
  /// when nothing could be measured.
  Future<TuneReading?> _measure(TunePhase phase, int port, bool tls, int n) async {
    _stepFailure = null;
    _stepResult = null;
    _checkCancel();
    _report(phase, n, port: port, tls: tls);
    final opened = await _openMany(_target(port, tls), n);
    final sessions = [for (final o in opened) if (o.session != null) o.session!];
    if (sessions.isEmpty) {
      _stepFailure = TuneFailure.connect;
      _stepResult = opened.first.failure;
      await _sleep(t.settle);
      _checkCancel();
      return null;
    }
    final step = _Step(sessions, depth, _nextId, t.readTimeout)..start();
    TuneReading? reading;
    var bps = 0.0;
    try {
      await _sleep(t.warmup);
      if (!_cancelled) {
        final startBytes = step.received;
        final clock = Stopwatch()..start();
        while (true) {
          await _sleep(t.poll);
          if (_cancelled) break;
          final e = clock.elapsed;
          if (e >= t.step || (e >= t.minStep && step.received - startBytes >= NntpTuner.maxStepBytes) || step.alive == 0) break;
        }
        clock.stop();
        if (!_cancelled) {
          final seconds = clock.elapsedMicroseconds / 1e6;
          final bytes = step.received - startBytes;
          bps = seconds > 0 ? bytes / seconds : 0;
          if (step.answered >= NntpTuner.missingSample && step.missing * 2 > step.answered) {
            _stepFailure = TuneFailure.missingArticles;
          } else if (bytes <= 0 || seconds <= 0) {
            _stepFailure = TuneFailure.tooSlow;
          } else {
            reading = TuneReading(port: port, tls: tls, connections: sessions.length, mbps: bytes * 8 / 1e6 / seconds);
            _readings.add(reading);
            _report(phase, n, port: port, tls: tls);
          }
        }
      }
    } finally {
      final stoppedBefore = _cancelled;
      final budget = stoppedBefore
          ? t.minDrainMs
          : NntpTuner.drainBudgetMs(sessions.length, depth, step.received / max(1, step.bodies), bps, minMs: t.minDrainMs, maxMs: t.maxDrainMs);
      final (spent, clean) = await step.end(Duration(milliseconds: budget), stoppedBefore ? null : cancel);
      _downloaded += step.received;
      final rest = clean ? t.settle - spent : t.settle;
      await _sleep(rest);
    }
    _checkCancel();
    return reading;
  }
}

/// The downloads of one step: a worker per connection, each keeping [depth] BODY requests in
/// flight over the test post's articles.
class _Step {
  _Step(this.sessions, this.depth, this.next, this.readTimeout);
  final List<NntpSession> sessions;
  final int depth;
  final String Function() next;
  final Duration readTimeout;

  int received = 0, bodies = 0, answered = 0, missing = 0, alive = 0;
  bool _ending = false;
  final _workers = <Future<void>>[];

  void start() {
    for (final s in sessions) {
      s.readTimeout = readTimeout;
      alive++;
      _workers.add(_work(s).whenComplete(() => alive--));
    }
  }

  Future<void> _work(NntpSession s) async {
    var quitting = false;
    try {
      s.sendAll([for (var i = 0; i < depth; i++) 'BODY <${next()}>']);
      while (true) {
        final line = await s.line();
        answered++;
        final code = line.length >= 3 ? int.tryParse(line.substring(0, 3)) : null;
        if (code == 222) {
          await s.drainBody(onBytes: (n) => received += n);
          bodies++;
        } else if (code == 430 || code == 423) {
          missing++;
        } else {
          return; // the goodbye, or an error (400, 480, 502, …)
        }
        if (quitting) continue;
        if (_ending) {
          // after the requests still due
          s.send('QUIT');
          quitting = true;
        } else {
          s.send('BODY <${next()}>');
        }
      }
    } catch (_) {
      // the connection closed, timed out, or the step's end closed it
    }
  }

  /// Ends the step: each worker says goodbye after its next reply and reads what is still due;
  /// those not done within [budget] (or when [cancel] comes) are cut off. Answers the time the
  /// wait took and whether every worker finished in it.
  Future<(Duration, bool)> end(Duration budget, TuneCancel? cancel) async {
    _ending = true;
    final clock = Stopwatch()..start();
    var clean = false;
    final waited = Completer<void>();
    void stop() {
      if (!waited.isCompleted) waited.complete();
    }

    final timer = Timer(budget, stop);
    unawaited(Future.wait(_workers).then((_) {
      if (!waited.isCompleted) clean = true;
      stop();
    }));
    if (cancel != null) unawaited(cancel.whenCancelled.then((_) => stop()));
    await waited.future;
    timer.cancel();
    final spent = clock.elapsed;
    for (final s in sessions) {
      s.close();
    }
    await Future.wait([for (final w in _workers) w.timeout(const Duration(seconds: 1), onTimeout: () {})]);
    return (spent, clean);
  }
}
