// The built-in Usenet search end to end against indexers on this computer and a TMDB that
// answers as each test says: what is asked, tiers, asking again, film and series checks, anime
// ids, timing, the kept searches, labels, binge groups, kept links and the search statistics
// (the Usenet search spec, sections 3, 6, 9 and 10).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/newznab.dart';
import 'package:vyse_tv/data/usenet/usenet_names.dart';
import 'package:vyse_tv/data/usenet/usenet_ranking.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_search.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

typedef Reply = ({int status, String body});

Reply ok(String body) => (status: 200, body: body);
Reply status(int code, [String body = '']) => (status: code, body: body);

String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');

String caps({String movie = 'q,imdbid,tmdbid,year', String tv = 'q,imdbid,tvdbid,season,ep'}) =>
    '<caps><limits max="100"/><searching><search available="yes" supportedParams="q"/>'
    '<tv-search available="${tv.isEmpty ? 'no' : 'yes'}" supportedParams="$tv"/><movie-search available="${movie.isEmpty ? 'no' : 'yes'}" supportedParams="$movie"/></searching></caps>';

const gib = 1073741824;

String rss(List<String> titles, {String host = 'h.test', int size = 2 * gib, int? posted}) =>
    '<rss xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/"><channel>${[
      for (final t in titles)
        '<item><title>${esc(t)}</title><enclosure url="https://$host/get/${esc(Uri.encodeComponent(t))}?apikey=secret" length="$size" type="application/x-nzb"/>'
            '<newznab:attr name="size" value="${t.contains('.S01.') ? 9 * gib : size}"/>${posted == null ? '' : '<newznab:attr name="usenetdate" value="$posted"/>'}</item>',
    ].join()}</channel></rss>';

/// An indexer on this computer.
class Fake {
  Fake(this.name, {this.priority = 1});
  final String name;
  final int priority;
  late HttpServer server;
  final requests = <Uri>[];
  String capsXml = caps();
  FutureOr<Reply> Function(Uri uri) search = (_) => ok(rss(const []));

  Future<Fake> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      final r = req.uri.queryParameters['t'] == 'caps' ? ok(capsXml) : await search(req.uri);
      req.response.statusCode = r.status;
      req.response.add(utf8.encode(r.body));
      await req.response.close();
    });
    return this;
  }

  UsenetIndexer get indexer => UsenetIndexer(id: name.toLowerCase(), name: name, apiUrl: 'http://127.0.0.1:${server.port}', apiPath: '/api', apiKey: 'key-$name-secret', priority: priority);
  List<Uri> get searches => [for (final u in requests) if (u.queryParameters['t'] != 'caps') u];
  bool get askedCaps => requests.any((u) => u.queryParameters['t'] == 'caps');
}

final provider = UsenetProvider(id: 'p', name: 'P', host: 'news.example.test', username: 'u', password: 'pw');

void configure(List<Fake> fakes, {bool fallback = false, bool progressive = false, int maxSizeGb = 0, UsenetSort sort = UsenetSort.quality, bool showNames = true}) =>
    UsenetSourcesStore.debugSet(
      UsenetSources(
        providers: [provider],
        indexers: [for (final f in fakes) f.indexer],
        indexerFallback: fallback,
        progressiveResults: progressive,
        maxSizeGb: maxSizeGb,
        sort: sort,
        showReleaseNames: showNames,
      ),
    );

final tmdbCalls = <String>[];
var tmdb = <String, FutureOr<Map<String, dynamic>> Function(Map<String, String> q)>{};
var mapping = <String, Map<String, dynamic>>{};
final mappingCalls = <String>[];

Future<UsenetResults?> find(AddonTarget t, {List<List<AddonStream>>? lists, List<int>? at}) {
  final watch = Stopwatch()..start();
  return UsenetSearch.instance.search(
    Addon.usenet,
    t,
    onSome: (soFar) {
      lists?.add(soFar);
      at?.add(watch.elapsedMilliseconds);
    },
  );
}

List<String> titles(UsenetResults? r) => [for (final s in r?.streams ?? const <AddonStream>[]) (s.usenetRelease as UsenetRelease).title];

Map<String, dynamic> koreanSuits() => {
  'id': 77548,
  'name': 'Suits',
  'original_name': '슈츠',
  'first_air_date': '2018-04-25',
  'vote_count': 24,
  'origin_country': ['KR'],
  'seasons': [
    {'season_number': 1, 'episode_count': 16, 'air_date': '2018-04-25'},
  ],
  'external_ids': {'imdb_id': 'tt8084058', 'tvdb_id': 336811},
};

