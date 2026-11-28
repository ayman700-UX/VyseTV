// Release-name matching, packs, upload templates, film and series checks, and what a name
// says it holds (the Usenet search spec, sections 4 and 6.7 to 6.9).

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/usenet_names.dart';

UsenetSearchRequest show({String title = 'Show', int season = 1, required int episode, int? year}) =>
    UsenetSearchRequest(title: title, season: season, episode: episode, series: true, year: year);

void main() {
  group('spelling', () {
    test('release spelling', () {
      expect(releaseSpelling('Amélie'), 'Amelie');
      expect(releaseSpelling('Der König der Löwen'), 'Der Koenig der Loewen');
      expect(releaseSpelling('Der König der Löwen', umlauts: false), 'Der Konig der Lowen');
      expect(releaseSpelling('Straße'), 'Strasse');
      expect(releaseSpelling("Marvel's"), 'Marvels');
      expect(releaseSpelling('ガンダム'), 'ガンダム');
      expect(releaseSpelling('Ärger'), 'Aerger');
      expect(releaseSpelling('Øresund'), 'Oeresund');
      expect(releaseSpelling('Øresund', umlauts: false), 'Oresund');
    });

    test('query titles', () {
      expect(queryTitle('Amélie'), 'Amelie');
      expect(queryTitle('Der König der Löwen'), 'Der Koenig der Loewen');
      expect(queryTitle("Marvel's The Avengers"), 'Marvels The Avengers');
      expect(queryTitle('Mission: Impossible – Fallout'), 'Mission Impossible Fallout');
      expect(queryTitle('ガンダム'), 'ガンダム');
      expect(queryTitle('Fast & Furious'), 'Fast Furious');
    });

    test('same names', () {
      expect(sameName("Marvel's Daredevil", 'Marvels Daredevil'), isTrue);
      expect(sameName('SUITS', 'Suits'), isTrue);
      expect(sameName('Suits LA', 'Suits'), isFalse);
      expect(sameName(null, 'Suits'), isFalse);
    });

    test('Latin letters', () {
      expect(hasLatinLetter('La casa de papel'), isTrue);
      expect(hasLatinLetter('Amélie'), isTrue);
      expect(hasLatinLetter('ペーパー・ハウス'), isFalse);
      expect(hasLatinLetter('2049'), isFalse);
    });
  });

  group('episode numbers', () {
    final cases = <(String, int, bool)>[
      ('The.Pitt.2025-S01E02-8-00.A.M.WEB-DL-2160p.HEVC-FRESH', 2, true),
      ('The.Pitt.2025-S01E02-8-00.A.M.WEB-DL-2160p.HEVC-FRESH', 5, false),
      ('The.Pitt.2025-S01E08-2-00.P.M.WEB-DL-2160p.HEVC-FRESH', 8, true),
      ('The.Pitt.2025-S01E08-2-00.P.M.WEB-DL-2160p.HEVC-FRESH', 2, false),
      ('The.Pitt.2025-S01E04-10-00.A.M.WEB-DL-2160p-FRESH', 4, true),
      ('The.Pitt.2025-S01E04-10-00.A.M.WEB-DL-2160p-FRESH', 5, false),
      ('The.Pitt.2025-S01E04-10-00.A.M.WEB-DL-2160p-FRESH', 10, false),
      ('Show.S01E01-03.1080p', 2, true),
      ('Show.S01E01-E03.1080p', 2, true),
      ('Show.S01E9-10.1080p', 10, true),
      ('Show.S01E01E02.1080p', 2, true),
      ('Show.S01E01E03.1080p', 2, false),
      ('A.Show.S01E01-05.1080p', 3, true),
      ('A.Show.S01E04E05E06.1080p', 6, true),
      ('A.Show.S01E04E05E06.1080p', 5, true),
      ('A.Show.S01E04E06.1080p', 5, false),
      ('A.Show.S01E04E06.1080p', 6, true),
      ('A.Show.S01E01E02-E04.1080p', 3, true),
      ('A.Show.1x04-06.1080p', 5, true),
      ('A.Show.S01E04-1080p', 5, false),
      ('A.Show.S01E04.1080p', 5, false),
      ('A.Show.1x04.1080p', 5, false),
      ('a8f3k2b9', 2, true),
      ('Show.S01E01.1999.1080p', 1, true),
    ];
    for (final (title, episode, expected) in cases) {
      test('$title E$episode', () {
        final r = UsenetSearchRequest(title: title.startsWith('A.') ? 'A Show' : 'Show', season: 1, episode: episode, series: true, year: 2010);
        expect(releaseMatches(title, r, idSearch: true), expected);
      });
    }

    test('title searches name the show', () {
      expect(releaseMatches('A.Show.S01E01-E10', show(title: 'A Show', episode: 5), idSearch: false), isTrue);
      expect(releaseMatches('A.Show.S01.Complete', show(title: 'A Show', episode: 5), idSearch: false), isTrue);
      expect(releaseMatches('A.Show.S02.Complete', show(title: 'A Show', episode: 5), idSearch: false), isFalse);
    });

    test('obfuscated names need an id search without required numbering', () {
      expect(releaseMatches('a8f3k2b9', show(episode: 2), idSearch: true, requireNumbering: true), isFalse);
      expect(releaseMatches('a8f3k2b9', show(episode: 2), idSearch: false), isFalse);
    });

    test('packs hold their seasons', () {
      bool holds(String t, int season) => releaseMatches(t, show(season: season, episode: 1), idSearch: true, requireNumbering: true);
      expect(holds('Show.S01-S03.1080p-GRP', 2), isTrue);
      expect(holds('Show.S01-S03.1080p-GRP', 4), isFalse);
      expect(holds('Show.S01-10.1080p', 9), isTrue);
      expect(holds('Show Season 1-10 1080p', 9), isTrue);
      expect(holds('Show.S01.S03.1080p', 3), isTrue);
      expect(holds('Show.S01.S03.1080p', 2), isFalse);
      expect(holds('Show.S02-720p', 2), isTrue);
      expect(holds('Show.S02-720p', 720), isFalse);
    });

    test('pack seasons', () {
      expect(packSeasons('Slow.Horses.S01.1080p.ATVP.WEB-DL-NTb'), [1]);
      expect(packSeasons('Show Season 2 Complete 2160p'), [2]);
      expect(packSeasons('Show.S01-S03.1080p'), [1, 2, 3]);
      expect(packSeasons('Show.S01-03.1080p'), [1, 2, 3]);
      expect(packSeasons('Show Season 1-3 1080p'), [1, 2, 3]);
      expect(packSeasons('Show.S01.S03.1080p'), [1, 3]);
      expect(packSeasons('Show.S02-720p'), [2]);
      expect(packSeasons('Slow.Horses.S01E03.1080p'), isEmpty);
      expect(packSeasons('Show.1x03.720p'), isEmpty);
      expect(packSeasons('Movie.2020.2160p'), isEmpty);
    });

    test('upload templates', () {
      final a = episodeTemplate('Silo.S01E01.Freedom.Day.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb'.toLowerCase());
      final b = episodeTemplate('Silo.S01E02.Holstons.Pick.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb'.toLowerCase());
      final c = episodeTemplate('Silo.S01E02.Holstons.Pick.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-FLUX'.toLowerCase());
      final d = episodeTemplate('Silo.S02E01.The.Engineer.2160p.ATVp.WEB-DL.DDP5.1.HDR.H.265-NTb'.toLowerCase());
      expect(a!.template, b!.template);
      expect(a.episode, 1);
      expect(b.episode, 2);
      expect(c!.template, isNot(a.template));
      expect(d!.template, isNot(a.template));
      final e02 = episodeTemplate('The.Pitt.2025-S01E02-8-00.A.M.WEB-DL-2160p.HEVC-FRESH'.toLowerCase());
      final e08 = episodeTemplate('The.Pitt.2025-S01E08-2-00.P.M.WEB-DL-2160p.HEVC-FRESH'.toLowerCase());
      expect(e02!.template, e08!.template);
      expect(e08.episode, 8);
      expect(episodeTemplate('show.s01.1080p-grp'), isNull);
      expect(episodeTemplate('show.s01e01e02.1080p-grp'), isNull);
      expect(episodeTemplate('movie.2020.1080p'), isNull);
    });
  });

  group('titles', () {
    test('named as', () {
      List<String> w(String s) => words(s).split(' ');
      expect(isNamedAs(w('Marvels.Daredevil.S01E01'), w('Daredevil'), series: true), isTrue);
      expect(isNamedAs(w('The.Batman.2022.1080p'), w('Batman'), series: false), isTrue);
      expect(isNamedAs(w('The.Batman.S01E01'), w('Batman'), series: true), isFalse);
      expect(isNamedAs(w('Supernoobs.S01E02.Super.Noob.Suits'), w('Suits'), series: true), isFalse);
      expect(isNamedAs(w('Suits.LA.S01E01.1080p'), w('Suits'), series: true), isFalse);
      expect(isNamedAs(w('The.Movie.Subtitle.2020.1080p'), w('The Movie'), series: false), isTrue);
    });

    test('a film title search checks the year', () {
      const r = UsenetSearchRequest(title: 'The Movie', year: 2020);
      expect(releaseMatches('The.Movie.2020.1080p', r, idSearch: false), isTrue);
      expect(releaseMatches('The.Movie.2010.1080p', r, idSearch: false), isFalse);
      expect(releaseMatches('Another.Movie.2020.1080p', r, idSearch: false), isFalse);
    });

    test('year words of titles are no release years', () {
      expect(contradictsYear('Blade.Runner.2049.2017.2160p', 2017, ['blade', 'runner', '2049']), isFalse);
      expect(contradictsYear('Blade.Runner.2049.1080p', 2017, ['blade', 'runner', '2049']), isFalse);
      expect(contradictsYear('1917.2019.1080p', 2019, ['1917']), isFalse);
      expect(contradictsYear('Movie.2011.1080p', 2001, ['movie']), isTrue);
      expect(contradictsYear('Movie.1080p', 2001, ['movie']), isFalse);
    });
  });

  group('films by id', () {
    const towers = UsenetSearchRequest(
      title: 'The Lord of the Rings: The Two Towers',
      year: 2002,
      otherTitles: [
        'Der Herr der Ringe - Die zwei Türme',
        'Il Signore degli Anelli - Le due torri',
        'LOTR2 - The Two Towers',
        'In de ban van de ring: De twee torens',
        'ロード・オブ・ザ・リング／二つの塔',
        'Властелин колец 2',
      ],
    );
    final table = <(String, bool)>[
      ('The.Ring.2002.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.DTS-HD.MA.5.1-TRiToN', false),
      ('The Ring 2002 1080p PCOK WEB-DL DDP 5 1 H 264-PiRaTeS', false),
      ('The.Ring.2002.MULTi.COMPLETE.BLURAY-OLDHAM', false),
      ('The.Lord.of.the.Rings.The.Two.Towers.2002.Extended.2160p.UHD.BluRay.x265', true),
      ('The Lord of the Rings-The Two Towers 2002 2160p 35mm HDR v1.1', true),
      ('Lord.of.the.Rings.Two.Towers.2002.1080p.BluRay.x264', true),
      ('LOTR The Two Towers 2002 1080p BluRay', true),
      ('The Lord of thee Rings The Two Towers 2002 720p', true),
      ('Der.Herr.der.Ringe.Die.zwei.Tuerme.2002.German.DL.1080p', true),
      ('Der Herr der Ringe II Die zwei Tuerme 2002 German 1080p', true),
      ('Il.Signore.degli.Anelli.Le.Due.Torri.2002.iTALiAN.1080p', true),
      ('{ Der.Herr.der.Ringe.die.zwei.Tuerme.2002.German.AC3.DVDRiP.XViD } }ghost-of-usenet.org{', true),
      ('a8f3c1e9d2b7', true),
      ('d-pate-1080p', true),
      ('The.Lord.of.the.Rings.The.Two.Towers.2012.1080p', false),
    ];
    for (final (title, kept) in table) {
      test(title, () => expect(filmResultsOf(towers, [title], (t) => t), kept ? [title] : isEmpty));
    }

    test('other names unknown: the year decides', () {
      const r = UsenetSearchRequest(title: 'The Lord of the Rings: The Two Towers', year: 2002);
      expect(filmResultsOf(r, ['The.Ring.2002.1080p'], (t) => t), ['The.Ring.2002.1080p']);
    });

    test('Amélie, Star Wars, Blade Runner 2049, 1917', () {
      const amelie = UsenetSearchRequest(title: 'Amélie', originalTitle: "Le Fabuleux Destin d'Amélie Poulain", year: 2001, otherTitles: []);
      expect(
        filmResultsOf(amelie, ['Amlie.2001.DVDRiP.XviD', 'Le.Fabuleux.Destin.D.Amelie.Poulain.2001.1080p', 'Soul.Assassin.2001.WEBRip.x264'], (t) => t),
        ['Amlie.2001.DVDRiP.XviD', 'Le.Fabuleux.Destin.D.Amelie.Poulain.2001.1080p'],
      );
      const starWars = UsenetSearchRequest(title: 'Star Wars', year: 1977, otherTitles: []);
      expect(filmResultsOf(starWars, ['Star.Wars.Episode.IV.A.New.Hope.1977.1080p', 'Scum.1977.1080p.BluRay.x264-GHOULS'], (t) => t), [
        'Star.Wars.Episode.IV.A.New.Hope.1977.1080p',
      ]);
      const blade = UsenetSearchRequest(title: 'Blade Runner 2049', year: 2017, otherTitles: []);
      expect(filmResultsOf(blade, ['Blade.Runner.2049.2017.2160p'], (t) => t), hasLength(1));
      const war = UsenetSearchRequest(title: '1917', year: 2019, otherTitles: []);
      expect(filmResultsOf(war, ['1917.2019.1080p'], (t) => t), hasLength(1));
    });

    test('year rule', () {
      const potter = UsenetSearchRequest(title: "Harry Potter and the Sorcerer's Stone", year: 2001);
      final kept = filmResultsOf(potter, [
        'Harry.Potter.und.die.Heiligtuemer.des.Todes.Teil.2.2011.German.DL.2160p.HDR.BluRay.AV1-Bi0hazard',
        'Harry.Potter.and.the.Sorcerers.Stone.2001.2160p.UHD.BluRay.x265',
        'Harry.Potter.und.der.Stein.der.Weisen.2002.German.1080p',
        'd-pate-1080p',
      ], (t) => t);
      expect(kept, hasLength(3));
      expect(kept.first, startsWith('Harry.Potter.and'));
      const blade = UsenetSearchRequest(title: 'Blade Runner 2049', year: 2017);
      expect(filmResultsOf(blade, ['Blade.Runner.2049.2017.2160p', 'Blade.Runner.2049.1080p'], (t) => t), hasLength(2));
    });
  });

  group('series of one name', () {
    List<String> kept(UsenetSearchRequest s, List<String> titles) => seriesResultsOf(s, titles, (t) => t, packSeasons);

    test('Korean Suits', () {
      const korean = UsenetSearchRequest(title: 'Suits', year: 2018, seasonYear: 2018, season: 1, episode: 2, series: true);
      expect(kept(korean, [
        'Suits.2018.S01E02.1080p.NF.WEB-DL.H.264-TSRG',
        'Suits.S01E02.2011.1080p.Netflix.WEB-DL.AVC.DDP.5.1-DBTV',
        'Suits (2011) S01E02 1080p BluRay x265 10bit HEVC',
        'Suits.2011.S01E02.1080p.NF.WEBRip.H.264-PTerWEB',
        'Suits 2011 1x02 Errores Y Omisiones Micro-HD',
        'Suits.S01E02.1080p.BluRay.H264-GERUDO',
        '8f3a2c1d9e7b6a5f4e3d2c1b',
      ]), [
        'Suits.2018.S01E02.1080p.NF.WEB-DL.H.264-TSRG',
        'Suits.S01E02.1080p.BluRay.H264-GERUDO',
        '8f3a2c1d9e7b6a5f4e3d2c1b',
      ]);
      const unknown = UsenetSearchRequest(title: 'Suits', season: 1, episode: 2, series: true);
      expect(kept(unknown, ['Suits.2011.S01E02.1080p']), hasLength(1));
    });

    test('American Suits', () {
      const us = UsenetSearchRequest(title: 'Suits', year: 2011, seasonYear: 2019, season: 9, episode: 1, series: true);
      expect(kept(us, ['Suits.2011.S09E01.1080p', 'Suits.S09E01.2019.1080p', 'Suits.S09E01.2020.720p', 'Suits.2015.S09E01.1080p']), [
        'Suits.2011.S09E01.1080p',
        'Suits.S09E01.2019.1080p',
        'Suits.S09E01.2020.720p',
      ]);
      const noSeason = UsenetSearchRequest(title: 'Suits', year: 2011, lastYear: 2019, season: 9, episode: 1, series: true);
      expect(kept(noSeason, ['Suits.2016.S09E01.1080p', 'Suits.2022.S09E01.1080p']), ['Suits.2016.S09E01.1080p']);
    });

    test('1923, The Daily Show, multi-season packs', () {
      const t1923 = UsenetSearchRequest(title: '1923', year: 2022, season: 1, episode: 1, series: true);
      expect(kept(t1923, ['1923.S01E01.1080p.WEB', '1923.2022.S01E01.720p', '1923.2019.S01E01.720p']), ['1923.S01E01.1080p.WEB', '1923.2022.S01E01.720p']);
      const daily = UsenetSearchRequest(title: 'The Daily Show', year: 1996, season: 29, episode: 50, series: true);
      expect(kept(daily, ['The.Daily.Show.2024.05.12.Guest.720p.WEB', 'The.Daily.Show.S29.2020-2024.1080p']), hasLength(2));
      const old = UsenetSearchRequest(title: 'Show', year: 2011, season: 2, episode: 1, series: true);
      expect(kept(old, ['Show.S01-S03.2013.1080p']), hasLength(1));
    });

    test('The Office', () {
      const uk = UsenetSearchRequest(
        title: 'The Office',
        year: 2001,
        countries: ['GB'],
        namesakes: [UsenetNamesake(year: 2005, countries: ['US'], votes: 5765)],
        season: 1,
        episode: 1,
        series: true,
      );
      expect(kept(uk, ['The.Office.UK.S01E01.720p', 'The.Office.S01E01.1080p.BluRay', 'The.Office.US.S01E01.720p']), [
        'The.Office.UK.S01E01.720p',
        'The.Office.S01E01.1080p.BluRay',
      ]);
      const ukAlone = UsenetSearchRequest(title: 'The Office', year: 2001, countries: ['GB'], season: 1, episode: 1, series: true);
      expect(kept(ukAlone, ['The.Office.US.S01E01.720p']), hasLength(1));
      const us = UsenetSearchRequest(
        title: 'This Is Us',
        year: 2016,
        countries: ['US'],
        namesakes: [UsenetNamesake(year: 2010, countries: ['GB'], votes: 10)],
        season: 1,
        episode: 1,
        series: true,
      );
      expect(kept(us, ['This.Is.Us.S01E01.1080p']), hasLength(1));
    });

    group('namesakes far better known', () {
      const releases = [
        'Suits.2018.S01E02.1080p.NF.WEB-DL-TSRG',
        'Suits.S01E02.1080p.BluRay.H264-GERUDO',
        'Suits - S01E02 - Errors and Omissions - Bluray-720p',
        '8f3a2c1d9e7b6a5f4e3d2c1b',
        'Pearson.S01E02.1080p',
      ];
      UsenetSearchRequest korean({int? votes = 24, int olderVotes = 6055}) => UsenetSearchRequest(
        title: 'Suits',
        year: 2018,
        votes: votes,
        countries: const ['KR'],
        namesakes: [
          UsenetNamesake(year: 2011, countries: const ['US'], votes: olderVotes),
          const UsenetNamesake(year: 2018, countries: ['JP'], votes: 11),
        ],
        season: 1,
        episode: 2,
        series: true,
      );
      List<String> left(UsenetSearchRequest s, List<String> l) => withoutNamesakeReleases(s, l, (t) => t, packSeasons);

      test('bare names go once one names this series', () {
        expect(left(korean(), releases), [releases[0], releases[3], releases[4]]);
        expect(left(korean(), releases.sublist(1)), releases.sublist(1));
      });

      test('a dated name is no bare name', () {
        const dated = 'Suits.S01E02.2018.1080p.WEB';
        expect(left(korean(), [...releases.sublist(1), dated]), hasLength(5));
        expect(left(korean(), [...releases, dated]), hasLength(4));
      });

      test('the thresholds', () {
        expect(left(korean(olderVotes: 9), releases), hasLength(5));
        expect(left(korean(votes: 606), releases), hasLength(5));
        expect(left(korean(votes: 605), releases), hasLength(3));
        expect(left(korean(votes: null), releases), hasLength(5));
        const older = UsenetSearchRequest(
          title: 'Suits',
          year: 2011,
          votes: 6055,
          namesakes: [UsenetNamesake(year: 2018, countries: ['KR'], votes: 24)],
          season: 1,
          episode: 2,
          series: true,
        );
        expect(left(older, releases), hasLength(5));
      });

      test('the American Office', () {
        const usOffice = UsenetSearchRequest(
          title: 'The Office',
          year: 2005,
          votes: 100,
          countries: ['US'],
          namesakes: [UsenetNamesake(year: 2001, countries: ['GB'], votes: 1030)],
          season: 2,
          episode: 1,
          series: true,
        );
        expect(left(usOffice, ['The.Office.US.S02E01.720p', 'The.Office.S02E01.720p']), ['The.Office.US.S02E01.720p']);
      });
    });
  });

  group('facts', () {
    test('the table', () {
      final f = RankingFacts.parse('Film.2025.2160p.UHD.BluRay.REMUX.HEVC.DV.HDR10+.TrueHD.Atmos.English-FraMeSToR.mkv');
      expect(f.resolution, 2160);
      expect(f.quality, ReleaseQuality.remux);
      expect(f.codec, 'HEVC');
      expect(f.group, 'FraMeSToR');
      expect(f.visual, containsAll(['HDR_DV', 'HDR10_PLUS']));
      expect(f.visual, isNot(contains('DV_ONLY')));
      expect(f.audio, containsAll(['TRUEHD', 'ATMOS']));
      expect(f.languages, {'en'});
      expect(RankingFacts.parse('Film.1080p.BluRay.x264-D-Z0N3').group, 'D-Z0N3');
      expect(RankingFacts.parse('[SubsPlease] Show - 01 (1080p) [AABB1122]').group, 'SubsPlease');
      expect(RankingFacts.parse('Film.WEB-DL-NTb').group, 'NTb');
      expect(RankingFacts.parse('Film.2160p.WEB-DL.DV-FLUX').visual, contains('DV_ONLY'));
      expect(RankingFacts.parse('obfuscated.release').quality, ReleaseQuality.unknown);
      expect(RankingFacts.parse('Film.WEB-DL-NTb\n').group, '');
      expect(RankingFacts.parse('Film.WEB-DL.mkv\n').group, '');
      expect(RankingFacts.parse('Film.1080p.AMZN.WEB.H264-GROUP').quality, ReleaseQuality.webDl);
      expect(RankingFacts.parse('Film.1080p.WEB-Rip-GROUP').quality, ReleaseQuality.webRip);
      expect(RankingFacts.parse('Web.Of.Lies.1080p.HDTV-GROUP').quality, ReleaseQuality.hdtv);
      final ts = RankingFacts.parse('Film.1080p.WEB-DL-GROUP.ts');
      expect(ts.quality, ReleaseQuality.webDl);
      expect(ts.group, 'GROUP');
      expect(ts.title, 'Film.1080p.WEB-DL-GROUP.ts');
      expect(ts.visual, contains('NO_HDR_LABEL'));
      expect(RankingFacts.parse('Film.1080p.WEB-DL.DV-GROUP').visual, isNot(contains('NO_HDR_LABEL')));
    });
  });

  group('labels', () {
    test('audio and services', () {
      final tulsa = ReleaseLabels.of('Tulsa.King.S01E01.2160p.AMZN.WEB-DL.DDP5.1.H.265-NTb');
      expect(tulsa.audio, 'DD+ 5.1');
      expect(tulsa.service, 'Prime');
      expect(ReleaseLabels.of('Movie.2020.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-GRP').audio, 'DD+ 5.1 Atmos');
      expect(ReleaseLabels.of('Movie.2020.2160p.BluRay.REMUX.HEVC.TrueHD.Atmos.7.1-GRP').audio, 'TrueHD 7.1 Atmos');
      expect(ReleaseLabels.of('Movie.2020.1080p.BluRay.DTS-HD.MA.7.1.x264-GRP').audio, 'DTS-HD MA 7.1');
      expect(ReleaseLabels.of('Movie.2020.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-X-GRP').audio, 'DTS:X');
      expect(ReleaseLabels.of('Movie.2020.1080p.WEB-DL.DD5.1.H.264-GRP').audio, 'DD 5.1');
      expect(ReleaseLabels.of('Movie.2020.1080p.WEBRip.AAC2.0.x264-GRP').audio, 'AAC 2.0');
      expect(ReleaseLabels.of('Movie.2020.1080p.WEB.H264-GRP').audio, isNull);
      expect(ReleaseLabels.of('Movie.2024.REPACK.720p.10bit.WEBRip.6CH.X265.HEVC-PSA').audio, '5.1');
      expect(ReleaseLabels.of('Show.S01E01.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HEVC-GRP').service, 'Max');
      expect(ReleaseLabels.of('Movie.2020.1080p.NF.WEB-DL.DDP5.1.H.264-GRP').service, 'Netflix');
      expect(ReleaseLabels.of('Movie.2020.1080p.iT.WEB-DL.DD5.1.H.264-GRP').service, 'iTunes');
      expect(ReleaseLabels.of('Mad.Max.Fury.Road.2015.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-X-GRP').service, isNull);
    });

    test('languages', () {
      expect(ReleaseLabels.of('It.Ends.With.Us.2024.1080p.iT.WEB-DL.DD5.1.H.264-GRP').languages, isEmpty);
      expect(ReleaseLabels.of('Movie.2020.GERMAN.DL.1080p.BluRay.x264-GRP').languages, ['DE']);
      expect(ReleaseLabels.of('Show.S02E05.MULTi.1080p.WEB.H264-GRP').languages, ['MULTI']);
      final many = ReleaseLabels.of('Movie.2024.Eng.Fre.Ger.Ita.Spa.Cze.Pol.Jpn.2160p.BluRay.Remux.DV.HDR.HEVC.Atmos-GRP');
      expect(many.languagesLabel, 'EN+JA +5');
      expect(many.audio, 'Atmos');
      expect(tagsOf('1917.2019.2160p.WEB-DL-GRP'), '2019.2160p.WEB-DL-GRP');
    });

    test('groups', () {
      expect(ReleaseLabels.of('Movie.2020.1080p-GRP').group, 'GRP');
      expect(ReleaseLabels.of('Dune.Part.Two.2024.BDRip.x264-ROEN-xpost').group, 'ROEN');
      expect(ReleaseLabels.of('Movie.2024.JAPANESE.BDRip.x264-HOA-xsp-').group, 'HOA');
      expect(ReleaseLabels.of('Movie.2020.2160p.BluRay.REMUX.HEVC.TrueHD.Atmos.7.1-FraMeSToR.mkv').group, 'FraMeSToR');
      expect(ReleaseLabels.of('Movie.2024.720p.WEBRip.900MB.x264-GalaxyRG[TGx]').group, 'GalaxyRG');
      expect(ReleaseLabels.of('Movie.2020.1080p.WEB-DL').group, isNull);
      expect(ReleaseLabels.of('a1b2c3d4e5f6').group, isNull);
    });
  });

  group('flags', () {
    test('resolution and low quality', () {
      expect(releaseResolution('Movie.2020.2160p'), 2160);
      expect(releaseResolution('Movie.2020.4K.HDR'), 2160);
      expect(releaseResolution('Movie.2020.UHD'), 0);
      expect(isLowQuality('Bad.HDCAM.1080p'), isTrue);
      expect(isLowQuality('Good.1080p'), isFalse);
    });

    test('whole discs', () {
      for (final t in [
        'The.Drama.2026.COMPLETE.UHD.BLURAY-GRP',
        'Movie.2020.Complete.Bluray-GRP',
        'Movie 2020 BD50',
        'Movie.2020.1080p.BDMV.AVC.DTS-HD.MA',
        'Movie.2020.DVD9-GRP',
        'Movie.2020.ISO',
        '[Movie 2020 BD25]',
        'Show.S01.COMPLETE.BLURAY.AVC.DTS-HD.MA.5.1-GRP',
      ]) {
        expect(isFullDisc(t), isTrue, reason: t);
      }
      for (final t in [
        'The.Drama.2026.2160p.UHD.Remux.HEVC.DoVi.TrueHD.Atmos.7.1-playBD',
        'Movie.2020.COMPLETE.BLURAY.REMUX-GRP',
        'Show.S01.COMPLETE.BluRay.1080p.x264-GRP',
        'Movie.2020.BDRip.x265',
        'Movie.2020.Complete.BDRip',
        'Movie.2020.1080p.BluRay.DTS-HD.MA',
        'Isolation.2020.1080p',
        'Show.S01.Complete.DVDRip',
        'Oppenheimer.2023.BluRay.2160p.HDR.MULTi.5.1.AV1.Opus.DVD5-CAV1aR',
        'Interstellar.2014.Complete.BluRay.1080p.Re-Encode.AVC.DTS-HD.MA.5.1-GRP',
      ]) {
        expect(isFullDisc(t), isFalse, reason: t);
      }
    });

    test('Blu-ray labels', () {
      expect(blurayLabelOf('Movie.2010.COMPLETE.BLURAY-GRP'), 'BLU-RAY');
      expect(blurayLabelOf('Movie 2010 BD50'), 'BLU-RAY');
      expect(blurayLabelOf('Movie.2019.COMPLETE.UHD.BLURAY-GRP'), 'UHD BLU-RAY');
      expect(blurayLabelOf('Movie.2019.2160p.BDMV.HEVC'), 'UHD BLU-RAY');
      expect(blurayLabelOf('Reservoir.Dogs.1992.1080p.BluRay.DDP5.1.iso'), 'BLU-RAY ISO');
      expect(blurayLabelOf('Die.Hard.1.1988.4K.UHD.Bluray.Disc.ISO.File-Sixty'), 'UHD BLU-RAY ISO');
      for (final t in [
        'Movie.2005.COMPLETE.DVD-GRP',
        'Movie.2005.DVD9-GRP',
        'Movie.2005.DVD9.ISO',
        'Movie.2019.2160p.UHD.BluRay.REMUX.HEVC-GRP',
        'Movie.2019.1080p.BluRay.x264-GRP',
      ]) {
        expect(blurayLabelOf(t), isNull, reason: t);
      }
    });
  });
}
