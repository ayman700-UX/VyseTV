// What this device remembers of how releases went (the Usenet search spec, section 8.7).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/usenet_names.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_search.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

const day = Duration(days: 1);
final start = DateTime.utc(2026, 10, 1);
var clock = start;

final mine = UsenetProvider(id: 'p1', name: 'Mine', host: 'news.example.test', username: 'user', password: 'secret', connections: 20, priority: 1);
final backup = UsenetProvider(id: 'p2', name: 'Backup', host: 'backup.example.test', username: 'user', password: 'secret');
List<String> get servers => [mine.serverUrl];
List<String> get otherServers => ['nntps://other:pass@elsewhere.example.test:563/50?priority=2'];

String sha(String s) => sha256.convert(utf8.encode(s)).toString();

var _n = 0;
AddonStream stream(String title, {String? url, int size = 2000000000, DateTime? posted, bool series = true}) {
  final r = UsenetRelease(
    title: title,
    nzbUrl: url ?? 'https://a.test/getnzb/${_n++}.nzb',
    indexerId: 'a',
    indexerName: 'A',
    size: size,
    publishedAt: posted?.millisecondsSinceEpoch ?? 0,
    series: series,
  );
  return AddonStream(addon: Addon.usenet, url: '', text: title, nzbUrl: r.nzbUrl, usenetRelease: r, sizeBytes: size);
}