Map<String, dynamic> suitsSearch() => {
  'results': [
    {'id': 37680, 'name': 'Suits', 'original_name': 'Suits', 'first_air_date': '2011-06-23', 'origin_country': ['US'], 'vote_count': 6055},
    {'id': 77548, 'name': 'Suits', 'original_name': '슈츠', 'first_air_date': '2018-04-25', 'origin_country': ['KR'], 'vote_count': 24},
    {'id': 259453, 'name': 'Suits LA', 'original_name': 'Suits LA', 'first_air_date': '2025-02-23', 'origin_country': ['US'], 'vote_count': 66},
  ],
};

const korean = AddonTarget(type: 'series', imdb: 'tt8084058', tmdb: 77548, season: 1, episode: 2);

Map<String, dynamic> movie(int id, String title, String date, {String? original, List<String> alt = const [], List<String> translations = const []}) => {
  'id': id,
  'title': title,
  'original_title': original ?? title,
  'release_date': date,
  'runtime': 120,
  'alternative_titles': {
    'titles': [for (final a in alt) {'title': a}],
  },
  'translations': {
    'translations': [
      for (final t in translations)
        {
          'data': {'title': t},
        },
    ],
  },
  'external_ids': {'imdb_id': 'tt$id'},
};

void main() {
  final fakes = <Fake>[];
  final searched = <String>[];

  Future<Fake> fake(String name, {int priority = 1}) async {
    final f = await Fake(name, priority: priority).start();
    fakes.add(f);
    return f;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Newznab.instance.clear();
    await UsenetReleases.clear();
    UsenetSearch.instance.forget();
    UsenetClock.debugNow = DateTime.now;
    UsenetSearch.partialWait = const Duration(milliseconds: 700);
    UsenetSearch.lookupWait = const Duration(milliseconds: 300);
    UsenetSearch.animeWait = const Duration(milliseconds: 300);
    tmdbCalls.clear();
    tmdb = {};
    mapping = {};
    mappingCalls.clear();
    UsenetSearch.tmdbGet = (path, q) async {
      tmdbCalls.add(path);
      final h = tmdb[path];
      if (h == null) throw TmdbException('TMDB returned 404 for $path');
      return await h(q);
    };
    UsenetSearch.animeMapping = (prefix, id) async {
      mappingCalls.add('$prefix:$id');
      return mapping['$prefix:$id'];
    };
    searched.clear();
    UsenetSearch.onSearch = (id, kind, outcome, n, urls) => searched.add('$id:$kind:$outcome:$n');
  });

  tearDown(() async {
    UsenetSearch.onSearch = null;
    for (final f in fakes) {
      await f.server.close(force: true);
    }
    fakes.clear();
  });

  group('what is searched', () {
    test('nothing without usable sources or a numbered episode', () async {
      final a = await fake('A');
      UsenetSourcesStore.debugSet(UsenetSources(indexers: [a.indexer]));
      expect(await find(const AddonTarget(type: 'movie', imdb: 'tt1')), isNull);
      configure([a]);
      expect(await find(const AddonTarget(type: 'series', imdb: 'tt1')), isNull);
      expect(await find(const AddonTarget(type: 'series', imdb: 'tt1', season: 1)), isNull);
      expect(await find(const AddonTarget(type: 'channel', imdb: 'tt1')), isNull);
      expect(a.requests, isEmpty);
      expect(UsenetSearch.canSearch(const AddonTarget(type: 'movie', imdb: 'tt123')), isTrue);
      expect(UsenetSearch.canSearch(const AddonTarget(type: 'series', imdb: 'tt123', season: 1, episode: 2)), isTrue);
      expect(UsenetSearch.canSearch(const AddonTarget(type: 'tv', tmdb: 10, season: 0, episode: 3)), isTrue);
      expect(UsenetSearch.canSearch(const AddonTarget(type: 'series', imdb: 'tt123')), isFalse);
    });

    test('a film by its id, and its streams', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(['Movie.2020.2160p.WEB-DL.DDP5.1.H.265-GRP', 'Movie.2020.1080p.WEB-DL-GRP'], posted: DateTime.now().subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000));
      configure([a]);
      tmdb['/movie/10'] = (_) => movie(10, 'Movie', '2020-05-01');
      final r = await find(const AddonTarget(type: 'movie', imdb: 'tt10', tmdb: 10, title: 'Movie', year: 2020));
      expect(titles(r), ['Movie.2020.2160p.WEB-DL.DDP5.1.H.265-GRP', 'Movie.2020.1080p.WEB-DL-GRP']);
      final q = a.searches.single.queryParameters;
      expect(q['imdbid'], '10');
      expect(q['cat'], '2000');
      final s = r!.streams.first;
      expect(s.addon, Addon.usenet);
      expect(s.url, '');
      expect(s.nzbUrl, contains('apikey=secret'));
      expect(s.usenetServers, isEmpty);
      expect(s.name, '4K WEB-DL • HEVC');
      expect(s.description, 'Movie.2020.2160p.WEB-DL.DDP5.1.H.265-GRP\nDD+ 5.1 • 2.00 GB • 2.4 Mbps • 3d • A');
      expect(s.sizeBytes, 2 * gib);
      expect(s.bingeGroup, 'Built-in Usenet|movie.2020.2160p.web-dl.ddp5.1.h.265-grp');
      expect((s.usenetRelease as UsenetRelease).season, isNull);
      expect(r.failures, isEmpty);
      expect(searched, ['a:movie:answered:2']);
    });

    test('an episode carries the numbers it was searched by', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(['Show.S01E03.1080p-GRP']));
      configure([a]);
      final r = await find(const AddonTarget(type: 'series', imdb: 'tt123', season: 1, episode: 3));
      final release = r!.streams.single.usenetRelease as UsenetRelease;
      expect((release.season, release.episode), (1, 3));
      expect(mappingCalls, isEmpty);
      expect(a.searches.map((u) => u.queryParameters['ep']).toSet(), {null, '3'});
    });

    test('a failed metadata lookup fails only indexers that need a title', () async {
      final a = await fake('A'), b = await fake('B');
      a.capsXml = caps(movie: 'imdbid');
      b.capsXml = caps(movie: 'q');
      a.search = (_) => ok(rss(['Film.2020.1080p-GRP']));
      configure([a, b]);
      final r = await find(const AddonTarget(type: 'movie', imdb: 'tt5'));
      expect(titles(r), ['Film.2020.1080p-GRP']);
      expect(r!.failures, ['B: indexer search failed. Check the API URL, key and limits.']);
      expect(b.searches, isEmpty);
      expect(searched..sort(), ['a:movie:answered:1', 'b:movie:failed:0']);
    });

    test('an indexer that searches TV by TheTVDB gets its id from TMDB', () async {
      final a = await fake('A');
      a.capsXml = caps(tv: 'tvdbid,season,ep');
      a.search = (uri) => ok(rss(uri.queryParameters['tvdbid'] == '336811' ? ['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG'] : const []));
      configure([a]);
      tmdb['/tv/77548'] = (_) => koreanSuits();
      tmdb['/search/tv'] = (_) => suitsSearch();
      expect(titles(await find(korean)), ['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG']);
    });

    test('a raw failure never shows', () async {
      final a = await fake('A');
      a.capsXml = 'secret-api-key';
      configure([a]);
      final r = await find(const AddonTarget(type: 'movie', imdb: 'tt5'));
      expect(r!.failures, ['A: indexer search failed. Check the API URL, key and limits.']);
      expect(r.failures.single, isNot(contains('secret')));
    });

    test('a paused indexer says until when', () async {
      final a = await fake('A');
      a.search = (_) => status(429);
      configure([a]);
      final r = await find(const AddonTarget(type: 'movie', imdb: 'tt5'));
      expect(r!.failures.single, matches(RegExp(r'^A: indexer limit reached, paused until \d\d:\d\d\.$')));
      expect(searched, ['a:movie:paused:0']);
    });
  });

  group('tiers', () {
    test('lower priorities only when nothing was listed', () async {
      final c = await fake('C', priority: 2), a = await fake('A'), b = await fake('B');
      a.search = (_) => ok(rss(['Film.2020.1080p-A']));
      c.search = (_) => ok(rss(['Film.2020.1080p-C']));
      configure([c, a, b], fallback: true);
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt5'))), ['Film.2020.1080p-A']);
      expect(b.searches, isNotEmpty);
      expect(c.askedCaps, isFalse);
      UsenetSearch.instance.forget();
      a.search = (_) => status(500);
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt6'))), ['Film.2020.1080p-C']);
    });

    test('without fallback every indexer is asked', () async {
      final c = await fake('C', priority: 2), a = await fake('A');
      a.search = (_) => ok(rss(['Film.2020.1080p-A']));
      c.search = (_) => ok(rss(['Film.2020.1080p-C']));
      configure([c, a]);
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt5'))).toSet(), {'Film.2020.1080p-A', 'Film.2020.1080p-C'});
    });
  });

  group('asking again', () {
    test('by title after an empty id search, never twice', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(uri.queryParameters['q'] != null && uri.queryParameters['year'] == '2020' ? ['The.Movie.2020.1080p'] : const []));
      configure([a]);
      tmdb['/movie/20'] = (_) => movie(20, 'The Movie', '2020-01-01');
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt20', tmdb: 20))), ['The.Movie.2020.1080p']);
      final byTitle = a.searches.where((u) => u.queryParameters['q'] != null).single.queryParameters;
      expect(byTitle['q'], 'The Movie');
      expect(byTitle.containsKey('imdbid'), isFalse);
      expect(byTitle.containsKey('tmdbid'), isFalse);
      a.search = (_) => ok(rss(const []));
      a.requests.clear();
      UsenetSearch.instance.forget();
      await find(const AddonTarget(type: 'movie', imdb: 'tt20', tmdb: 20));
      await find(const AddonTarget(type: 'movie', imdb: 'tt20', tmdb: 20));
      expect(a.searches.where((u) => u.queryParameters['q'] != null), hasLength(2));
    });

    test('by the original title, in Latin script only', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(uri.queryParameters['q'] == 'La casa de papel' ? ['La.Casa.de.Papel.2017.1080p'] : const []));
      configure([a]);
      tmdb['/movie/30'] = (_) => movie(30, 'Money Heist', '2017-05-02', original: 'La casa de papel');
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt30', tmdb: 30))), ['La.Casa.de.Papel.2017.1080p']);
      UsenetSearch.instance.forget();
      a.requests.clear();
      tmdb['/movie/30'] = (_) => movie(30, 'Money Heist', '2017-05-02', original: 'ペーパー・ハウス');
      expect(await find(const AddonTarget(type: 'movie', imdb: 'tt30', tmdb: 30)), isNotNull);
      expect(a.searches.map((u) => u.queryParameters['q']).whereType<String>(), ['Money Heist']);
    });
  });

  group('films by id', () {
    test('a film of another year under its id', () async {
      final a = await fake('A');
      a.search = (_) => ok(rss([
        'Harry.Potter.und.die.Heiligtuemer.des.Todes.Teil.2.2011.German.DL.2160p.HDR.BluRay.AV1-Bi0hazard',
        'Harry.Potter.and.the.Sorcerers.Stone.2001.2160p.UHD.BluRay.x265',
      ]));
      configure([a]);
      tmdb['/movie/671'] = (_) => movie(671, "Harry Potter and the Philosopher's Stone", '2001-11-16', alt: ["Harry Potter and the Sorcerer's Stone"]);
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt671', tmdb: 671))), ['Harry.Potter.and.the.Sorcerers.Stone.2001.2160p.UHD.BluRay.x265']);
      UsenetSearch.instance.forget();
      tmdb.clear();
      expect(titles(await find(const AddonTarget(type: 'movie', imdb: 'tt671', tmdb: 671))), hasLength(2));
    });

    test('another film of the same year under its id', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(uri.queryParameters['q'] == null
          ? ['The.Lord.of.the.Rings.The.Two.Towers.2002.1080p', 'The.Ring.2002.1080p']
          : ['The.Lord.of.the.Rings.The.Two.Towers.2002.720p']));
      configure([a]);
      tmdb['/movie/121'] = (_) => movie(121, 'The Lord of the Rings: The Two Towers', '2002-12-18', translations: ['Der Herr der Ringe - Die zwei Türme']);
      const t = AddonTarget(type: 'movie', imdb: 'tt0167261', tmdb: 121);
      expect(titles(await find(t)), ['The.Lord.of.the.Rings.The.Two.Towers.2002.1080p']);
      UsenetSearch.instance.forget();
      a.search = (uri) => ok(rss(uri.queryParameters['q'] == null ? ['The.Ring.2002.1080p'] : ['The.Lord.of.the.Rings.The.Two.Towers.2002.720p']));
      expect(titles(await find(t)), ['The.Lord.of.the.Rings.The.Two.Towers.2002.720p']);
      UsenetSearch.instance.forget();
      tmdb.clear();
      expect(titles(await find(t)), ['The.Ring.2002.1080p']);
    });
  });

  group('series of one name', () {
    Future<Fake> suits(List<String> found) async {
      final a = await fake('A');
      a.search = (_) => ok(rss(found));
      configure([a]);
      tmdb['/tv/77548'] = (_) => koreanSuits();
      tmdb['/search/tv'] = (_) => suitsSearch();
      return a;
    }

    test('another series of its name is dropped once its details come', () async {
      await suits(['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG', 'Suits.S01E02.1080p.BluRay-GERUDO', 'Suits.S01E02.2011.1080p.WEB-DL-DBTV']);
      expect(titles(await find(korean)), ['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG']);
      UsenetSearch.instance.forget();
      tmdb['/search/tv'] = (_) => throw const SocketException('offline');
      expect(titles(await find(korean)).toSet(), {'Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG', 'Suits.S01E02.1080p.BluRay-GERUDO'});
      UsenetSearch.instance.forget();
      tmdb.remove('/tv/77548');
      expect(titles(await find(korean)), hasLength(3));
      UsenetSearch.instance.forget();
      // the title's own year, when TMDB can't say
      expect(titles(await find(const AddonTarget(type: 'series', imdb: 'tt8084058', tmdb: 77548, season: 1, episode: 2, title: 'Suits', year: 2018))), hasLength(2));
    });

    test('the list never waits for the details, and is arranged again', () async {
      await suits(['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG', 'Suits.S01E02.1080p.BluRay-GERUDO']);
      tmdb['/tv/77548'] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return koreanSuits();
      };
      final lists = <List<AddonStream>>[];
      final at = <int>[];
      final r = await find(korean, lists: lists, at: at);
      expect(lists, hasLength(2));
      expect(lists.first, hasLength(2));
      expect(at.first, lessThan(120));
      expect(at.last, greaterThanOrEqualTo(140));
      expect(titles(r), ['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG']);
      UsenetSearch.instance.forget();
      tmdb['/tv/77548'] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return koreanSuits();
      };
      lists.clear();
      await find(korean, lists: lists);
      expect(lists, hasLength(1));
    });

    test('an id search that found only the other series asks by title', () async {
      final a = await fake('A');
      a.capsXml = caps(tv: 'imdbid,q,season,ep');
      a.search = (uri) async {
        if (uri.queryParameters['q'] != null) return ok(rss(['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG']));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return ok(rss(['Suits.S01E02.2011.1080p.WEB-DL-DBTV']));
      };
      configure([a]);
      tmdb['/tv/77548'] = (_) => koreanSuits();
      tmdb['/search/tv'] = (_) => suitsSearch();
      expect(titles(await find(korean)), ['Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG']);
      expect(a.searches.where((u) => u.queryParameters['q'] == 'Suits S01E02'), hasLength(1));
    });
  });

  group('anime catalog ids', () {
    test('the details say where IMDb counts the episode', () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(uri.queryParameters['season'] == '2' ? ['Frieren.S02E01.1080p.WEB-DL-GRP'] : const []));
      configure([a]);
      const t = AddonTarget(type: 'series', raw: 'kitsu:49240', video: 'kitsu:49240:1', imdb: 'tt22248376', season: 1, episode: 1, imdbSeason: 2, imdbEpisode: 1);
      final r = await find(t);
      final release = r!.streams.single.usenetRelease as UsenetRelease;
      expect((release.season, release.episode), (2, 1));
      expect(a.searches.every((u) => u.queryParameters['season'] == '2' && u.queryParameters['imdbid'] == '22248376'), isTrue);
      expect(mappingCalls, isEmpty);
    });

    test("the title's own IMDb id", () async {
      final a = await fake('A');
      a.search = (_) => ok(rss(['Show.S03E02.1080p-GRP']));
      configure([a]);
      await find(const AddonTarget(type: 'series', raw: 'tt777', video: 'kitsu:9:40', season: 3, episode: 2, imdbSeason: 3, imdbEpisode: 2));
      expect(a.searches.map((u) => (u.queryParameters['imdbid'], u.queryParameters['season'])).toSet(), {('777', '3')});
    });

    test("the anime databases' numbering", () async {
      final a = await fake('A');
      a.search = (_) => ok(rss(['Frieren.S02E01.1080p.WEB-DL-GRP']));
      configure([a]);
      mapping['mal:52991'] = {
        'mappings': {'imdb_id': 'tt22248376', 'thetvdb_id': 424536},
        'episodes': {
          '1': {'seasonNumber': 2, 'episodeNumber': 1},
        },
      };
      final r = await find(const AddonTarget(type: 'series', raw: 'mal:52991', video: 'mal:52991:1', title: 'Frieren', season: 1, episode: 1));
      expect(titles(r), ['Frieren.S02E01.1080p.WEB-DL-GRP']);
      expect(a.searches.map((u) => (u.queryParameters['imdbid'], u.queryParameters['season'], u.queryParameters['ep'])).toSet(), {('22248376', '2', '1'), ('22248376', '2', null)});
      UsenetSearch.instance.forget();
      mapping['mal:52991']!['mappings'] = {'imdb_id': 'tt999'};
      mapping['mal:52991']!['episodes'] = {
        '1': {'seasonNumber': 1, 'episodeNumber': 5},
      };
      a.requests.clear();
      await find(const AddonTarget(type: 'series', raw: 'mal:52991', video: 'mal:52991:1', imdb: 'not-an-id', season: 1, episode: 1));
      expect(a.searches.map((u) => (u.queryParameters['imdbid'], u.queryParameters['ep'])).toSet(), {('999', '5'), ('999', null)});
    });

    test('an anime from AniList by its Kitsu id', () async {
      final a = await fake('A');
      a.search = (_) => ok(rss(['Attack.on.Titan.S01E05.1080p-GRP']));
      configure([a]);
      mapping['kitsu:7442'] = {
        'mappings': {'imdb_id': 'tt2560140', 'thetvdb_id': 267440},
        'episodes': {
          '5': {'seasonNumber': 1, 'episodeNumber': 5},
        },
      };
      final r = await find(const AddonTarget(type: 'series', kitsu: 7442, episode: 5, anime: true, imdb: 'tt2560140'));
      expect(titles(r), ['Attack.on.Titan.S01E05.1080p-GRP']);
    });

    test('nothing maps: nothing is searched', () async {
      final a = await fake('A');
      configure([a]);
      expect(await find(const AddonTarget(type: 'series', raw: 'kitsu:1', video: 'kitsu:1:5', title: 'Something', season: 1, episode: 5)), isNull);
      expect(a.requests, isEmpty);
    });
  });

  group('timing', () {
    test('the list shows once every indexer answered', () async {
      final a = await fake('A'), b = await fake('B');
      a.search = (_) => ok(rss(['Film.2020.1080p-A']));
      b.search = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return ok(rss(['Film.2020.1080p-B']));
      };
      configure([a, b]);
      final lists = <List<AddonStream>>[];
      await find(const AddonTarget(type: 'movie', imdb: 'tt5'), lists: lists);
      expect(lists.map((l) => l.length), [2]);
      UsenetSearch.instance.forget();
      lists.clear();
      configure([a, b], progressive: true);
      await find(const AddonTarget(type: 'movie', imdb: 'tt5'), lists: lists);
      expect(lists.map((l) => l.length), [1, 2]);
    });

    test('a slow indexer: what came shows after the wait', () async {
      final a = await fake('A'), b = await fake('B');
      a.search = (_) => ok(rss(['Film.2020.1080p-A']));
      b.search = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        return ok(rss(['Film.2020.1080p-B']));
      };
      configure([a, b]);
      final lists = <List<AddonStream>>[];
      final at = <int>[];
      await find(const AddonTarget(type: 'movie', imdb: 'tt5'), lists: lists, at: at);
      expect(lists.map((l) => l.length), [1, 2]);
      expect(at.first, inInclusiveRange(650, 1300));
    });

    test("a season's episode count, never waited for long", () async {
      final a = await fake('A');
      a.search = (uri) => ok(rss(uri.queryParameters['ep'] == null ? const [] : ['Show.S01E02.1080p-GRP', 'Show.S01.1080p-GRP']));
      configure([a], maxSizeGb: 5);
      tmdb['/tv/50'] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return {
          'id': 50,
          'name': 'Show',
          'seasons': [
            {'season_number': 1, 'episode_count': 9},
          ],
        };
      };
      const t = AddonTarget(type: 'series', imdb: 'tt50', tmdb: 50, season: 1, episode: 2);
      final lists = <List<AddonStream>>[];
      await find(t, lists: lists);
      expect(lists.map((l) => l.length), [1]);
      UsenetSearch.instance.forget();
      lists.clear();
      tmdb['/tv/50'] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return {
          'id': 50,
          'name': 'Show',
          'seasons': [
            {'season_number': 1, 'episode_count': 9},
          ],
        };
      };
      final r = await find(t, lists: lists);
      expect(lists.map((l) => l.length), [1, 2]);
      final pack = r!.streams.firstWhere((s) => (s.usenetRelease as UsenetRelease).seasonPack);
      expect(pack.sizeBytes, gib);
      expect(pack.description, contains('9.00 GB whole season (~1.00 GB per episode)'));
      expect(UsenetSearch.badgesOf(pack).map((b) => b.text), ['SEASON PACK']);
      expect(tmdbCalls.where((p) => p == '/tv/50'), hasLength(2)); // once per search
    });
  });

  group('kept searches', () {
    test('reused, re-labelled, and searched again after a change', () async {
      final a = await fake('A');
      a.search = (_) => ok(rss(['Film.2020.2160p-DEAD', 'Film.2020.1080p-GOOD']));
      configure([a]);
      const t = AddonTarget(type: 'movie', imdb: 'tt5');
      final first = await find(t);
      final asked = a.requests.length;
      expect(titles(first), ['Film.2020.2160p-DEAD', 'Film.2020.1080p-GOOD']);
      UsenetReleases.failed(first!.streams.first, 'missing-article');
      final again = await find(t);
      expect(a.requests.length, asked);
      expect(titles(again), ['Film.2020.1080p-GOOD', 'Film.2020.2160p-DEAD']);
      expect(UsenetSearch.badgesOf(again!.streams.last).single.text, 'UNAVAILABLE');
      configure([a], sort: UsenetSort.newest);
      await find(t);
      expect(a.requests.length, greaterThan(asked));
    });

    test('an empty search is not kept', () async {
      final a = await fake('A');
      configure([a]);
      const t = AddonTarget(type: 'movie', imdb: 'tt5');
      await find(t);
      final asked = a.searches.length;
      await find(t);
      expect(a.searches.length, greaterThan(asked));
    });

    test('one search for two who ask at once', () async {
      final a = await fake('A');
      a.search = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return ok(rss(['Film.2020.1080p-A']));
      };
      configure([a]);
      const t = AddonTarget(type: 'movie', imdb: 'tt5');
      final both = await Future.wait([find(t), find(t)]);
      expect(both.map(titles), [
        ['Film.2020.1080p-A'],
        ['Film.2020.1080p-A'],
      ]);
      expect(a.searches, hasLength(1));
    });
  });

  group('labels', () {
    UsenetRelease r(String title, {double gb = 0, int days = -1, bool series = false}) => UsenetRelease(
      title: title,
      nzbUrl: 'https://a.test/1',
      indexerId: 'a',
      indexerName: 'A',
      size: (gb * gib).round(),
      publishedAt: days < 0 ? 0 : DateTime.now().subtract(Duration(days: days, hours: 1)).millisecondsSinceEpoch,
      series: series,
    );

    test('names', () {
      String name(String t, {RankingProfile? p}) => UsenetSearch.describe(r(t), showReleaseNames: true, profile: p).name;
      expect(name('Movie.2020.2160p-GRP'), '4K');
      expect(name('Movie.2020.720p-GRP'), '720p');
      expect(name('Movie.2020-GRP'), 'Usenet');
      expect(name('The.Movie.2026.2160p.UHD.BluRay.REMUX.DV.HDR10Plus.HEVC.TrueHD.Atmos.7.1-FraMeSToR', p: RankingPresets.bestQuality), '4K Remux • DV HDR10+ • HEVC • T1');
      expect(name('Tulsa.King.S01E01.2160p.AMZN.WEB-DL.DDP5.1.H.265-NTb'), '4K Prime WEB-DL • HEVC');
    });

    test('descriptions', () {
      String text(UsenetRelease x, {bool names = true, int? runtime, Map<int, int>? counts, bool badges = false}) =>
          UsenetSearch.describe(x, showReleaseNames: names, runtimeMinutes: runtime, seasonEpisodes: counts, sizeBadges: badges).description;
      expect(text(r('Movie.2020.1080p-GRP', gb: 2)), 'Movie.2020.1080p-GRP\n2.00 GB • A');
      expect(text(r('Movie.2020.1080p-GRP', gb: 2), names: false), '2.00 GB • A • GRP');
      const film = 'The.Movie.2026.2160p.UHD.BluRay.REMUX.DV.HDR10Plus.HEVC.TrueHD.Atmos.7.1-FraMeSToR';
      expect(text(r(film, gb: 60, days: 3), runtime: 120), '$film\nTrueHD 7.1 Atmos • 60.00 GB • 72 Mbps • 3d • A');
      expect(text(r(film, gb: 60, days: 3), runtime: 120, names: false), 'TrueHD 7.1 Atmos • 60.00 GB • 72 Mbps • 3d • A • FraMeSToR');
      expect(text(r('Show.S01.1080p-GRP', gb: 9, series: true), names: false, counts: {1: 9}), '9.00 GB whole season (~1.00 GB per episode) • A • GRP');
      expect(text(r('Show.S01-S03.1080p-GRP', gb: 34, series: true), names: false, counts: {1: 10, 2: 12, 3: 12}), '34.00 GB whole pack (~1.00 GB per episode) • A • GRP');
      expect(text(r('Show.S01.1080p-GRP', gb: 9, series: true), names: false), '9.00 GB (whole season) • A • GRP');
      expect(text(r('Show.S01-S03.1080p-GRP', gb: 34, series: true), names: false), '34.00 GB (whole pack) • A • GRP');
      expect(text(r('Movie.2020.1080p')), 'Movie.2020.1080p\nA');
      expect(text(r('Show.S01E02.1080p-GRP', gb: 2, series: true), names: false, badges: true), 'A • GRP');
      expect(text(r('Show.S01.1080p-GRP', gb: 9, series: true), names: false, badges: true, counts: {1: 9}), '9.00 GB whole season (~1.00 GB per episode) • A • GRP');
      expect(text(r('Show.S01E02.1080p-GRP', gb: 2, series: true), names: false), '2.00 GB • A • GRP');
      expect(text(r('Show.S01E02.1080p-GRP', gb: 0.5, series: true), names: false, runtime: 60, counts: {1: 9}), '0.50 GB • 1.2 Mbps • A • GRP');
      expect(text(r('Show.S01.1080p-GRP', gb: 9, series: true), names: false, runtime: 60, counts: {1: 9}), '9.00 GB whole season (~1.00 GB per episode) • ~2.4 Mbps • A • GRP');
    });

    test('the size a badge shows', () {
      int? size(UsenetRelease x, [Map<int, int>? c]) => UsenetSearch.describe(x, showReleaseNames: true, seasonEpisodes: c).videoSize;
      expect(size(r('Show.S01.1080p-GRP', gb: 9, series: true), {1: 9}), gib);
      expect(size(r('Show.S01-S03.1080p-GRP', gb: 34, series: true), {1: 10, 2: 12, 3: 12}), gib);
      expect(size(r('Movie.2020.COMPLETE.BLURAY-GRP', gb: 60)), 60 * gib);
      expect(size(r('Movie.2020.1080p')), isNull);
    });

    test('a Blu-ray badge', () {
      final x = r('Movie.2019.COMPLETE.UHD.BLURAY-GRP', gb: 60);
      final s = AddonStream(addon: Addon.usenet, url: '', text: '', nzbUrl: x.nzbUrl, usenetRelease: x);
      expect(UsenetSearch.badgesOf(s).map((b) => (b.text, b.kind)), [('UHD BLU-RAY', UsenetBadgeKind.other)]);
      expect(const UsenetBadge('AVAILABLE', UsenetBadgeKind.available).color, 0xFF198754);
    });
  });

  group('binge groups', () {
    test('an upload, a pack, a film', () {
      String? g(String t, {bool series = true}) => UsenetSearch.bingeGroupOf(t, series: series);
      final e1 = g('Silo.S01E01.Freedom.Day.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb');
      expect(e1, g('Silo.S01E02.Holstons.Pick.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb'));
      expect(e1, isNot(g('Silo.S01E02.Holstons.Pick.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-FLUX')));
      expect(e1, isNot(g('Silo.S02E01.The.Engineer.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb')));
      expect(g('Silo.S01.2160p.ATVp.WEB-DL-NTb'), g('silo.s01.2160p.atvp.web-dl-ntb'));
      expect(g('Silo.S01.2160p.ATVp.WEB-DL-NTb'), 'Built-in Usenet|silo.s01.2160p.atvp.web-dl-ntb');
      expect(g('Movie.2020.1080p.WEB-DL-GRP'), isNull);
      expect(g('Movie.2020.1080p.BluRay-OTHER', series: false), 'Built-in Usenet|movie.2020.1080p.bluray-other');
    });
  });

  group('kept links', () {
    test('keys out, keys back', () {
      final i = UsenetIndexer(id: 'idx', name: 'A', apiUrl: 'https://a.test', apiKey: '0123456789abcdef');
      const url = 'https://a.test/api?t=get&id=1&apikey=0123456789abcdef';
      final kept = UsenetSearch.keylessLink(url, [i]);
      expect(kept, 'https://a.test/api?t=get&id=1&apikey={indexer-key:idx}');
      expect(UsenetSearch.linkIndexer(kept), 'idx');
      final renewed = i.copyWith(apiKey: 'fedcba9876543210');
      expect(UsenetSearch.keyedLink(kept, [renewed]), 'https://a.test/api?t=get&id=1&apikey=fedcba9876543210');
      expect(UsenetSearch.keyedLink(UsenetSearch.keylessLink('https://a.test/0123456789abcdef/1.nzb', [i]), [renewed]), 'https://a.test/fedcba9876543210/1.nzb');
      expect(UsenetSearch.keyedLink(kept, const []), isNull);
      expect(UsenetSearch.keyedLink(kept, [i.copyWith(apiKey: '')]), isNull);
      expect(UsenetSearch.keylessLink('https://b.test/nzb/1', [i]), 'https://b.test/nzb/1');
      expect(UsenetSearch.keyedLink('https://b.test/nzb/1', const []), 'https://b.test/nzb/1');
      expect(UsenetSearch.keylessLink('https://a.test/?k=short', [UsenetIndexer(id: 's', apiKey: 'short')]), 'https://a.test/?k=short');
    });
  });

  group('statistics', () {
    test('a series search', () async {
      final a = await fake('A');
      a.search = (_) => ok(rss(['Show.S01E02.1080p-GRP']));
      configure([a]);
      final requests = <String>[];
      Newznab.onRequest = (id, kind, outcome, ms) => requests.add('$id:${kind ?? 'all'}:$outcome');
      addTearDown(() => Newznab.onRequest = null);
      await find(const AddonTarget(type: 'series', imdb: 'tt123', season: 1, episode: 2));
      expect(requests, ['a:all:answered', 'a:show:answered', 'a:show:answered']);
      expect(searched, ['a:show:answered:1']);
    });
  });
}
