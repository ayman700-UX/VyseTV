// Source statistics: what counts, by period and content, the rows Settings shows (with the
// spec's examples), how they are kept, and that nothing secret is.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';
import 'package:vyse_tv/data/usenet/usenet_stats.dart';

void main() {
  final stats = UsenetStats.instance;
  var now = DateTime(2026, 11, 28, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stats.debugRestart();
    now = DateTime(2026, 11, 28, 12);
    stats.clock = () => now;
    await stats.load();
  });

  Future<Map<String, Object?>> stored() async {
    await stats.flush();
    final raw = (await SharedPreferences.getInstance()).getString('device.usenet.sourceStats');
    return raw == null ? const {} : (jsonDecode(raw) as Map).cast<String, Object?>();
  }

  group('indexers', () {
    test('searches: 10 with 2 failed, 1 paused, 1 empty and 185 releases make 86% and 31', () {
      for (final n in [30, 30, 30, 30, 30, 35, 0]) {
        stats.indexerSearch('ix', 'movie', 'answered', n, const []);
      }
      stats.indexerSearch('ix', 'movie', 'failed', 0, const []);
      stats.indexerSearch('ix', 'movie', 'failed', 0, const []);
      stats.indexerSearch('ix', 'movie', 'paused', 0, const []);
      final c = stats.indexer('ix');
      expect(c.searches, 10);
      expect(c.releases, 185);
      expect(c.resultsPercent, 86);
      expect(c.averageReleases, 31);
      final rows = Map.fromEntries([for (final (k, v) in UsenetStatRows.indexer(c, stats.indexerToday('ix'), StatsPeriod.last30, null)) MapEntry(k, v)]);
      expect(rows['Searches'], '10 (2 failed, 1 paused)');
      expect(rows['Searches with results'], '86% · 31 releases on average');
      expect(rows.containsKey('Since'), isFalse);
    });

    test('two empty searches: 0% and 0', () {
      stats.indexerSearch('ix', 'show', 'answered', 0, const []);
      stats.indexerSearch('ix', 'show', 'answered', 0, const []);
      final c = stats.indexer('ix');
      expect(c.resultsPercent, 0);
      expect(c.averageReleases, 0);
      expect(UsenetStatRows.indexer(c, c, StatsPeriod.last30, null).first, ('Searches', '2'));
    });

    test('requests: answered with their time, failed, limited; today beside the total', () {
      stats.indexerRequest('ix', 'movie', 'answered', 600);
      stats.indexerRequest('ix', 'movie', 'answered', 620);
      stats.indexerRequest('ix', null, 'answered', 700);
      stats.indexerRequest('ix', 'show', 'failed', 0);
      stats.indexerRequest('ix', 'show', 'limited', 0);
      stats.indexerRequest('ix', 'show', 'answered', -5); // a clock that went back counts 0 ms
      final c = stats.indexer('ix');
      expect(c.requests, 6);
      expect(c.answered, 4);
      expect(c.responseMs, 1920);
      expect(c.averageResponseMs, 480);
      expect(c.failedRequests, 1);
      expect(c.limitedRequests, 1);
      final rows = Map.fromEntries([for (final (k, v) in UsenetStatRows.indexer(c, stats.indexerToday('ix'), StatsPeriod.last30, null)) MapEntry(k, v)]);
      expect(rows['API requests'], '6 · 6 today');
      expect(rows['Average response'], '480 ms');
      expect(rows.containsKey('Searches with results'), isFalse);
    });

    test('average response 1920 / 3 is 640', () {
      for (final ms in [600, 620, 700]) {
        stats.indexerRequest('ix', 'movie', 'answered', ms);
      }
      expect(stats.indexer('ix').averageResponseMs, 640);
    });

    test('content: Movies, Shows, and All with capability checks too', () {
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      stats.indexerRequest('ix', 'show', 'answered', 1);
      stats.indexerRequest('ix', null, 'answered', 1);
      stats.indexerSearch('ix', 'Series', 'answered', 3, const []); // any type but movie is a show
      expect(stats.indexer('ix', content: StatsContent.all).requests, 3);
      expect(stats.indexer('ix', content: StatsContent.movies).requests, 1);
      expect(stats.indexer('ix', content: StatsContent.shows).requests, 1);
      expect(stats.indexer('ix', content: StatsContent.shows).searches, 1);
      expect(stats.indexer('ix', content: StatsContent.movies).searches, 0);
    });

    test('periods: the last 7 and 30 local days, all time, and today alone', () {
      final start = now;
      for (final back in [0, 6, 7, 29, 30, 100]) {
        now = start.subtract(Duration(days: back));
        stats.indexerRequest('ix', 'movie', 'answered', 10);
      }
      now = start;
      expect(stats.indexer('ix', period: StatsPeriod.last7).requests, 2);
      expect(stats.indexer('ix', period: StatsPeriod.last30).requests, 4);
      expect(stats.indexer('ix', period: StatsPeriod.allTime).requests, 6);
      expect(stats.indexerToday('ix').requests, 1);
    });

    test('NZB downloads, plays and failures count only for releases a search listed', () {
      stats.indexerSearch('ix', 'movie', 'answered', 2, const ['https://ix/get/1?apikey=k', 'https://ix/get/2?apikey=k']);
      stats.grab('https://ix/get/1?apikey=k');
      stats.grab('https://elsewhere/addon.nzb');
      stats.played('https://ix/get/1?apikey=k');
      stats.unavailable('https://ix/get/2?apikey=k', 'missing-article');
      stats.unavailable('https://ix/get/2?apikey=k', 'provider-quota'); // not the release's fault
      final c = stats.indexer('ix');
      expect(c.grabs, 1);
      expect(c.played, 1);
      expect(c.unavailable, 1);
      expect(UsenetStatRows.indexer(c, stats.indexerToday('ix'), StatsPeriod.last30, null), contains(('NZB downloads', '1 · 1 today')));
      expect(UsenetStatRows.indexer(c, stats.indexerToday('ix'), StatsPeriod.last30, null), contains(('Played / unavailable', '1 / 1')));
    });

    test('a release plays or fails at most once in 12 hours, and a new listing keeps that', () {
      const url = 'https://ix/get/1?apikey=k';
      stats.indexerSearch('ix', 'movie', 'answered', 1, const [url]);
      stats.played(url);
      stats.played(url);
      stats.unavailable(url, 'hole-limit');
      stats.indexerSearch('ix', 'movie', 'answered', 1, const [url]);
      stats.played(url);
      expect(stats.indexer('ix').played, 1);
      now = now.add(const Duration(hours: 12, minutes: 1));
      stats.played(url);
      expect(stats.indexer('ix').played, 2);
    });

    test('a kept link names its indexer where the key goes', () {
      stats.grab('https://ix/api?t=get&id=1&apikey={indexer-key:ix-7}', contentType: 'series');
      stats.played('https://ix/api?t=get&id=1&apikey=%7Bindexer-key%3Aix-7%7D', contentType: 'movie');
      expect(stats.indexer('ix-7', content: StatsContent.shows).grabs, 1);
      expect(stats.indexer('ix-7', content: StatsContent.movies).played, 1);
    });

    test('the release memory keeps the last 4000', () {
      stats.indexerSearch('ix', 'movie', 'answered', 4001, [for (var i = 0; i <= 4000; i++) 'u$i']);
      stats.grab('u0');
      stats.grab('u1');
      expect(stats.indexer('ix').grabs, 1);
    });
  });

  group('providers', () {
    final p = UsenetProvider(id: 'p1', name: 'Main', host: 'News.Example.com', username: 'me', password: 'one');
    final v6 = UsenetProvider(id: 'p6', name: 'Six', host: '2001:db8::1', port: 119, tls: false, username: 'u+x', password: 'pw');

    setUp(() => stats.knownProviders([p, v6]));

    test('sessions by exact address, and by account when the password or allowance changed', () {
      final edited = p.copyWith(password: 'two', connections: 50);
      stats.providerReport([p.serverUrl, edited.serverUrl], [
        {'server': 0, 'articles': 10, 'bytes': 7000000, 'missing': 1, 'errors': 0, 'ttfbMs': 40.4},
      ], refused: false, contentKind: 'movie');
      stats.providerReport([edited.serverUrl], [
        {'server': 0, 'articles': 982, 'bytes': 1073741824, 'missing': 7, 'errors': 50, 'ttfbMs': 29.6},
      ], refused: false, contentKind: 'show');
      final c = stats.provider('p1');
      expect(c.sessions, 2);
      expect(c.articles, 992);
      expect(c.missing, 8);
      expect(c.completion, 99.2);
      expect(c.firstByteMs, 35);
      final rows = Map.fromEntries([for (final (k, v) in UsenetStatRows.provider(c, StatsPeriod.allTime, stats.since('p1'))) MapEntry(k, v)]);
      expect(rows['Completion'], '99.2% (8 missing)');
      expect(rows['Errors'], '50');
      expect(rows['Downloaded'], '1.01 GiB');
      expect(rows['First byte'], '35 ms');
      expect(rows['Sessions'], '2');
      expect(rows.containsKey('Since'), isTrue);
      expect(stats.provider('p1', content: StatsContent.movies).sessions, 1);
    });

    test('an IPv6 host with or without brackets, a + in the username kept', () {
      expect(UsenetStats.accountOf('nntp://u%2Bx:pw@[2001:DB8::1]:119/20?priority=1'), '[2001:db8::1]:119\nu+x');
      expect(UsenetStats.accountOf('nntps://me:pw@news.example.com/20'), 'news.example.com:563\nme');
      expect(UsenetStats.accountOf('nntp://news.example.com/20'), 'news.example.com:119\n');
      stats.providerReport(['nntp://u+x:other@[2001:db8::1]:119/8?priority=2'], [
        {'server': 0, 'articles': 1},
      ], refused: false, contentKind: 'movie');
      expect(stats.provider('p6').articles, 1);
    });

    test('unknown servers, places out of range and unreadable values count nothing', () {
      final before = stats.revision.value;
      stats.providerReport(['nntps://x:y@other.example:563/20'], [
        {'server': 0, 'articles': 5},
        {'server': 3, 'articles': 5},
        {'server': 'zero', 'articles': 5},
      ], refused: false);
      stats.providerReport([p.serverUrl], const [], refused: false);
      expect(stats.revision.value, before);
      expect(stats.provider('p1').isEmpty, isTrue);
    });

    test('two listings of one provider are one session; the first first byte counts', () {
      final other = p.copyWith(password: 'addon');
      stats.providerReport([p.serverUrl, other.serverUrl], [
        {'server': 0, 'articles': 3, 'ttfbMs': 100},
        {'server': 1, 'articles': 4, 'ttfbMs': 20},
      ], refused: false, contentKind: 'movie');
      final c = stats.provider('p1');
      expect(c.sessions, 1);
      expect(c.articles, 7);
      expect(c.ttfbSessions, 1);
      expect(c.firstByteMs, 100);
    });

    test('a refused open: failed to open only for articles a provider lacked or broke', () {
      final second = UsenetProvider(id: 'p2', name: 'Backup', host: 'backup.example', username: 'b', password: 'c');
      stats.knownProviders([p, second]);
      stats.providerReport([p.serverUrl, second.serverUrl], [
        {'server': 0, 'articles': 0, 'missing': 4},
        {'server': 1, 'articles': 0, 'missing': 0, 'errors': 0}, // never asked
      ], refused: true, failureKind: 'missing-article', contentKind: 'movie');
      stats.providerReport([p.serverUrl], [
        {'server': 0, 'articles': 6, 'missing': 0},
      ], refused: true, failureKind: 'blank-content', contentKind: 'movie');
      expect(stats.provider('p1').sessions, 2);
      expect(stats.provider('p1').failedOpens, 1);
      expect(stats.provider('p1').articles, 6);
      expect(stats.provider('p2').isEmpty, isTrue);
      final rows = UsenetStatRows.provider(stats.provider('p1'), StatsPeriod.last30, null);
      expect(rows, contains(('Sessions', '2 (1 failed to open)')));
      expect(rows, contains(('Completion', '60.0% (4 missing)')));
    });

    test('missing articles only: 0.0% complete; a provider never told counts nothing', () {
      stats.providerReport([p.serverUrl], [
        {'server': 0, 'missing': 3},
      ], refused: false);
      expect(stats.provider('p1').completion, 0.0);
      final stranger = UsenetProvider(id: 'px', name: 'New', host: 'new.example');
      stats.providerReport([stranger.serverUrl], [
        {'server': 0, 'articles': 3},
      ], refused: false);
      expect(stats.provider('px').isEmpty, isTrue);
    });

    test('names for the player: the provider, else the host, else ?', () {
      expect(stats.providerLabel(p.copyWith(password: 'x').serverUrl), 'Main');
      expect(stats.providerLabel('nntps://someone@else.example:563/4'), 'else.example');
      expect(stats.providerLabel('not a server'), '?');
    });
  });

  group('keeping', () {
    test('written at once, then at most every 5 s (held counts go with a flush)', () async {
      final prefs = await SharedPreferences.getInstance();
      String? raw() => prefs.getString('device.usenet.sourceStats');
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      await Future<void>.delayed(Duration.zero);
      expect(raw(), contains('"requests":1'));
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      await Future<void>.delayed(Duration.zero);
      expect(raw(), contains('"requests":1'));
      now = now.add(const Duration(seconds: 5));
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      await Future<void>.delayed(Duration.zero);
      expect(raw(), contains('"requests":3'));
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      await stats.flush();
      expect(raw(), contains('"requests":4'));
    });

    test('read back after a restart, counts and choices', () async {
      stats.indexerSearch('ix', 'movie', 'answered', 4, const []);
      await stats.setPeriod(StatsPeriod.allTime);
      await stats.setContent(StatsContent.shows);
      await stats.flush();
      stats.debugRestart();
      stats.clock = () => now;
      await stats.load();
      expect(stats.indexer('ix', content: StatsContent.all).releases, 4);
      expect(stats.period.value, StatsPeriod.allTime);
      expect(stats.content.value, StatsContent.shows);
    });

    test('events before the store is read are counted once it is', () async {
      stats.debugRestart();
      stats.clock = () => now;
      stats.indexerRequest('ix', 'movie', 'failed', 0);
      await stats.load();
      expect(stats.indexer('ix').failedRequests, 1);
    });

    test('unknown stored choices and unreadable counts start from the defaults', () async {
      SharedPreferences.setMockInitialValues({'device.usenet.statsPeriod': 'FOREVER', 'device.usenet.statsContent': 'X', 'device.usenet.sourceStats': '{broken'});
      stats.debugRestart();
      await stats.load();
      expect(stats.period.value, StatsPeriod.last30);
      expect(stats.content.value, StatsContent.all);
      expect(stats.indexer('ix').isEmpty, isTrue);
    });

    test('ids only: no address, key, name or password is kept', () async {
      final p = UsenetProvider(id: 'p1', name: 'Main', host: 'news.example.com', username: 'me', password: 'secret');
      stats.knownProviders([p]);
      stats.indexerSearch('ix', 'movie', 'answered', 1, const ['https://ix.example/get?apikey=KEY123']);
      stats.grab('https://ix.example/get?apikey=KEY123');
      stats.providerReport([p.serverUrl], [
        {'server': 0, 'articles': 2},
      ], refused: false, contentKind: 'movie');
      final text = jsonEncode(await stored());
      for (final secret in ['secret', 'KEY123', 'news.example.com', 'Main', 'ix.example', 'apikey']) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('"p1"'));
      expect(text, contains('"ix"'));
    });

    test('pruned on write: 32 of each kind, 180 days, 30 days of buckets (totals stay)', () async {
      final start = now;
      now = start.subtract(const Duration(days: 181));
      stats.indexerRequest('old', 'movie', 'answered', 1);
      now = start.subtract(const Duration(days: 40));
      stats.indexerRequest('ix0', 'movie', 'answered', 1);
      for (var i = 1; i <= 32; i++) {
        now = start.subtract(Duration(minutes: 100 - i));
        stats.indexerRequest('ix$i', 'movie', 'answered', 1);
      }
      now = start;
      stats.indexerRequest('ix32', 'movie', 'answered', 1);
      final j = await stored();
      final indexers = (j['indexers'] as Map).keys.toSet();
      expect(indexers.length, 32);
      expect(indexers.contains('old'), isFalse);
      expect(indexers.contains('ix0'), isFalse, reason: 'the least recently touched of 33');
      expect(stats.indexer('ix32', period: StatsPeriod.allTime).requests, 2);
    });

    test('day buckets older than 30 days go, their counts stay in all time', () async {
      final start = now;
      now = start.subtract(const Duration(days: 45));
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      now = start;
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      final days = (((await stored())['indexers'] as Map)['ix'] as Map)['days'] as Map;
      expect(days.length, 1);
      expect(stats.indexer('ix', period: StatsPeriod.allTime).requests, 2);
      expect(stats.indexer('ix', period: StatsPeriod.last30).requests, 1);
    });

    test('Reset statistics clears the counts and keeps the choices; an account reset clears all', () async {
      await stats.setPeriod(StatsPeriod.last7);
      stats.indexerRequest('ix', 'movie', 'answered', 1);
      await stats.reset();
      expect(stats.indexer('ix', period: StatsPeriod.allTime).isEmpty, isTrue);
      expect(stats.period.value, StatsPeriod.last7);
      expect((await SharedPreferences.getInstance()).getString('device.usenet.sourceStats'), isNull);
      await stats.clearAll();
      expect(stats.period.value, StatsPeriod.last30);
      expect((await SharedPreferences.getInstance()).getString('device.usenet.statsPeriod'), isNull);
    });
  });
}