Future<String> stored() async {
  await UsenetReleases.flushed();
  return (await SharedPreferences.getInstance()).getString('device.usenet.outcomes') ?? '';
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UsenetReleases.debugForget();
    clock = start;
    UsenetClock.debugNow = () => clock;
    UsenetSourcesStore.debugSet(UsenetSources(providers: [mine]));
    await UsenetReleases.load();
  });

  bool failed({String? url, required String title, int? size, List<String>? with_, DateTime? posted}) =>
      UsenetReleases.outcome(nzbUrl: url, title: title, size: size, servers: with_ ?? servers, posted: posted?.millisecondsSinceEpoch).failed;

  test('a failure is remembered under hashes only', () async {
    UsenetReleases.record(nzbUrl: 'https://a.test/getnzb/1.nzb&r=key', title: 'Movie.2026.2160p-GRP', size: 30000000000, servers: servers, kind: 'missing-article');
    expect(failed(url: 'https://a.test/getnzb/1.nzb&r=key', title: 'Movie.2026.2160p-GRP', size: 30000000000), isTrue);
    final text = await stored();
    expect(text, isNotEmpty);
    for (final secret in ['secret', 'key', 'Movie', 'movie', 'a.test']) {
      expect(text.contains(secret), isFalse, reason: secret);
    }
  });

  test('the same name and size from another indexer', () {
    UsenetReleases.record(nzbUrl: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', size: 25991001440, servers: servers, kind: 'missing-article');
    expect(failed(url: 'https://b.test/9', title: 'movie.2026.2160p-grp', size: 25991001000), isTrue);
    expect(failed(url: 'https://b.test/9', title: 'Movie.2026.2160p-GRP', size: 25991999999), isTrue);
    expect(failed(url: 'https://b.test/9', title: 'Movie.2026.2160p-GRP', size: 22087105000), isFalse);
  });

  test('passing failures are not remembered', () {
    for (final kind in ['provider-authentication', 'provider-quota', 'temporary-read-error', '']) {
      UsenetReleases.record(nzbUrl: 'https://a.test/$kind', title: 'Movie.$kind', size: 1000000000, servers: servers, kind: kind);
      expect(failed(url: 'https://a.test/$kind', title: 'Movie.$kind', size: 1000000000), isFalse, reason: kind);
    }
  });

  test('providers', () {
    UsenetReleases.record(nzbUrl: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', size: 1000000000, servers: servers, kind: 'missing-article');
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', with_: [mine.serverUrl, backup.serverUrl]), isFalse);
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', with_: ['nntps://other:pass@news.example.test:563/50?priority=2']), isTrue);
    UsenetReleases.record(nzbUrl: 'https://a.test/2', title: 'Fake.2026.2160p-GRP', size: 1000000000, servers: otherServers, kind: 'blank-content');
    expect(failed(url: 'https://a.test/2', title: 'Fake.2026.2160p-GRP'), isTrue);
  });

  test('30 days, and a reset', () async {
    UsenetReleases.record(nzbUrl: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', size: 1000000000, servers: servers, kind: 'missing-article');
    clock = start.add(const Duration(days: 31));
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP'), isFalse);
    clock = start;
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP'), isTrue);
    await UsenetReleases.clear();
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP'), isFalse);
  });

  test('it survives a restart', () async {
    UsenetReleases.record(nzbUrl: 'https://a.test/1', title: 'Movie.2026.2160p-GRP', size: 1000000000, servers: servers, kind: 'invalid-article');
    await UsenetReleases.flushed();
    UsenetReleases.debugForget();
    await UsenetReleases.load();
    expect(failed(url: 'https://a.test/1', title: 'Movie.2026.2160p-GRP'), isTrue);
  });

  test('an entry kept in the stored form', () async {
    SharedPreferences.setMockInitialValues({
      'device.usenet.outcomes': jsonEncode({
        'u:${sha('https://a.test/old')}': {'kind': 'missing-article', 'at': start.millisecondsSinceEpoch, 'providers': sha('nntps://news.example.test:563')},
      }),
    });
    UsenetReleases.debugForget();
    await UsenetReleases.load();
    expect(failed(url: 'https://a.test/old', title: 'Anything'), isTrue);
  });

  test('a list puts the dead last, the same again', () {
    final dead = stream('Movie.2026.2160p-DEAD', series: false), good = stream('Movie.2026.1080p-GOOD', series: false);
    UsenetReleases.failed(dead, 'missing-article');
    final once = UsenetSearch.instance.arrange([dead, good]);
    expect(once, [good, dead]);
    expect(UsenetSearch.badgesOf(dead).map((b) => b.text), ['UNAVAILABLE']);
    expect(UsenetSearch.instance.arrange(once), once);
  });

  test('a played pack, then a failure, then a play', () {
    final pack = stream('Show.S01.1080p-GRP', size: 9000000000);
    UsenetReleases.played(pack);
    expect(UsenetReleases.outcomeOf(pack), (failed: false, played: true));
    expect(UsenetReleases.outcome(nzbUrl: 'https://b.test/7', title: 'Show.S01.1080p-GRP', size: 29000000000, servers: servers).played, isTrue);
    expect(UsenetReleases.outcome(nzbUrl: 'https://b.test/7', title: 'Show.S01.1080p-GRP', size: 1500000000, servers: servers).played, isTrue);
    expect(UsenetReleases.outcome(nzbUrl: 'https://b.test/8', title: 'Show.S02.1080p-GRP', size: 9000000000, servers: servers).played, isFalse);
    clock = clock.add(const Duration(minutes: 1));
    UsenetReleases.failed(pack, 'missing-article');
    expect(UsenetReleases.outcomeOf(pack), (failed: true, played: false));
    clock = clock.add(const Duration(minutes: 1));
    UsenetReleases.played(pack);
    expect(UsenetReleases.outcomeOf(pack), (failed: false, played: true));
    clock = clock.add(const Duration(days: 15));
    expect(UsenetReleases.outcomeOf(pack).played, isFalse);
  });

  test('played again within a day is not written', () {
    final s = stream('Movie.2026.1080p-GRP', series: false);
    UsenetReleases.played(s);
    final before = UsenetReleases.changed.value;
    clock = clock.add(const Duration(hours: 1));
    UsenetReleases.played(s);
    expect(UsenetReleases.changed.value, before);
  });

  test('available first', () {
    UsenetSourcesStore.debugSet(UsenetSources(providers: [mine], availableFirst: true));
    final dead = stream('A.2026.1080p-DEAD', series: false), untried = stream('B.2026.1080p-NEW', series: false), good = stream('C.2026.1080p-GOOD', series: false);
    UsenetReleases.failed(dead, 'hole-limit');
    UsenetReleases.played(good);
    expect(UsenetSearch.instance.arrange([dead, untried, good]), [good, untried, dead]);
    UsenetSourcesStore.debugSet(UsenetSources(providers: [mine]));
    expect(UsenetSearch.instance.arrange([dead, untried, good]), [untried, good, dead]);
    expect(UsenetSearch.badgesOf(good).single.text, 'AVAILABLE');
    expect(UsenetSearch.badgesOf(dead).single.text, 'UNAVAILABLE');
    expect(UsenetSearch.badgesOf(untried), isEmpty);
  });

  group('other episodes of the upload', () {
    final p = start.subtract(const Duration(days: 30));
    List<String> badges(AddonStream s) => [for (final b in UsenetSearch.badgesOf(s)) b.text];

    test('a failed episode tells its neighbours', () {
      UsenetReleases.failed(stream('Show.S01E02.2160p.WEB-DL-GRP', posted: p), 'missing-article');
      expect(badges(stream('Show.S01E03.2160p.WEB-DL-GRP', posted: p.add(const Duration(days: 7)))), ['E02 FAILED']);
      expect(badges(stream('Show.S01E03.2160p.WEB-DL-GRP', posted: p.add(const Duration(days: 6)))), ['E02 FAILED']);
      expect(badges(stream('Show.S01E03.2160p.WEB-DL-GRP', posted: p.add(const Duration(days: 204)))), isEmpty);
      expect(badges(stream('Show.S01E03.2160p.WEB-DL-GRP')), isEmpty);
      expect(UsenetReleases.sibling(title: 'Show.S01E02.2160p.WEB-DL-GRP', servers: servers, posted: p.millisecondsSinceEpoch), isNull);
      expect(badges(stream('Show.S01E03.1080p.WEB-DL-GRP', posted: p)), isEmpty);
      expect(badges(stream('Show.S02E03.2160p.WEB-DL-GRP', posted: p)), isEmpty);
      expect(UsenetReleases.sibling(title: 'Show.S01E03.2160p.WEB-DL-GRP', servers: otherServers, posted: p.millisecondsSinceEpoch), isNull);
      expect(badges(stream('Show.S01.2160p.WEB-DL-GRP', posted: p)), ['SEASON PACK']);
      expect(badges(stream('Show.S01E03E04.2160p.WEB-DL-GRP', posted: p)), isEmpty);
    });

    test('a played episode, for two weeks', () {
      UsenetReleases.played(stream('Show.S01E04.2160p.WEB-DL-GRP', posted: p.add(const Duration(days: 14))));
      final e05 = stream('Show.S01E05.2160p.WEB-DL-GRP', posted: p.add(const Duration(days: 21)));
      expect(badges(e05), ['E04 PLAYED']);
      clock = clock.add(const Duration(days: 15));
      expect(badges(e05), isEmpty);
    });

    test('a repost is another upload', () {
      const title = 'Slow.Horses.S02E02.Hello.Goodbye.2160p.ATVP.WEB-DL.DDP5.1.HDR.H.265-FLUX';
      UsenetReleases.failed(stream(title, url: 'https://a.test/x', size: 4000000000, posted: p), 'missing-article');
      expect(UsenetReleases.isUnplayable(stream(title, url: 'https://b.test/y', size: 4000000000, posted: p.add(const Duration(hours: 12)))), isTrue);
      expect(UsenetReleases.isUnplayable(stream(title, url: 'https://b.test/y', size: 4000000000, posted: p.add(const Duration(days: 204)))), isFalse);
    });

    test('episode names differ', () {
      UsenetReleases.failed(stream('Show.S01E04.Visiting.Hours.1080p.WEB.H264-GRP', posted: p), 'missing-article');
      expect(badges(stream('Show.S01E06.Follies.1080p.WEB.H264-GRP', posted: p.add(const Duration(days: 14)))), ['E04 FAILED']);
      final e04 = stream('Lioness.S01E04.Truth.Is.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-CRFW', posted: p.add(const Duration(days: 14)));
      UsenetReleases.played(e04);
      expect(badges(stream('Lioness.S01E02.Sinister.Intentions.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-CRFW', posted: p.add(const Duration(days: 7)))), ['E04 PLAYED']);
      expect(badges(stream('Lioness.S01E02.Sinister.Intentions.1080p.WEB-DL.DDP5.1.H.264-CRFW', posted: p.add(const Duration(days: 7)))), isEmpty);
      clock = clock.add(const Duration(hours: 1));
      UsenetReleases.played(stream('Lioness.S01E02.Sinister.Intentions.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-CRFW', posted: p.add(const Duration(days: 7))));
      clock = clock.add(const Duration(hours: 1));
      UsenetReleases.played(e04);
      expect(badges(stream('Lioness.S01E03.Ride.Along.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-CRFW', posted: p.add(const Duration(days: 10)))), ['E04 PLAYED']);
    });

    test('a fake post makes its neighbours go last', () {
      UsenetReleases.record(nzbUrl: 'https://a.test/e2', title: 'Show.S01E02.2160p-FAKE', size: 1000000000, servers: otherServers, kind: 'blank-content', posted: p.millisecondsSinceEpoch);
      final fake = stream('Show.S01E03.2160p-FAKE', posted: p.add(const Duration(days: 7)));
      final real = stream('Show.S01E03.2160p-GRP', posted: p.add(const Duration(days: 7)));
      expect(badges(fake), ['E02 FAILED']);
      expect(UsenetReleases.siblingOf(fake)!.blank, isTrue);
      expect(UsenetSearch.instance.arrange([fake, real]), [real, fake]);
      UsenetReleases.failed(fake, 'blank-content');
      expect(badges(fake), ['UNAVAILABLE']);
    });
  });
}
