// Filters, the plain sorts, sorting profiles and presets, de-duplication and the result limit
// (the Usenet search spec, sections 5 and 7).

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/usenet_names.dart';
import 'package:vyse_tv/data/usenet/usenet_ranking.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

const gib = 1073741824;
const day = 86400000;
final now = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;

var _n = 0;
UsenetRelease rel(String title, {double? gb, int? bytes, int? at, String indexer = 'one', String? url, bool passworded = false, bool series = false}) => UsenetRelease(
  title: title,
  nzbUrl: url ?? 'https://$indexer.test/get/${_n++}',
  indexerId: indexer,
  indexerName: indexer,
  size: bytes ?? (gb == null ? 0 : (gb * gib).round()),
  publishedAt: at ?? 0,
  passworded: passworded,
  series: series,
);

UsenetIndexer idx(String id, {int priority = 1}) => UsenetIndexer(id: id, name: id, apiUrl: 'https://$id.test', apiPath: '/api', apiKey: 'key-$id', priority: priority);

UsenetSources cfg({
  UsenetPreset preset = UsenetPreset.original,
  UsenetSort sort = UsenetSort.quality,
  RankingProfile? custom,
  String language = '',
  int maxResults = 50,
  int minResolution = 0,
  int maxSizeGb = 0,
  int maxAgeDays = 0,
  bool excludeFullDisc = false,
  List<UsenetIndexer>? indexers,
}) => UsenetSources(
  indexers: indexers ?? [idx('one')],
  preset: preset,
  sort: sort,
  customProfile: custom?.toJson(),
  preferredLanguage: language,
  maxResults: maxResults,
  minResolution: minResolution,
  maxSizeGb: maxSizeGb,
  maxAgeDays: maxAgeDays,
  excludeFullDisc: excludeFullDisc,
);

List<String> titles(List<UsenetRelease> l) => [for (final r in l) r.title];

List<RankingResult<UsenetRelease>> rank(RankingProfile p, List<UsenetRelease> releases, {Map<String, int> reliability = const {}, bool series = false}) =>
    RankingEngine.of(p).rank([
      for (final r in releases)
        RankingCandidate(
          r,
          r.facts,
          r.nzbUrl,
          sizeBytes: r.size > 0 ? r.size : null,
          publishedAt: r.publishedAt > 0 ? r.publishedAt : null,
          indexer: r.indexerName,
          mediaType: series ? 'series' : 'movie',
          reliability: reliability[r.title] ?? 1,
        ),
    ], now: now);

List<String> ranked(RankingProfile p, List<UsenetRelease> releases, {Map<String, int> reliability = const {}, bool series = false}) => [
  for (final r in rank(p, releases, reliability: reliability, series: series)) r.candidate.value.title,
];

RankingRule rule(String name, List<RankingCondition> c, {int score = 100, RankingAction action = RankingAction.boost, int minimumRemaining = 0, bool matchAny = false}) =>
    RankingRule(name, conditions: c, score: score, action: action, minimumRemaining: minimumRemaining, matchAny: matchAny);

