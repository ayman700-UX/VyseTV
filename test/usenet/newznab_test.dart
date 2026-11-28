// The Newznab client: endpoints, search addresses, paging, parsing, errors and pauses, what is
// kept of each indexer, Test indexer, the season searches and the request statistics (the
// Usenet search spec, sections 1, 2, 3.5 and 10.5; Test indexer, the tester spec section 2).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/usenet/newznab.dart';
import 'package:vyse_tv/data/usenet/usenet_names.dart';
import 'package:vyse_tv/data/usenet/usenet_play.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

typedef Reply = ({int status, String body, Map<String, String> headers});

Reply ok(String body, [Map<String, String> headers = const {}]) => (status: 200, body: body, headers: headers);
Reply status(int code, [String body = '', Map<String, String> headers = const {}]) => (status: code, body: body, headers: headers);

String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');

String caps({int limit = 100, String movie = 'q,imdbid,tmdbid,year', String tv = 'q,imdbid,tvdbid,season,ep', bool search = true}) =>
    '<?xml version="1.0" encoding="UTF-8"?><caps><limits max="$limit" default="$limit"/><searching>'
    '<search available="${search ? 'yes' : 'no'}" supportedParams="q"/>'
    '<tv-search available="yes" supportedParams="$tv"/><movie-search available="yes" supportedParams="$movie"/></searching></caps>';

String item(String title, String url, {int size = 1000, String? extra}) =>
    '<item><title>${esc(title)}</title><link>${esc(url)}</link><enclosure url="${esc(url)}" length="$size" type="application/x-nzb"/>'
    '<newznab:attr name="size" value="$size"/>${extra ?? ''}</item>';

String rss(Iterable<String> items, {int? total, String comment = ''}) =>
    '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/"><channel>$comment'
    '${total == null ? '' : '<newznab:response offset="0" total="$total"/>'}${items.join()}</channel></rss>';

/// An indexer on this computer, answering as each test says.
class Fake {
  late HttpServer server;
  final requests = <Uri>[];
  final agents = <String?>[];
  final caching = <String?>[];
  Reply Function(Uri uri) reply = (uri) => ok(caps());

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      agents.add(req.headers.value(HttpHeaders.userAgentHeader));
      caching.add(req.headers.value(HttpHeaders.cacheControlHeader));
      final r = reply(req.uri);
      req.response.statusCode = r.status;
      r.headers.forEach(req.response.headers.set);
      req.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
      req.response.add(utf8.encode(r.body));
      await req.response.close();
    });
  }

  List<Uri> of(String t) => [for (final u in requests) if (u.queryParameters['t'] == t) u];

  UsenetIndexer indexer({String id = 'one', String name = 'One', String key = 'secret-key-123', int priority = 1}) =>
      UsenetIndexer(id: id, name: name, apiUrl: base, apiPath: '/api', apiKey: key, priority: priority);
}

final nz = Newznab.instance;

Future<String> stored() async {
  await nz.flushed();
  return (await SharedPreferences.getInstance()).getString('device.usenet.indexers') ?? '';
}

const series12 = UsenetSearchRequest(imdbId: 'tt123', season: 1, episode: 2, series: true);

