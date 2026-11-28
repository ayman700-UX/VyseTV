// The automatic Usenet fallback (Settings > Usenet > Automatic Usenet fallback) and the engine's
// open request: which releases are tried after one that won't play, in what order, within what
// time, and what is said meanwhile.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/usenet_engine.dart';
import 'package:vyse_tv/data/usenet/usenet_play.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

const _addon = Addon(manifestUrl: 'https://addon.test/manifest.json', id: 'test', name: 'Test');

AddonStream nzb(String n, {List<String> servers = const [], int? fileIdx}) =>
    AddonStream(addon: _addon, url: '', text: n, name: n, nzbUrl: 'https://indexer.test/get/$n.nzb', usenetServers: servers, fileIdx: fileIdx);

AddonStream http(String n) => AddonStream(addon: _addon, url: 'https://cdn.test/$n.mkv', text: n, name: n);

AddonStream torrent(String n) => AddonStream(addon: _addon, url: '', text: n, name: n, infoHash: n.padRight(40, '0'));

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    await UsenetReleases.load();
    UsenetSourcesStore.debugSet(
      UsenetSources(
        providers: [UsenetProvider(id: 'p1', name: 'Main', host: 'news.test', port: 563, tls: true, username: 'u', password: 'p', connections: 8, enabled: true, priority: 1)],
      ),
    );
  });

  setUp(() {
    AppSettings.usenetFallback.set(true);
    AppSettings.usenetFallbackMax.set(5);
  });

  test('is off unless turned on, and then the one pick gets the whole two minutes', () {
    AppSettings.usenetFallback.set(false);
    final a = nzb('a'), b = nzb('b');
    final fb = UsenetFallback([a, b], a);
    expect(fb.enabled, isFalse);
    expect(fb.allowance(initial: true), const Duration(seconds: 120));
    expect(fb.next(), isNull);
  });

  test('carries on after the pick, in the list order, never back to the top', () {
    final l = [nzb('a'), nzb('b'), nzb('c'), nzb('d')];
    final fb = UsenetFallback(l, l[1]);
    expect(fb.next()?.name, 'c');
    expect(fb.next()?.name, 'd');
    expect(fb.next(), isNull);
  });

  test('a pick missing from the list starts at the first result', () {
    final l = [nzb('a'), nzb('b')];
    final fb = UsenetFallback(l, nzb('elsewhere'));
    expect(fb.next()?.name, 'a');
  });

  test('torrents and links between Usenet results are passed over', () {
    final l = [nzb('a'), torrent('t'), http('h'), nzb('b')];
    final fb = UsenetFallback(l, l[0]);
    expect(fb.next()?.name, 'b');
    expect(fb.next(), isNull);
  });

  test('the same release listed twice is tried once; another file of it is another try', () {
    final a = nzb('a');
    final l = [a, nzb('a'), nzb('a', fileIdx: 2), nzb('b')];
    final fb = UsenetFallback(l, a);
    expect(fb.next()?.fileIdx, 2);
    expect(fb.next()?.name, 'b');
    expect(fb.next(), isNull);
  });

  test('five tries by default even with a hundred results, at most fifty', () {
    final l = [for (var i = 0; i < 100; i++) nzb('r$i')];
    var fb = UsenetFallback(l, l[0]);
    var n = 0;
    while (fb.next() != null) {
      n++;
    }
    expect(n, 5);
    AppSettings.usenetFallbackMax.set(80);
    fb = UsenetFallback(l, l[0]);
    n = 0;
    while (fb.next() != null) {
      n++;
    }
    expect(n, 50);
  });

  test('one budget: 60 s for the pick, 30 s each after, 120 s in all; watching is free', () {
    final l = [for (var i = 0; i < 6; i++) nzb('r$i')];
    final fb = UsenetFallback(l, l[0]);
    expect(fb.allowance(initial: true), const Duration(seconds: 60));
    fb.failed(l[0], UsenetEngineError('Usenet source preparation timed out'), const Duration(seconds: 60));
    expect(fb.lastReason, 'Took too long to open');
    expect(fb.next()?.name, 'r1');
    expect(fb.allowance(initial: false), const Duration(seconds: 30));
    fb.failed(l[1], UsenetEngineError('Usenet source preparation timed out'), const Duration(seconds: 30));
    expect(fb.next()?.name, 'r2');
    fb.failed(l[2], UsenetEngineError('Usenet source preparation timed out'), const Duration(seconds: 30));
    expect(fb.canAdvance, isFalse);
    expect(fb.failureMessage, startsWith('Usenet preparation time budget exhausted'));

    final watched = UsenetFallback(l, l[0]);
    watched.opened(const Duration(seconds: 5));
    // (an hour of watching later, the release stops: the budget is what opening took)
    expect(watched.allowance(initial: false), const Duration(seconds: 30));
  });

  test('a provider failure skips that account, not another; an engine failure ends it', () {
    final other = ['nntps://x:y@news.other.test:563/8'];
    final l = [nzb('a'), nzb('b'), nzb('c', servers: other)];
    final fb = UsenetFallback(l, l[0]);
    fb.failed(l[0], UsenetEngineError('refused', kind: 'provider', scope: UsenetFailureScope.provider), const Duration(seconds: 2));
    expect(fb.lastReason, 'Provider unavailable');
    expect(fb.next()?.name, 'c');

    final g = UsenetFallback(l, l[0]);
    g.failed(l[0], UsenetEngineError('Usenet engine could not start', scope: UsenetFailureScope.engine), const Duration(seconds: 1));
    expect(g.next(), isNull);
    expect(g.failureMessage, 'Usenet engine could not start');
  });

  test('a release known to be gone from your providers is skipped', () {
    final l = [nzb('a'), nzb('gone'), nzb('c')];
    UsenetPlay.unplayable(l[1], 'missing-article');
    final fb = UsenetFallback(l, l[0]);
    expect(fb.next()?.name, 'c');
  });

  test('turning it off stops the next replacement', () {
    final l = [nzb('a'), nzb('b'), nzb('c')];
    final fb = UsenetFallback(l, l[0]);
    expect(fb.next()?.name, 'b');
    AppSettings.usenetFallback.set(false);
    expect(fb.next(), isNull);
  });

  test('what is said on the next try, by the engine\'s failure kind', () {
    final l = [nzb('a'), nzb('b')];
    String said(String kind) {
      final fb = UsenetFallback(l, l[0]);
      fb.failed(l[0], UsenetEngineError('x', kind: kind), const Duration(seconds: 1));
      fb.next();
      return fb.nextMessage();
    }

    expect(said('missing-article'), 'Articles missing on your providers. Trying the next release (1)…');
    expect(said('hole-limit'), 'Too many missing articles. Trying the next release (1)…');
    expect(said('invalid-article'), 'Damaged articles. Trying the next release (1)…');
    expect(said('provider-quota'), 'Provider quota reached. Trying the next release (1)…');
    expect(said('blank-content'), 'Empty release. Trying the next release (1)…');
  });

  test('the sources list hands its list to the player, once, by release', () {
    final l = [nzb('a'), nzb('b'), nzb('c')];
    UsenetFallback.hand(l, l[1]);
    final fb = UsenetFallback.take(nzb('b'));
    expect(fb.next()?.name, 'c');
    expect(UsenetFallback.take(nzb('b')).next(), isNull);
  });

  test('the open request: your providers, a User-Agent, the episode, the engine settings', () {
    final r = UsenetPlay.request(nzb('a', fileIdx: 3), season: 2, episode: 5);
    expect(r['nzbUrl'], 'https://indexer.test/get/a.nzb');
    expect(r['servers'], ['nntps://u:p@news.test:563/8?priority=1']);
    expect((r['headers'] as Map)['User-Agent'], startsWith('VyseTV/'));
    expect(r['fileIdx'], 3);
    expect(r['season'], 2);
    expect(r['episode'], 5);
    expect(r['cacheScope'], 'unscoped');
    final c = r['config'] as Map;
    expect(c.keys, containsAll(['profile', 'readAhead', 'maxConnections', 'fastMkvStartup', 'fastNzbFetch', 'cacheNzb', 'allowPrivateNetwork', 'holeFilling', 'maxMissingArticles', 'maxConsecutiveMissing']));
    // a film: no episode at all
    expect(UsenetPlay.request(nzb('m')).containsKey('episode'), isFalse);
    // an addon's own servers and User-Agent win
    final own = AddonStream(addon: _addon, url: '', text: 'x', nzbUrl: 'https://a.test/x.nzb', usenetServers: const ['nntp://h:119/2'], headers: const {'user-agent': 'Theirs/1'});
    final o = UsenetPlay.request(own);
    expect(o['servers'], ['nntp://h:119/2']);
    expect((o['headers'] as Map).length, 1);
  });

  test('Stream info: providers by bytes, completion, first byte, errors', () {
    final s = UsenetSession(
      id: 'a' * 48,
      url: 'http://127.0.0.1:1/stream/${'a' * 48}/Movie.mkv',
      filename: 'Movie.mkv',
      size: 4200000000,
      subtitles: const [],
      startup: const {},
      servers: const ['nntps://u:p@news.test:563/8?priority=1', 'nntps://u:p@backup.test:563/4?priority=2'],
    );
    final f = UsenetPlay.liveFacts(s, {
      'providers': [
        {'server': 0, 'articles': 900, 'bytes': 700000000, 'missing': 20, 'errors': 0, 'ttfbMs': 182.4},
        {'server': 1, 'articles': 18, 'bytes': 14000000, 'missing': 2, 'errors': 1},
      ],
      'filledArticles': 2,
    });
    expect(f['Release'], 'Movie.mkv');
    expect(f['Size'], '4.20 GB');
    expect(f['Providers'], 'Main 97.8%, backup.test 90.0%');
    expect(f['Articles'], '99.8%  (2 missing, 2 filled)');
    expect(f['First byte'], '182 ms');
    expect(f['Errors'], '1 · backup.test');
    expect(f.containsKey('Stopped'), isFalse);
  });
}