void main() {
  setUp(() => UsenetClock.debugNow = () => DateTime.fromMillisecondsSinceEpoch(now));

  group('filters', () {
    test('the example of section 5.3', () {
      final good = rel('Good.1080p', bytes: 4000, at: now - day, url: 'https://one.test/good');
      final list = [
        good,
        rel('Good.2160p', bytes: 5000, at: now - day),
        rel('Bad.HDCAM.1080p', bytes: 4000, at: now - day),
        rel('Old.2160p', bytes: 4000, at: now - 40 * day),
        rel('Huge.2160p', gb: 11, at: now - day),
        rel('Locked.2160p', bytes: 4000, at: now - day, passworded: true),
        rel('Good.1080p', bytes: 4000, at: now - day, url: 'https://one.test/good'),
      ];
      final c = cfg(maxResults: 2, minResolution: 720, maxSizeGb: 10, maxAgeDays: 30);
      expect(titles(UsenetArrange.arrange(list, c, now: now)), ['Good.2160p', 'Good.1080p']);
      expect(titles(UsenetArrange.arrange(list.reversed.toList(), c, now: now)), ['Good.2160p', 'Good.1080p']);
      expect(titles(UsenetArrange.arrange(list, cfg(maxResults: 2, minResolution: 720, maxSizeGb: 10, maxAgeDays: 30, sort: UsenetSort.smallest), now: now)).first, 'Good.1080p');
    });

    test('unknown sizes and dates are left out by size and age limits', () {
      final list = [rel('NoSize.1080p', at: now), rel('NoDate.1080p', bytes: 100)];
      expect(UsenetArrange.arrange(list, cfg(maxSizeGb: 10), now: now).map((r) => r.title), ['NoDate.1080p']);
      expect(UsenetArrange.arrange(list, cfg(maxAgeDays: 30), now: now).map((r) => r.title), ['NoSize.1080p']);
    });

    test('whole discs', () {
      final list = [rel('Disc.COMPLETE.UHD.BLURAY', gb: 50), rel('Remux.2160p.REMUX', gb: 50)];
      expect(UsenetArrange.arrange(list, cfg(), now: now), hasLength(2));
      expect(titles(UsenetArrange.arrange(list, cfg(excludeFullDisc: true), now: now)), ['Remux.2160p.REMUX']);
    });
  });

  group('season packs per episode', () {
    test('sizes', () {
      final pack = rel('Show.S01-S03.1080p-GRP', gb: 34, series: true);
      expect(pack.episodeSize({1: 10, 2: 12, 3: 12}), gib);
      expect(pack.episodeSize({1: 10, 2: 12}), 34 * gib);
      expect(pack.episodeSize(null), 34 * gib);
    });

    test('the size limit and size sorts', () {
      final pack = rel('Show.S01.1080p-GRP', gb: 9, series: true);
      final ep = rel('Show.S01E02.1080p-GRP', gb: 2, series: true);
      final c = cfg(maxSizeGb: 5, sort: UsenetSort.largest);
      expect(titles(UsenetArrange.arrange([pack, ep], c, now: now, series: true)), ['Show.S01E02.1080p-GRP']);
      expect(titles(UsenetArrange.arrange([pack, ep], c, now: now, series: true, seasonEpisodes: {1: 9})), ['Show.S01E02.1080p-GRP', 'Show.S01.1080p-GRP']);
      expect(
        titles(UsenetArrange.arrange([pack, ep], cfg(maxSizeGb: 5, sort: UsenetSort.smallest), now: now, series: true, seasonEpisodes: {1: 9})),
        ['Show.S01.1080p-GRP', 'Show.S01E02.1080p-GRP'],
      );
    });
  });

  group('repeated releases', () {
    final indexers = [idx('one'), idx('low', priority: 2)];
    test('the highest indexer copy is kept', () {
      final c = cfg(indexers: indexers);
      final list = [rel('Movie.2020.1080p-GRP', indexer: 'low', bytes: 10), rel('Movie 2020 1080p GRP', indexer: 'one', bytes: 10), rel('Other.2020.1080p', indexer: 'low', bytes: 10)];
      final kept = UsenetArrange.withoutDuplicates(list, c, now: now);
      expect([for (final r in kept) '${r.indexerId}:${r.title}'], ['one:Movie 2020 1080p GRP', 'low:Other.2020.1080p']);
    });

    test('a copy the filters hide does not hide the others', () {
      final c = cfg(indexers: indexers);
      final list = [rel('Movie.2020.1080p-GRP', indexer: 'low'), rel('Movie.2020.1080p-GRP', indexer: 'one', passworded: true), rel('Other.2020.1080p', indexer: 'low')];
      final kept = UsenetArrange.withoutDuplicates(list, c, now: now);
      expect([for (final r in kept) r.indexerId], ['low', 'low']);
    });

    test('a profile requiring series', () {
      final p = RankingProfile(rules: [rule('series only', [const RankingCondition(RankingField.mediaType, RankingOperator.equals, 'series')], action: RankingAction.require)]);
      final c = cfg(indexers: indexers, preset: UsenetPreset.custom, custom: p);
      final high = rel('Show.S01E01.1080p-GRP', indexer: 'one', series: true);
      final list = [rel('Show.S01E01.1080p-GRP', indexer: 'low', series: true), high];
      expect(UsenetArrange.withoutDuplicates(list, c, now: now, series: true).single.indexerId, 'one');
      expect(UsenetArrange.arrange([high], c, now: now), isEmpty);
    });
  });

  group('result limit', () {
    test('known to play is never cut', () {
      final list = [for (var i = 1; i <= 5; i++) rel('Movie.2020.2160p-G$i', bytes: i), rel('Movie.2020.720p-OK', bytes: 1)];
      final out = UsenetArrange.arrange(list, cfg(maxResults: 3), now: now, rank: (r) => r.title.endsWith('OK') ? 0 : 1);
      expect(titles(out), ['Movie.2020.720p-OK', 'Movie.2020.2160p-G5', 'Movie.2020.2160p-G4']);
    });

    test('unlimited and the maximum', () {
      final list = [for (var i = 0; i < 600; i++) rel('Movie.2020.1080p-G$i', bytes: 10)];
      expect(UsenetArrange.arrange(list, cfg(maxResults: 0), now: now), hasLength(600));
      expect(UsenetArrange.arrange(list, cfg(maxResults: 500), now: now), hasLength(500));
    });
  });

  group('plain sorts', () {
    final preferred = idx('preferred'), one = idx('one');
    final list = [
      rel('Sharp.2160p', bytes: 4000, at: 1000, indexer: 'one'),
      rel('Large.1080p', bytes: 8000, at: 2000, indexer: 'one'),
      rel('Recent.720p', bytes: 1000, at: 3000, indexer: 'one'),
      rel('Preferred.1080p', bytes: 2000, at: 1500, indexer: 'preferred'),
    ];
    String first(UsenetSort s, {List<UsenetIndexer>? indexers}) =>
        UsenetArrange.arrange(list, cfg(sort: s, indexers: indexers ?? [preferred, one]), now: now).first.title;

    test('each sort', () {
      expect(first(UsenetSort.quality), 'Sharp.2160p');
      expect(first(UsenetSort.largest), 'Large.1080p');
      expect(first(UsenetSort.smallest), 'Recent.720p');
      expect(first(UsenetSort.newest), 'Recent.720p');
      expect(first(UsenetSort.indexer), 'Preferred.1080p');
      expect(first(UsenetSort.indexer, indexers: [one, preferred]), 'Sharp.2160p');
      expect(titles(UsenetArrange.arrange(list.reversed.toList(), cfg(indexers: [preferred, one]), now: now)), titles(UsenetArrange.arrange(list, cfg(indexers: [preferred, one]), now: now)));
    });

    test('a stored configuration without a profile', () {
      final c = UsenetSources.fromJson({'sort': 'SMALLEST', 'maxResults': 10});
      expect(c.preset, UsenetPreset.original);
      final s = UsenetSources.fromJson({'sort': 'smallest', 'maxResults': 10, 'indexers': [one.toJson()]});
      final out = UsenetArrange.arrange([rel('Film.2160p.BluRay.REMUX-GRP', gb: 60), rel('Film.1080p.WEB-DL-GRP', gb: 2)], s, now: now);
      expect(titles(out), ['Film.1080p.WEB-DL-GRP', 'Film.2160p.BluRay.REMUX-GRP']);
    });
  });

  group('profiles', () {
    test('Best Quality', () {
      expect(ranked(RankingPresets.bestQuality, [rel('Film.2160p.WEB-DL-FLUX', gb: 15), rel('Film.1080p.BluRay.REMUX-CiNEPHiLES', gb: 25), rel('Film.2160p.BluRay.REMUX-FraMeSToR', gb: 70)]), [
        'Film.2160p.BluRay.REMUX-FraMeSToR',
        'Film.1080p.BluRay.REMUX-CiNEPHiLES',
        'Film.2160p.WEB-DL-FLUX',
      ]);
    });

    test('Balanced', () {
      final out = ranked(RankingPresets.balanced, [rel('Film.2160p.BluRay.REMUX-FraMeSToR', gb: 70), rel('Unlabelled release'), rel('Film.2160p.WEB-DL-FLUX', gb: 15)]);
      expect(out.first, 'Film.2160p.WEB-DL-FLUX');
      expect(out, hasLength(3));
    });

    test('Smaller Files', () {
      expect(
        ranked(RankingPresets.smallerFiles, [
          rel('Film.2160p.BluRay.REMUX-FraMeSToR', gb: 70),
          rel('Film.2160p.WEB-DL-FLUX', gb: 8),
          rel('Film.1080p.WEB-DL.x264-NTb', gb: 4),
          rel('Film.1080p.WEB-DL.x265-NTb', gb: 3),
        ]),
        ['Film.1080p.WEB-DL.x265-NTb', 'Film.1080p.WEB-DL.x264-NTb', 'Film.2160p.WEB-DL-FLUX', 'Film.2160p.BluRay.REMUX-FraMeSToR'],
      );
    });

    test('group boosts are source-specific and ignore case', () {
      final out = rank(RankingPresets.bestQuality, [rel('Film.2160p.WEB-DL-fLuX', gb: 10), rel('Film.2160p.WEB-DL-Other', gb: 12), rel('Film.2160p.BluRay.REMUX-FLUX', gb: 50)]);
      final scores = {for (final r in out) r.candidate.value.title: r.score};
      expect(scores['Film.2160p.WEB-DL-fLuX'], 300);
      expect(scores['Film.2160p.WEB-DL-Other'], 0);
      expect(scores['Film.2160p.BluRay.REMUX-FLUX'], 0);
      expect(out, hasLength(3));
    });

    test('scores add up', () {
      final p = RankingProfile(
        sort: const [RankingSort(RankingKey.score), RankingSort(RankingKey.tier)],
        topPerBucket: 0,
        rules: [
          rule('group', [const RankingCondition(RankingField.group, RankingOperator.equals, 'Preferred')], score: 500),
          rule('codec', [const RankingCondition(RankingField.codec, RankingOperator.equals, 'HEVC')], score: 100),
        ],
      );
      final out = rank(p, [rel('Film.2160p.BluRay.REMUX-Other'), rel('Film.1080p.WEB-DL.x265-Preferred')]);
      expect(out.first.candidate.value.title, 'Film.1080p.WEB-DL.x265-Preferred');
      expect(out.first.score, 600);
      expect(out.first.matches, ['group', 'codec']);
    });

    test('filters and how many must remain', () {
      final list = [rel('Film.1080p.WEB-DL-A'), rel('Film.480p.WEB-DL-B')];
      RankingProfile exclude(int min) => RankingProfile(
        rules: [rule('low', [const RankingCondition(RankingField.resolution, RankingOperator.atMost, '720')], action: RankingAction.exclude, minimumRemaining: min)],
      );
      expect(ranked(exclude(2), list), hasLength(2));
      expect(ranked(exclude(0), list), ['Film.1080p.WEB-DL-A']);
      final english = RankingProfile(rules: [rule('en', [const RankingCondition(RankingField.language, RankingOperator.equals, 'en')], action: RankingAction.require)]);
      expect(ranked(english, list), isEmpty);
    });

    test('media type, patterns, sizes and any', () {
      final conditions = [
        const RankingCondition(RankingField.mediaType, RankingOperator.equals, 'series'),
        const RankingCondition(RankingField.title, RankingOperator.matches, 'S[0-9]+E[0-9]+'),
        const RankingCondition(RankingField.sizeGb, RankingOperator.atMost, '2'),
      ];
      final all = RankingProfile(rules: [rule('episode', conditions, score: 200)]);
      final anyOf = RankingProfile(rules: [rule('episode', conditions, score: 200, matchAny: true)]);
      final r = rel('Show.S01E01.1080p.WEB-DL-GRP', gb: 1);
      final unknown = rel('Show.S01E01.1080p.WEB-DL-GRP');
      expect(rank(all, [r]).single.score, 0);
      expect(rank(all, [r], series: true).single.score, 200);
      expect(rank(all, [unknown], series: true).single.score, 0);
      expect(rank(anyOf, [r]).single.score, 200);
    });

    test('variety and known failures', () {
      final p = RankingProfile(topPerBucket: 1, rules: [rule('preferred', [const RankingCondition(RankingField.group, RankingOperator.equals, 'Preferred')], score: 10000)]);
      final out = rank(p, [rel('Film.1080p.WEB-DL-A'), rel('Film.1080p.WEB-DL-B'), rel('Film.2160p.BluRay.REMUX-Preferred')], reliability: {'Film.2160p.BluRay.REMUX-Preferred': 2});
      expect([for (final r in out) r.candidate.value.title], ['Film.1080p.WEB-DL-A', 'Film.1080p.WEB-DL-B', 'Film.2160p.BluRay.REMUX-Preferred']);
      expect(out[1].overflow, isTrue);
    });

    test('Best Quality keeps a few of each kind on top', () {
      final p = RankingPresets.bestQuality.copyWith(topPerBucket: 2);
      final list = [for (var i = 1; i <= 6; i++) rel('Film.2160p.WEB-DL-G$i', gb: i.toDouble()), rel('Film.1080p.WEB-DL-Other', gb: 1)];
      final out = rank(p, list);
      expect([for (final r in out) r.candidate.value.title], [for (final r in rank(p, list.reversed.toList())) r.candidate.value.title]);
      expect(out, hasLength(7));
      expect(out.where((r) => r.overflow), hasLength(4));
      expect(out[2].candidate.value.title, 'Film.1080p.WEB-DL-Other');
    });

    test('unknown sizes go last either way', () {
      final list = [rel('Missing'), rel('Small', gb: 1), rel('Large', gb: 10)];
      RankingProfile by(bool descending) => RankingProfile(sort: [RankingSort(RankingKey.size, descending: descending)], topPerBucket: 0);
      expect(ranked(by(false), list), ['Small', 'Large', 'Missing']);
      expect(ranked(by(true), list), ['Large', 'Small', 'Missing']);
    });

    test('preferred languages', () {
      const p = RankingProfile(preferredLanguages: ['ja', 'en'], sort: [RankingSort(RankingKey.language)], topPerBucket: 0);
      expect(ranked(p, [rel('Film.1080p.English-A'), rel('Film.1080p.Japanese-B'), rel('Film.1080p-C')]), ['Film.1080p.Japanese-B', 'Film.1080p.English-A', 'Film.1080p-C']);
    });

    test('compressed groups when alternatives exist', () {
      final yts = rel('Film.1080p.WEB-DL-YTS');
      final failing = [for (var i = 0; i < 5; i++) rel('Film.1080p.WEB-DL.N$i-NTb')];
      expect(ranked(RankingPresets.balanced, [yts, ...failing], reliability: {for (final r in failing) r.title: 2}), contains(yts.title));
      final four = ranked(RankingPresets.bestQuality, [yts, ...failing.take(4)]);
      expect(four.last, yts.title);
      expect(ranked(RankingPresets.bestQuality, [yts, ...failing]), isNot(contains(yts.title)));
    });

    test('1080p / SDR', () {
      final out = ranked(RankingPresets.hdSdr, [
        rel('Film.1080p.WEB-DL.HDR.HEVC-FLUX', gb: 6),
        rel('Film.1080p.WEB-DL.DV.HEVC-NTb', gb: 5),
        rel('Film.2160p.BluRay.REMUX.HDR-FraMeSToR', gb: 60),
        rel('Film.1080p.WEB-DL.x265-Other', gb: 4),
        rel('Unknown'),
        rel('Film.720p.WEB-DL.x264-Other', gb: 1),
        rel('Film.1080p.WEB-DL.x264.AAC-Other', gb: 4),
      ]);
      expect(out.first, 'Film.1080p.WEB-DL.x264.AAC-Other');
      expect(out.indexOf('Film.720p.WEB-DL.x264-Other'), lessThan(out.indexOf('Film.1080p.WEB-DL.HDR.HEVC-FLUX')));
      expect(out, hasLength(7));
    });

    test('a preset with a preferred language', () {
      final c = cfg(preset: UsenetPreset.bestQuality, language: 'nl', maxResults: 0);
      final out = UsenetArrange.arrange([
        rel('Film.2160p.BluRay.REMUX.English-FraMeSToR', gb: 60),
        rel('Film.1080p.WEB-DL.Dutch-Other', gb: 2),
        rel('Film.1080p.WEB-DL-NTb', gb: 3),
      ], c, now: now);
      expect(out.first.title, 'Film.1080p.WEB-DL.Dutch-Other');
      expect(out, hasLength(3));
      expect(RankingPresets.active(c)!.sort.first.key, RankingKey.language);
    });

    test('Balanced with filters and the limit', () {
      final remux = rel('Film.2160p.BluRay.REMUX-FraMeSToR', gb: 60);
      final list = [remux, rel('Film.2160p.WEB-DL-FLUX', gb: 12), rel('Film.HDCAM-X', gb: 1), rel('Film.2160p.WEB-DL-Locked', gb: 5, passworded: true)];
      expect(titles(UsenetArrange.arrange(list, cfg(preset: UsenetPreset.balanced, maxResults: 1, maxSizeGb: 20), now: now)), ['Film.2160p.WEB-DL-FLUX']);
      expect(
        titles(UsenetArrange.arrange(list, cfg(preset: UsenetPreset.balanced, maxResults: 1), now: now, rank: (r) => identical(r, remux) ? 0 : 1)),
        ['Film.2160p.BluRay.REMUX-FraMeSToR'],
      );
    });

    test('Balanced with a season pack', () {
      final pack = rel('Show.S01-S02.2160p.BluRay.REMUX-FraMeSToR', gb: 80, series: true);
      final ep = rel('Show.S01E01.1080p.WEB-DL-NTb', gb: 1, series: true);
      final c = cfg(preset: UsenetPreset.balanced);
      expect(UsenetArrange.arrange([pack, ep], c, now: now, series: true, seasonEpisodes: {1: 10, 2: 10}).first, pack);
      expect(UsenetArrange.arrange([pack, ep], c, now: now, series: true, seasonEpisodes: {1: 5, 2: 5}).first, ep);
      expect(UsenetArrange.arrange([pack, ep], c, now: now, series: true).first, pack);
    });

    test('a pattern that would hang a backtracking engine', () {
      final p = RankingProfile(rules: [rule('bad', [const RankingCondition(RankingField.title, RankingOperator.matches, r'(a+)+b')], score: 50)]);
      final watch = Stopwatch()..start();
      expect(rank(p, [rel('a' * 2048)]).single.score, 0);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('profile data', () {
    test('round trip and defaults', () {
      for (final p in [RankingPresets.balanced, RankingPresets.bestQuality, RankingPresets.smallerFiles, RankingPresets.hdSdr, RankingPresets.custom]) {
        expect(p.problem, isNull, reason: p.name);
        final back = RankingProfile.fromJson(p.toJson())!;
        expect(back.toJson(), p.toJson());
      }
      final fresh = RankingProfile.fromJson({'name': 'Mine'})!;
      expect(fresh.sort.map((s) => s.key), [RankingKey.sizePreference, RankingKey.tier, RankingKey.score, RankingKey.language, RankingKey.size]);
      expect(fresh.sort.last.descending, isFalse);
      expect(fresh.topPerBucket, 3);
    });

    test('validation', () {
      for (final bad in [r'(?<=x)y', r'(x)\1', '[']) {
        expect(RankingCondition(RankingField.title, RankingOperator.matches, bad).problem, isNotNull, reason: bad);
      }
      expect(const RankingCondition(RankingField.sizeGb, RankingOperator.contains, '1').problem, isNotNull);
      expect(const RankingCondition(RankingField.title, RankingOperator.atLeast, '1').problem, isNotNull);
      expect(const RankingCondition(RankingField.sizeGb, RankingOperator.atLeast, '-1').problem, isNotNull);
      expect(const RankingCondition(RankingField.title, RankingOperator.contains, ' ').problem, isNotNull);
      expect(const RankingRule('r').problem, isNotNull);
      expect(const RankingProfile(sort: []).problem, isNotNull);
      expect(const RankingProfile(sort: [RankingSort(RankingKey.tier), RankingSort(RankingKey.tier)]).problem, isNotNull);
      expect(const RankingProfile(topPerBucket: 21).problem, isNotNull);
      expect(const RankingProfile(preferredLanguages: ['EN']).problem, isNotNull);
      expect(const RankingProfile(tiers: [RankingTier('t', resolutions: [1234])]).problem, isNotNull);
      expect(RankingProfile.fromJson({'version': 2}), isNull);
      expect(RankingProfile.fromJson({'sort': [{'key': 'NOPE'}]}), isNull);
    });

    test('Current sorting and custom', () {
      expect(RankingPresets.active(cfg()), isNull);
      expect(RankingPresets.active(cfg(preset: UsenetPreset.custom)), isNull);
      final mine = RankingProfile(name: 'Mine', rules: [rule('x', [const RankingCondition(RankingField.title, RankingOperator.contains, 'x')])]);
      expect(RankingPresets.active(cfg(preset: UsenetPreset.custom, custom: mine, language: 'de'))!.name, 'Mine');
      expect(RankingPresets.active(cfg(preset: UsenetPreset.custom, custom: mine, language: 'de'))!.preferredLanguages, isEmpty);
    });
  });
}