void main() {
  late Fake fake;
  final events = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await nz.clear();
    nz.debugForget();
    UsenetClock.debugNow = DateTime.now;
    events.clear();
    Newznab.onRequest = (id, kind, outcome, ms) => events.add('$id:${kind ?? 'all'}:$outcome');
    fake = Fake();
    await fake.start();
  });

  tearDown(() async {
    Newznab.onRequest = null;
    await fake.server.close(force: true);
  });

  group('endpoints', () {
    String? e(String url, String path) => UsenetIndexer(name: 'x', apiUrl: url, apiPath: path).endpoint?.toString();

    test('the table', () {
      expect(e('https://api.nzbgeek.info/', '/api'), 'https://api.nzbgeek.info/api');
      expect(e('https://api.nzbgeek.info', 'api'), 'https://api.nzbgeek.info/api');
      expect(e('http://prowlarr.local:9696/1', '/api'), 'http://prowlarr.local:9696/1/api');
      expect(e('https://indexer.test/?custom=1', '/api'), 'https://indexer.test/api?custom=1');
      expect(e('https://indexer.test', '/v2/api/'), 'https://indexer.test/v2/api');
      expect(e('https://indexer.test/api', '/api'), 'https://indexer.test/api');
      expect(e('http://prowlarr.local:9696/1/api', '/api'), 'http://prowlarr.local:9696/1/api');
      expect(Newznab.endpointOf(UsenetIndexer(name: 'x', apiUrl: 'http://hydra.local:5076/api?x=1')), 'http://hydra.local:5076/api?x=1');
      final legacy = UsenetIndexer.fromJson({'name': 'x', 'apiUrl': 'https://indexer.test/newznab'});
      expect(Newznab.endpointOf(legacy), 'https://indexer.test/newznab');
    });

    test('invalid paths and addresses', () {
      for (final p in ['/api?t=caps', '/api#x', '/../api', '/a pi']) {
        expect(UsenetIndexer(name: 'x', apiUrl: 'https://indexer.test', apiPath: p).problem, isNotNull, reason: p);
      }
      expect(UsenetIndexer(name: 'x', apiUrl: 'https://indexer.test', apiPath: '/api').problem, isNull);
      expect(UsenetIndexer(name: 'x', apiUrl: 'https://user:pw@indexer.test', apiPath: '/api').problem, isNotNull);
      expect(UsenetIndexer(name: 'x', apiUrl: 'ftp://indexer.test', apiPath: '/api').problem, isNotNull);
      expect(UsenetIndexer(apiUrl: 'https://indexer.test', apiPath: '/api').problem, isNotNull);
    });
  });

  group('search addresses', () {
    final i = UsenetIndexer(id: 'x', name: 'X', apiUrl: 'https://indexer.test/api?custom=value', apiKey: 'secret &+key');
    const defaults = NewznabCaps();
    final example = NewznabCaps.parse(
      '<caps><limits max="50"/><searching><movie-search available="yes" supportedParams="q,tmdbid,year"/><tv-search available="no"/><search available="yes"/></searching></caps>',
    );
    Map<String, String>? q(UsenetSearchRequest r, NewznabCaps c, {bool whole = false}) => Newznab.searchUrl(i, r, c, wholeSeason: whole)?.queryParameters;

    test('the capabilities example', () {
      expect(example.movieParams, {'q', 'tmdbid', 'year'});
      expect(example.tvParams, isEmpty);
      expect(example.searchAvailable, isTrue);
      expect(example.limit, 50);
      expect(() => NewznabCaps.parse('<rss/>'), throwsA(isA<NewznabFailure>()));
      expect(NewznabCaps.parse('<caps><limits max="500"/></caps>').limit, 100);
      expect(NewznabCaps.parse('<caps><limits max="x"/></caps>').limit, 100);
    });

    test('by id', () {
      expect(q(const UsenetSearchRequest(imdbId: 'tt123', season: 0, episode: 2, series: true), defaults), {
        'custom': 'value',
        'apikey': 'secret &+key',
        't': 'tvsearch',
        'o': 'xml',
        'imdbid': '123',
        'season': '0',
        'ep': '2',
        'cat': '5000',
        'limit': '100',
        'offset': '0',
      });
      expect(Newznab.searchUrl(i, const UsenetSearchRequest(imdbId: 'tt123', season: 0, episode: 2, series: true), defaults).toString(), contains('%2B'));
      expect(q(const UsenetSearchRequest(imdbId: 'tt123', series: true), defaults), isNull);
      const tvdbCaps = NewznabCaps(tvParams: {'q', 'tvdbid', 'season', 'ep'});
      const both = UsenetSearchRequest(imdbId: 'tt1', tvdbId: '121361', season: 1, episode: 2, series: true);
      final a = q(both, tvdbCaps)!;
      expect(a['tvdbid'], '121361');
      expect(a.containsKey('imdbid'), isFalse);
      expect(a['ep'], '2');
      final whole = q(both, tvdbCaps, whole: true)!;
      expect(whole['season'], '1');
      expect(whole.containsKey('ep'), isFalse);
      expect(q(const UsenetSearchRequest(title: 'A Show', season: 1, episode: 2, series: true), tvdbCaps, whole: true), isNull);
      expect(q(const UsenetSearchRequest(imdbId: 'tt1'), defaults, whole: true), isNull);
      expect(q(const UsenetSearchRequest(tvdbId: '5'), const NewznabCaps(movieParams: {'tvdbid'})), isNull);
      final movie = q(const UsenetSearchRequest(imdbId: 'tt1', tmdbId: '20'), example)!;
      expect(movie['t'], 'movie');
      expect(movie['tmdbid'], '20');
      expect(movie['limit'], '50');
      expect(movie.containsKey('imdbid'), isFalse);
      expect(q(const UsenetSearchRequest(imdbId: 'tt1', season: 1, episode: 1, series: true), example), isNull);
    });

    test('by title', () {
      final generic = q(const UsenetSearchRequest(title: 'A Show', season: 2, episode: 3, series: true), example)!;
      expect(generic['t'], 'search');
      expect(generic['q'], 'A Show S02E03');
      expect(generic.containsKey('season'), isFalse);
      final noEpisodes = q(const UsenetSearchRequest(imdbId: 'tt1', title: 'A Show', season: 2, episode: 3, series: true), const NewznabCaps(tvParams: {'imdbid', 'q'}))!;
      expect(noEpisodes['t'], 'tvsearch');
      expect(noEpisodes['q'], 'A Show S02E03');
      expect(noEpisodes.containsKey('imdbid'), isFalse);
      const qOnly = NewznabCaps(movieParams: {'q'});
      expect(q(const UsenetSearchRequest(title: 'Amélie'), qOnly)!['q'], 'Amelie');
      expect(q(const UsenetSearchRequest(title: 'Der König der Löwen'), qOnly)!['q'], 'Der Koenig der Loewen');
      expect(q(const UsenetSearchRequest(title: "Marvel's The Avengers"), qOnly)!['q'], 'Marvels The Avengers');
      expect(q(const UsenetSearchRequest(title: 'Mission: Impossible – Fallout'), qOnly)!['q'], 'Mission Impossible Fallout');
      expect(q(const UsenetSearchRequest(title: 'ガンダム'), qOnly)!['q'], 'ガンダム');
      expect(q(const UsenetSearchRequest(title: 'Film', year: 2020), const NewznabCaps(movieParams: {'q', 'year'}))!['year'], '2020');
      expect(q(const UsenetSearchRequest(title: 'Film'), const NewznabCaps(movieParams: {}, searchAvailable: false)), isNull);
      expect(Newznab.isIdSearch(Newznab.searchUrl(i, const UsenetSearchRequest(imdbId: 'tt1'), defaults)!), isTrue);
      expect(Newznab.isIdSearch(Newznab.searchUrl(i, const UsenetSearchRequest(title: 'Film'), qOnly)!), isFalse);
    });
  });

  group('parsing', () {
    final i = UsenetIndexer(id: 'x', name: 'X', apiUrl: 'https://indexer.test/api?custom=value');

    test('items', () {
      const xml = '''<?xml version="1.0"?>
<rss xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/" xmlns:torznab="http://torznab.com/schemas/2015/feed">
<channel><newznab:response offset="0" total="44"/>
<item><title> Film.2020.1080p-A </title><link>https://other.test/ignored</link><enclosure url="/get?id=1&amp;apikey=secret" length="1000" type="application/x-nzb"/><newznab:attr name="size" value="2000"/><newznab:attr name="usenetdate" value="Fri, 09 Oct 2026 12:00:00 +0000"/><newznab:attr name="password" value="1"/></item>
<item><title>Film.2020.1080p-B</title><link>https://indexer.test/get?id=2</link><pubDate>2026-10-09T12:00:00Z</pubDate><torznab:attr name="SIZE" value="-5"/></item>
<item><title>Film.2020.1080p-C</title><link>https://indexer.test/get?id=3</link><enclosure url="https://indexer.test/t.torrent" type="application/x-bittorrent"/></item>
<item><title></title><link>https://indexer.test/get?id=4</link></item>
<item><title>Film.2020.1080p-E</title><enclosure url="https://indexer.test/get?id=5" length="700" type="application/X-NZB"/><pubDate>1791547200</pubDate></item>
<item><title>Film.2020.1080p-F</title><enclosure url="https://indexer.test/get?id=6" type="application/x-nzb"/><pubDate>1791547200000</pubDate><newznab:attr name="password" value="no"/></item>
</channel></rss>''';
      final page = Newznab.parseReleases(xml, i);
      expect(page.items, 6);
      expect(page.total, 44);
      expect(page.releases.map((r) => r.title), ['Film.2020.1080p-A', 'Film.2020.1080p-B', 'Film.2020.1080p-E', 'Film.2020.1080p-F']);
      final a = page.releases[0];
      expect(a.nzbUrl, 'https://indexer.test/get?id=1&apikey=secret');
      expect(a.size, 2000);
      expect(a.passworded, isTrue);
      expect(a.publishedAt, DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(a.indexerId, 'x');
      expect(a.indexerName, 'X');
      expect(page.releases[1].size, 0);
      expect(page.releases[1].publishedAt, DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(page.releases[2].size, 700);
      expect(page.releases[2].publishedAt, 1791547200000);
      expect(page.releases[3].publishedAt, 1791547200000);
      expect(page.releases[3].passworded, isFalse);
    });

    test('dates', () {
      expect(Newznab.parsePosted('Fri, 09 Oct 2026 12:00:00 +0000'), DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(Newznab.parsePosted('09 Oct 2026 14:00:00 +0200'), DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(Newznab.parsePosted('Fri, 09 Oct 2026 12:00:00 GMT'), DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(Newznab.parsePosted('2026-10-09T12:00:00Z'), DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch);
      expect(Newznab.parsePosted('nonsense'), 0);
      expect(Newznab.parsePosted('0'), 0);
      expect(Newznab.parsePosted(''), 0);
    });

    test('unsafe XML and error documents', () {
      expect(() => Newznab.parseReleases('<!DOCTYPE x [<!ENTITY a "b">]><rss/>', i), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.invalid)));
      expect(() => Newznab.parseReleases('<caps/>', i), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.invalid)));
      NewznabFailureKind kindOf(String code) {
        try {
          Newznab.parseReleases('<error code="$code" description="API key secret &amp; URL"/>', i);
        } on NewznabFailure catch (e) {
          return e.kind;
        }
        throw StateError('no failure');
      }

      for (final c in ['429', '500', '501']) {
        expect(kindOf(c), NewznabFailureKind.quota);
      }
      for (final c in ['100', '101', '102']) {
        expect(kindOf(c), NewznabFailureKind.auth);
      }
      for (final c in ['200', '201', '202', '203']) {
        expect(kindOf(c), NewznabFailureKind.unsupported);
      }
      expect(kindOf('300'), NewznabFailureKind.api);
      try {
        Newznab.parseReleases('<error code="100" description="API key secret &amp; URL"/>', i);
      } on NewznabFailure catch (e) {
        expect(e.toString(), 'Indexer authentication failed');
      }
    });

    test('search rejections', () {
      for (final s in [400, 404, 405, 422]) {
        expect(Newznab.isSearchRejection(NewznabFailure(NewznabFailureKind.http, status: s)), isTrue, reason: '$s');
      }
      for (final s in [401, 403, 408, 429, 500, 502, 503]) {
        expect(Newznab.isSearchRejection(NewznabFailure(NewznabFailureKind.http, status: s)), isFalse, reason: '$s');
      }
      expect(Newznab.isSearchRejection(const NewznabFailure(NewznabFailureKind.unsupported)), isTrue);
      expect(Newznab.isSearchRejection(TimeoutException('x')), isFalse);
      expect(Newznab.isSearchRejection(const NewznabFailure(NewznabFailureKind.cooldown)), isFalse);
      expect(Newznab.isSearchRejection(const NewznabFailure(NewznabFailureKind.auth)), isFalse);
    });

    test('Retry-After', () {
      final now = DateTime.utc(2026, 10, 9, 12).millisecondsSinceEpoch;
      expect(Newznab.retryAfter('120'), const Duration(seconds: 120));
      expect(Newznab.retryAfter(' 0 '), isNull);
      expect(Newznab.retryAfter('-5'), isNull);
      expect(Newznab.retryAfter(''), isNull);
      expect(Newznab.retryAfter('Fri, 09 Oct 2026 12:10:00 GMT', now: now), const Duration(minutes: 10));
      expect(Newznab.retryAfter('Fri, 09 Oct 2026 11:00:00 GMT', now: now), isNull);
    });
  });

  group('paging', () {
    final offsets = <(int, int)>[];
    setUp(() => offsets.clear());

    Future<List<UsenetRelease>> read(Fake f, {required int limit, required int results, required String Function(int offset, int limit) page}) async {
      f.reply = (uri) {
        if (uri.queryParameters['t'] == 'caps') return ok(caps(limit: limit));
        final o = int.parse(uri.queryParameters['offset']!), l = int.parse(uri.queryParameters['limit']!);
        offsets.add((o, l));
        return ok(page(o, l));
      };
      final i = f.indexer();
      final c = await nz.capabilities(i);
      const r = UsenetSearchRequest(imdbId: 'tt1');
      return nz.pages(i, Newznab.searchUrl(i, r, c)!, r, c, results);
    }

    String items(Iterable<int> ns) => [for (final n in ns) item('Film.$n', 'https://h.test/$n')].join();

    test('the last page asks only for the rest', () async {
      final got = await read(fake, limit: 75, results: 200, page: (o, l) => rss([items(Iterable.generate(l, (k) => o + k))]));
      expect(offsets, [(0, 75), (75, 75), (150, 50)]);
      expect(got, hasLength(200));
    });

    test('every page up to the total', () async {
      final got = await read(fake, limit: 100, results: 0, page: (o, l) => rss([items(Iterable.generate(o + l > 1205 ? 1205 - o : l, (k) => o + k))], total: 1205));
      expect(offsets.map((x) => x.$1), [for (var o = 0; o <= 1200; o += 100) o]);
      expect(got, hasLength(1205));
    });

    test('with a total, a short page goes on', () async {
      String page(int o, int l) => rss([items(o == 0 ? [0] : [for (var n = o; n < o + 2 && n < 9; n++) n])], total: 9);
      expect(await read(fake, limit: 2, results: 0, page: page), hasLength(8));
      expect(offsets.map((x) => x.$1), [0, 2, 4, 6, 8]);
      offsets.clear();
      expect(await read(fake, limit: 2, results: 5, page: page), hasLength(4));
      expect(offsets, [(0, 2), (2, 2), (4, 1)]);
      offsets.clear();
      final held = await read(fake, limit: 2, results: 0, page: (o, l) => rss([items(o == 0 ? [0] : [for (var n = o; n < o + 2 && n < 4; n++) n])], total: 10000));
      expect(held, hasLength(3));
      expect(offsets.map((x) => x.$1), [0, 2, 4]);
    });

    test('without a total, a short page stops', () async {
      final got = await read(fake, limit: 1, results: 0, page: (o, l) => rss([items(o < 3 ? [o] : const [])]));
      expect(got, hasLength(3));
      expect(offsets, hasLength(4));
    });

    test('repeated pages stop', () async {
      expect(await read(fake, limit: 1, results: 0, page: (o, l) => rss([items([0])])), hasLength(1));
      expect(offsets, hasLength(2));
      offsets.clear();
      expect(await read(fake, limit: 1, results: 0, page: (o, l) => rss([items([0])], comment: '<!-- page $o -->')), hasLength(1));
      expect(offsets, hasLength(2));
    });

    test('unusable items advance, a failed later page keeps the first', () async {
      final got = await read(fake, limit: 1, results: 0, page: (o, l) => o == 0 ? rss(['<item><title></title></item>']) : (o == 1 ? rss([items([1])]) : rss([items([2])])));
      expect(got.map((r) => r.title), ['Film.1', 'Film.2']);
      offsets.clear();
      fake.reply = (uri) {
        if (uri.queryParameters['t'] == 'caps') return ok(caps(limit: 1));
        final o = int.parse(uri.queryParameters['offset']!);
        offsets.add((o, 1));
        return o == 0 ? ok(rss([items([0])])) : status(503);
      };
      final i = fake.indexer();
      final c = await nz.capabilities(i);
      const r = UsenetSearchRequest(imdbId: 'tt1');
      expect(await nz.pages(i, Newznab.searchUrl(i, r, c)!, r, c, 0), hasLength(1));
    });

    test('an unlimited read can be stopped', () async {
      var stop = false;
      fake.reply = (uri) {
        if (uri.queryParameters['t'] == 'caps') return ok(caps(limit: 1));
        final o = int.parse(uri.queryParameters['offset']!);
        if (o == 2) stop = true;
        return ok(rss([items([o])]));
      };
      final i = fake.indexer();
      final c = await nz.capabilities(i);
      const r = UsenetSearchRequest(imdbId: 'tt1');
      final got = await nz.pages(i, Newznab.searchUrl(i, r, c)!, r, c, 0, cancelled: () => stop);
      expect(got, hasLength(3));
    });
  });

  group('requests', () {
    test('headers', () async {
      await nz.capabilities(fake.indexer());
      expect(fake.agents.single, UsenetPlay.searchUserAgent);
      expect(fake.caching.single, 'no-store');
    });

    test('problems, and what is written', () async {
      final i = fake.indexer();
      Future<void> go(Reply r) async {
        fake.reply = (_) => r;
        try {
          await nz.capabilities(i, live: true);
        } catch (_) {}
      }

      await go(ok('<error code="100" description="bad key secret-key-123"/>'));
      expect(nz.status(i).problem, IndexerProblem.auth);
      expect(nz.statusLine(i), 'Last request failed: API key rejected');
      await go(status(403));
      expect(nz.status(i).problem, IndexerProblem.auth);
      await go(status(500, 'oops'));
      expect(nz.status(i).problem, IndexerProblem.response);
      expect(nz.statusLine(i), 'Last request failed: unexpected response');
      await go(ok(caps()));
      expect(nz.status(i).problem, isNull);
      final before = await stored();
      final changes = nz.changed.value;
      await go(ok(caps()));
      expect(await stored(), isNot(isEmpty));
      expect(nz.changed.value - changes, 1); // the capabilities kept again, nothing else
      expect(before.contains('secret-key-123'), isFalse);
      await go(ok('<error code="101"/>'));
      await nz.flushed();
      nz.debugForget();
      await nz.load();
      expect(nz.status(i).problem, IndexerProblem.auth);
      await fake.server.close(force: true);
      await go(ok(caps()));
      expect(nz.status(i).problem, IndexerProblem.unreachable);
      expect(nz.statusLine(i), 'Last request failed: could not reach the indexer');
    });

    test('a key in an error is never in the message', () async {
      fake.reply = (_) => ok('<error code="100" description="API key secret-key-123 &amp; URL"/>');
      try {
        await nz.capabilities(fake.indexer());
        fail('no failure');
      } on NewznabFailure catch (e) {
        expect(e.toString(), 'Indexer authentication failed');
      }
    });

    test('429 pauses, also after a restart; a live request still goes', () async {
      final i = fake.indexer();
      fake.reply = (_) => status(429, '', {'Retry-After': '120'});
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.cooldown)));
      final left = nz.status(i).pausedUntil!.difference(DateTime.now()).inSeconds;
      expect(left, inInclusiveRange(100, 120));
      expect(nz.statusLine(i), startsWith('Paused until '));
      await nz.flushed();
      nz.debugForget();
      await nz.load();
      final sent = fake.requests.length;
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>()));
      expect(fake.requests.length, sent);
      fake.reply = (_) => ok(caps());
      await nz.capabilities(i, live: true);
      expect(fake.requests.length, sent + 1);
      expect(events.where((e) => e.endsWith('limited')), hasLength(1));
    });

    test('429 without Retry-After, and a long one', () async {
      final i = fake.indexer();
      fake.reply = (_) => status(429);
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>()));
      expect(nz.status(i).pausedUntil!.difference(DateTime.now()).inSeconds, inInclusiveRange(50, 60));
      final j = fake.indexer(id: 'two', key: 'another-key-456');
      fake.reply = (_) => status(429, '', {'Retry-After': '7200'});
      await expectLater(nz.capabilities(j), throwsA(isA<NewznabFailure>()));
      expect(nz.status(j).pausedUntil!.difference(DateTime.now()).inMinutes, inInclusiveRange(14, 15));
    });

    test('quota documents pause, whatever the status', () async {
      final i = fake.indexer();
      fake.reply = (_) => ok('<error code="500" description="Request limit reached"/>');
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.cooldown)));
      expect(nz.status(i).pausedUntil!.difference(DateTime.now()).inMinutes, greaterThan(25));
      final j = fake.indexer(id: 'two', key: 'another-key-456');
      fake.reply = (_) => status(403, '<error code="429"/>', {'Retry-After': '7200'});
      await expectLater(nz.capabilities(j), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.cooldown)));
      expect(nz.status(j).pausedUntil!.difference(DateTime.now()).inMinutes, greaterThan(100));
      final k = fake.indexer(id: 'three', key: 'third-key-789');
      fake.reply = (_) => status(503, '<error code="100"/>');
      await expectLater(nz.capabilities(k), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.auth)));
      expect(nz.status(k).problem, IndexerProblem.auth);
    });

    test('counts left', () async {
      final i = fake.indexer();
      fake.reply = (_) => ok(caps(), {'x-api-remaining': '42', 'x-grab-remaining': '1'});
      await nz.capabilities(i, live: true);
      final s = nz.status(i);
      expect(s.apiHitsLeft, 42);
      expect(s.grabsLeft, 1);
      expect(s.pausedUntil, isNull);
      expect(DateTime.now().difference(s.leftAt!).inSeconds, lessThan(5));
      expect(nz.statusLine(i), matches(RegExp(r'^42 API hits left, 1 grab left \(as of \d\d:\d\d\)$')));
      expect(await stored(), isNot(contains('secret-key-123')));
      await nz.flushed();
      nz.debugForget();
      await nz.load();
      expect(nz.status(i).apiHitsLeft, 42);
      UsenetClock.debugNow = () => DateTime.now().add(const Duration(hours: 25));
      expect(nz.status(i).apiHitsLeft, isNull);
      expect(nz.status(i).grabsLeft, isNull);
      UsenetClock.debugNow = DateTime.now;
      fake.reply = (_) => ok(caps(), {'X-RateLimit-Daily-Remaining': '7'});
      await nz.capabilities(i, live: true);
      expect(nz.status(i).apiHitsLeft, 7);
      expect(nz.status(i).grabsLeft, isNull);
      expect(nz.statusLine(i), startsWith('7 API hits left (as of'));
    });

    test('none left: this answer still counts, the next request waits', () async {
      final i = fake.indexer();
      fake.reply = (_) => ok(caps(limit: 33), {'x-api-remaining': '0'});
      expect((await nz.capabilities(i, live: true)).limit, 33);
      expect(nz.status(i).pausedUntil!.difference(DateTime.now()).inMinutes, inInclusiveRange(14, 15));
    });

    test('too large an answer', () async {
      final i = fake.indexer();
      fake.reply = (_) => ok('<caps>${' ' * (Newznab.maxBody + 10)}</caps>');
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>().having((e) => e.kind, 'kind', NewznabFailureKind.tooLarge)));
      expect(nz.status(i).problem, IndexerProblem.response);
    });
  });

  group('capabilities kept', () {
    test('asked once, also after a restart; a new key asks again', () async {
      final i = fake.indexer();
      await nz.capabilities(i);
      await nz.capabilities(i);
      await nz.flushed();
      nz.debugForget();
      await nz.capabilities(i);
      expect(fake.of('caps'), hasLength(1));
      expect(await stored(), isNot(contains('secret-key-123')));
      await nz.capabilities(fake.indexer(key: 'rotated-key-999'));
      expect(fake.of('caps'), hasLength(2));
    });

    test('an old copy serves when a fresh one fails', () async {
      final i = fake.indexer();
      fake.reply = (_) => ok(caps(limit: 40));
      await nz.capabilities(i);
      UsenetClock.debugNow = () => DateTime.now().add(const Duration(days: 8));
      fake.reply = (_) => status(503);
      expect((await nz.capabilities(i)).limit, 40);
      expect(fake.of('caps'), hasLength(2));
      await expectLater(nz.capabilities(i, live: true), throwsA(isA<NewznabFailure>()));
    });

    test('a reset forgets', () async {
      final i = fake.indexer();
      fake.reply = (_) => status(401);
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>()));
      expect(nz.status(i).problem, IndexerProblem.auth);
      await nz.clear();
      expect(nz.status(i).problem, isNull);
      expect(await stored(), isEmpty);
    });
  });

  group('Test indexer', () {
    test('passes on results, or a refusal of its parameters', () async {
      final i = fake.indexer();
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok(rss(const []));
      final r = await nz.test(i);
      expect(r.ok, isTrue);
      expect(r.message, Newznab.testPassed);
      final search = fake.of('search').single.queryParameters;
      expect(search['limit'], '1');
      expect(search.containsKey('q'), isFalse);
      expect(search.containsKey('cat'), isFalse);
      expect(events, ['one:all:answered', 'one:all:answered']);
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok('<error code="201"/>');
      expect((await nz.test(i)).ok, isTrue);
    });

    test('fails on a login page, a refusal with an error status, and a rejected key', () async {
      final i = fake.indexer();
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok('<html><body>Log in</body></html>');
      expect((await nz.test(i)).ok, isFalse);
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : status(400, '<error code="201"/>');
      expect((await nz.test(i)).ok, isFalse);
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok('<error code="100"/>');
      final r = await nz.test(i);
      expect(r.ok, isFalse);
      expect(nz.status(i).problem, IndexerProblem.auth);
      expect(r.message, isNot(contains('secret')));
      expect((await nz.test(UsenetIndexer(name: '', apiUrl: 'nope'))).ok, isFalse);
    });

    test('ignores a pause and the kept capabilities', () async {
      final i = fake.indexer();
      fake.reply = (_) => status(429, '', {'Retry-After': '600'});
      await expectLater(nz.capabilities(i), throwsA(isA<NewznabFailure>()));
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok(rss(const []));
      expect((await nz.test(i)).ok, isTrue);
      expect((await nz.test(i)).ok, isTrue);
      expect(fake.of('caps'), hasLength(3));
    });
  });

  group('season searches', () {
    String url(String t) => 'https://h.test/get/$t';
    Reply Function(Uri) indexerOf({required Reply Function(Uri) season, required List<String> Function(int ep) episodes}) => (uri) {
      final q = uri.queryParameters;
      if (q['t'] == 'caps') return ok(caps());
      if (q['ep'] == null) return season(uri);
      return ok(rss([for (final t in episodes(int.parse(q['ep']!))) item(t, url(t))]));
    };
    UsenetSearchRequest ep(int n) => UsenetSearchRequest(imdbId: 'tt1', season: 1, episode: n, series: true);
    Future<List<String>> find(UsenetIndexer i, int n, {int results = 200}) async {
      final c = await nz.capabilities(i);
      return [for (final r in await nz.search(i, ep(n), c, results, kind: 'show')) r.title];
    }

    List<String?> eps() => [for (final u in fake.requests) if (u.queryParameters['t'] == 'tvsearch') u.queryParameters['ep']];

    test('one season search serves its episodes', () async {
      fake.reply = indexerOf(
        season: (_) => ok(rss([for (final t in ['Show.S01E01.1080p', 'Show.S01.2160p', 'Show.S01E02.1080p', 'a8f3k2b9']) item(t, url(t))])),
        episodes: (n) => n == 1 ? ['Show.S01E01.1080p', 'Show.S01E01.2160p'] : ['Show.S01E02.2160p'],
      );
      final i = fake.indexer();
      expect(await find(i, 1), ['Show.S01E01.1080p', 'Show.S01E01.2160p', 'Show.S01.2160p']);
      expect(await find(i, 2), ['Show.S01E02.2160p', 'Show.S01.2160p', 'Show.S01E02.1080p']);
      expect(eps()..sort((a, b) => (a ?? '').compareTo(b ?? '')), [null, '1', '2']);
      expect(fake.requests.where((u) => u.queryParameters['t'] == 'tvsearch').every((u) => u.queryParameters['season'] == '1'), isTrue);
      expect(events.where((e) => e.contains(':show:')), hasLength(3));
    });

    test('a failed episode search keeps the season', () async {
      fake.reply = (uri) {
        final q = uri.queryParameters;
        if (q['t'] == 'caps') return ok(caps());
        if (q['ep'] == null) return ok(rss([item('Show.S01.1080p', url('Show.S01.1080p'))]));
        return status(500);
      };
      expect(await find(fake.indexer(), 4), ['Show.S01.1080p']);
    });

    test('a refused season search is not asked again', () async {
      for (final refusal in [status(400), ok('<error code="201"/>')]) {
        await nz.clear();
        fake.requests.clear();
        fake.reply = indexerOf(season: (_) => refusal, episodes: (n) => ['Show.S01E0$n.1080p']);
        final i = fake.indexer();
        expect(await find(i, 5), ['Show.S01E05.1080p']);
        expect(await find(i, 6), ['Show.S01E06.1080p']);
        expect(eps()..sort((a, b) => (a ?? '').compareTo(b ?? '')), [null, '5', '6']);
      }
    });

    test('a season search that failed is asked again', () async {
      var first = true;
      fake.reply = indexerOf(
        season: (_) {
          if (first) {
            first = false;
            return status(503);
          }
          return ok(rss([item('Show.S01.1080p', url('Show.S01.1080p'))]));
        },
        episodes: (n) => ['Show.S01E0$n.1080p'],
      );
      final i = fake.indexer();
      expect(await find(i, 1), ['Show.S01E01.1080p']);
      expect(await find(i, 2), ['Show.S01E02.1080p', 'Show.S01.1080p']);
    });

    test('another indexer of the same endpoint and key', () async {
      fake.reply = indexerOf(season: (_) => ok(rss([item('Show.S01.1080p', url('Show.S01.1080p'))])), episodes: (_) => const []);
      final a = fake.indexer(id: 'a', name: 'A'), b = fake.indexer(id: 'b', name: 'B');
      await find(a, 2);
      final c = await nz.capabilities(b);
      final got = await nz.search(b, ep(2), c, 200);
      expect(got.single.indexerId, 'b');
      expect(got.single.indexerName, 'B');
      expect(eps().where((e) => e == null), hasLength(1));
    });

    test('a changed fetch limit reads the season again', () async {
      fake.reply = (uri) {
        final q = uri.queryParameters;
        if (q['t'] == 'caps') return ok(caps(limit: 1));
        if (q['ep'] != null) return ok(rss(const []));
        final o = int.parse(q['offset']!);
        final t = ['Show.S01.1080p', 'Show.S01.720p', 'Show.S01.2160p'];
        return ok(rss([if (o < 3) item(t[o], url(t[o]))]));
      };
      final i = fake.indexer();
      expect(await find(i, 1, results: 1), hasLength(1));
      expect(await find(i, 1, results: 0), hasLength(3));
      final asked = eps().length;
      expect(await find(i, 1, results: 0), hasLength(3));
      expect(eps().where((e) => e == null).length, 1 + 4);
      expect(eps().length, asked + 1); // only the episode search
    });

    test('fetch limits of 100 and 200 with totals of 500', () async {
      fake.reply = (uri) {
        final q = uri.queryParameters;
        if (q['t'] == 'caps') return ok(caps());
        final o = int.parse(q['offset']!), l = int.parse(q['limit']!);
        final prefix = q['ep'] == null ? 'Show.S01.P' : 'Show.S01E01.P';
        return ok(rss([for (var n = o; n < o + l; n++) item('$prefix$n', url('$prefix$n${q['ep'] ?? ''}'))], total: 500));
      };
      final i = fake.indexer();
      await find(i, 1, results: 100);
      expect(fake.requests.where((u) => u.queryParameters['t'] == 'tvsearch'), hasLength(2));
      fake.requests.clear();
      await find(i, 1, results: 200);
      expect(fake.requests.where((u) => u.queryParameters['t'] == 'tvsearch'), hasLength(4));
    });
  });

  group('statistics', () {
    test('what each request counts as', () async {
      final i = fake.indexer();
      fake.reply = (uri) => uri.queryParameters['t'] == 'caps' ? ok(caps()) : ok(rss([item('Show.S01E02.1080p', 'https://h.test/1')]));
      final c = await nz.capabilities(i);
      await nz.search(i, series12, c, 200, kind: 'show');
      expect(events, ['one:all:answered', 'one:show:answered', 'one:show:answered']);
      fake.reply = (_) => status(401);
      await expectLater(nz.search(i, const UsenetSearchRequest(imdbId: 'tt9'), c, 200, kind: 'movie'), throwsA(isA<NewznabFailure>()));
      fake.reply = (_) => status(429);
      await expectLater(nz.search(i, const UsenetSearchRequest(imdbId: 'tt9'), c, 200, kind: 'movie'), throwsA(isA<NewznabFailure>()));
      await expectLater(nz.search(i, const UsenetSearchRequest(imdbId: 'tt9'), c, 200, kind: 'movie'), throwsA(isA<NewznabFailure>()));
      expect(events.sublist(3), ['one:movie:failed', 'one:movie:limited']);
      expect(events, hasLength(5));
      expect(events.where((e) => e.endsWith('answered')), hasLength(3));
      fake.reply = (_) => ok(caps());
      await nz.capabilities(fake.indexer(key: 'rotated-key-999'));
      expect(events, hasLength(6));
      expect(events.last, 'one:all:answered');
    });
  });
}
