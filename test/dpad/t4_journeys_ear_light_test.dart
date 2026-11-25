// Subtitle sync by ear must not cost the film its own download (2026-11-26).
//
// A tester: CNO's 4K films play without a stop on an iPhone and an Android phone, and "buffer
// every 5-10 seconds" on a Google TV; then: "I've tried the older version 1.0.1 and I can
// completely watch 4K movies using CNO on my Google TV". What 1.0.2 added on that path is the
// subtitle sync by ear: with a downloaded subtitle on (they come on by themselves), up to four
// 45-second stretches of the film's sound are fetched by a second player, as fast as the line
// gives them, while the film plays. A stream's sound is inside its picture's pieces: measured on
// CNO's 4K stream with the app's own mpv, one stretch is about 70 MB; from its 480p version,
// 3.7 MB, and the two sounds are in step to the hundredth of a second.
//
// So: the listener takes the smallest version of the stream there is; on a TV a stream taller
// than 1080p with no smaller version is not listened to; and on any device the listening ends
// the moment the film has to stop to load. CNO's scraper kept only the first of the four sizes
// its server lists, so there was nothing smaller to take: it keeps them all now.
//
// On a PC, with the bed standing in for Media3 and for the listener's mpv. That a TV now plays
// CNO's 4K without stopping is the tester's to say.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/playback/stream_proxy.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/scrapers.dart' show cnoStream;
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/subtitles/sound_sync.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Player;

import 'harness.dart';
import 't4_journeys_autosync_test.dart' show filmLines, retimed, srt;

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);
  final own = filmLines(61, until: 1800);
  late FakeRoute route;
  late String file;
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
    file = srt(retimed(own, 2.4, 62));
    route = Bed.http.route;
    Bed.http.route = (method, uri) => switch (uri.host) {
      'files.test' => const FakeReply(206, [0, 0, 0, 0], type: 'video/mp4'),
      'subs.test' => FakeReply(200, utf8.encode(file), type: 'text/plain; charset=utf-8'),
      _ => route(method, uri),
    };
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
    debugFilmSources = null;
    Bed.http.route = route;
    Bed.exoAnswers.clear();
  });

  /// What the listener's mpv was asked to open, oldest first.
  List<String> listenedTo() => [
    for (final c in Bed.audioCalls)
      if (c.startsWith('mpv_audio_listener command') && c.contains('loadfile')) RegExp(r'files\.test/([\w.]+)').firstMatch(c)?[1] ?? c,
  ];

  /// What Media3 was asked to open.
  List<String> opened() => [
    for (final c in Bed.exoCalls)
      if (c.startsWith('open ')) RegExp(r'files\.test/([\w.]+)').firstMatch(c)?[1] ?? c,
  ];

  /// Opens a film with a French subtitle file on, Media3 saying its picture is [width] wide, and
  /// plays it to half a minute in. Then [seconds] go by.
  Future<void> play(WidgetTester t, {required int width, required int height, int seconds = 12}) async {
    final film = Bed.freshTitle();
    WatchProgress.record(
      film,
      position: const Duration(seconds: 4),
      duration: const Duration(minutes: 100),
      subtitle: const {'id': 'fr-7', 'provider': 'OpenSubtitles', 'lang': 'fr', 'language': 'French', 'release': '', 'url': 'http://subs.test/ear.fr.srt', 'format': 'srt'},
    );
    Bed.exoAnswers['getStats'] = {'videoWidth': width, 'videoHeight': height};
    Bed.exoCalls.clear();
    Bed.audioCalls.clear();
    await Bed.openPlayer(t, media: film);
    // (the subtitle file is fetched and written to disk: real time)
    for (var i = 0; i < 30; i++) {
      await Bed.settle(t, rounds: 1);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await Bed.exoEvent(t, 'playback-restart'); // (Media3 shows a frame, and is asked the picture's size)
    await Bed.exoProperty(t, 'duration', 1800.0);
    await Bed.exoProperty(t, 'pause', false);
    await Bed.exoProperty(t, 'paused-for-cache', false);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
    await Bed.exoProperty(t, 'time-pos', 30.0);
    for (var i = 0; i < seconds; i++) {
      await t.pump(const Duration(seconds: 1));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  }

  Future<void> close(WidgetTester t) async {
    await Bed.closePlayer(t);
    t.takeException(); // (progress saved as the page goes: see t4_journeys_autosync_test.dart)
    await t.pump(const Duration(seconds: 31));
  }

  testWidgets('a 4K link whose server also has a 480p version: the 4K plays, and the 480p is what is listened to', (t) async {
    debugFilmSources = [
      FilmSource(
        id: 'first',
        name: 'First',
        note: '',
        scraper: (_) async => const [
          FoundStream(
            url: 'http://files.test/film.2160.mp4',
            type: 'mp4',
            quality: '3840x2160',
            qualities: [
              (label: '4K', url: 'http://files.test/film.2160.mp4'),
              (label: '1080p', url: 'http://files.test/film.1080.mp4'),
              (label: '480p', url: 'http://files.test/film.480.mp4'),
            ],
          ),
        ],
      ),
    ];
    await play(t, width: 3840, height: 2160);
    expect(opened().first, 'film.2160.mp4', reason: "the link's own size plays first, not 1080p: ${opened()}");
    expect(listenedTo(), isNotEmpty, reason: 'the listener: ${Bed.audioCalls.take(8)}');
    expect(listenedTo().toSet(), {'film.480.mp4'}, reason: 'never the 4K one');
    await close(t);
  }, variant: tv);

  testWidgets('a 4K stream with no smaller version, on a TV: not listened to at all', (t) async {
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.2160.mp4', type: 'mp4')]),
    ];
    await play(t, width: 3840, height: 2160, seconds: 20);
    expect(opened(), ['film.2160.mp4']);
    expect(listenedTo(), isEmpty, reason: 'it would take as much again as the film itself');
    expect(Bed.audioCalls.where((c) => c.startsWith('mpv_audio_listener')), isEmpty, reason: "the listener's player is never even made");
    await close(t);
  }, variant: tv);

  testWidgets('a 1080p stream on a TV is listened to, until the film has to stop to load: then never again for that film', (t) async {
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.1080.mp4', type: 'mp4')]),
    ];
    await play(t, width: 1920, height: 1080);
    expect(listenedTo(), ['film.1080.mp4'], reason: 'the first stretch is being fetched: ${Bed.audioCalls.take(8)}');
    // (the page tells a stop to load from a seek's own loading by the real clock: three seconds)
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3200)));
    await Bed.exoProperty(t, 'paused-for-cache', true); // the film stops to load
    await Bed.settle(t, rounds: 2);
    expect(Bed.audioCalls.where((c) => c.startsWith('mpv_audio_listener dispose')), hasLength(1), reason: 'the listener lets go at once');
    await Bed.exoProperty(t, 'paused-for-cache', false);
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(seconds: 1));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(listenedTo(), ['film.1080.mp4'], reason: 'and does not start again');
    await close(t);
  }, variant: tv);

  // ── the pieces ──

  test("CNO's answer: the first size plays, as before, and every size listed is kept", () {
    const answer = '#EXTM3U\n#EXT-X-VERSION:3\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=16100000,RESOLUTION=3840x2160,CODECS="avc1.640033,mp4a.40.2"\nhttps://v.example.top/v/abc/3840x2160/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=6100000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"\nhttps://v.example.top/v/abc/1920x1080/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3100000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"\n/v/abc/1280x720/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1300000,RESOLUTION=852x480,CODECS="avc1.4d401e,mp4a.40.2"\nhttps://v.example.top/v/abc/852x480/index.m3u8\n';
    final s = cnoStream(answer, 'https://cno.example');
    expect(s.url, 'https://v.example.top/v/abc/3840x2160/index.m3u8');
    expect(s.quality, '3840x2160');
    expect([for (final q in s.qualities) q.label], ['4K', '1080p', '720p', '480p']);
    expect(s.qualities[2].url, 'https://cno.example/v/abc/1280x720/index.m3u8', reason: "a path is the site's own");
    expect(s.qualities.first.url, s.url);
    // one size only: nothing to choose from, as before
    final one = cnoStream('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=6100000,RESOLUTION=1920x1080\nhttps://v.example.top/a.m3u8\n', 'https://cno.example');
    expect((one.url, one.quality), ('https://v.example.top/a.m3u8', '1920x1080'));
    expect(one.qualities, isEmpty);
    // a plain playlist (no sizes at all): its first address, as before
    final plain = cnoStream('#EXTM3U\n#EXTINF:6.0,\nseg-1.ts\n', 'https://cno.example');
    expect((plain.url, plain.quality), ('seg-1.ts', 'Auto'));
    expect(plain.qualities, isEmpty);
  });

  test('the smallest version of a stream, by size and then by bitrate', () {
    const v4k = StreamVariant(url: 'a', name: '4K'), v1080 = StreamVariant(url: 'b', name: '1080p'), v480 = StreamVariant(url: 'c', name: '480p');
    expect(StreamVariant.lightest(const [v4k, v1080, v480])?.url, 'c');
    expect(StreamVariant.lightest(const [v480, v4k])?.url, 'c');
    expect(
      StreamVariant.lightest(const [StreamVariant(url: 'hi', width: 1280, height: 720, bandwidth: 4000000), StreamVariant(url: 'lo', width: 1280, height: 720, bandwidth: 2000000)])?.url,
      'lo',
    );
    expect(StreamVariant.lightest(const [StreamVariant(url: 'x', name: 'Auto')]), isNull, reason: 'a name that is not a size says nothing');
    expect((StreamVariant.linesOf('4K'), StreamVariant.linesOf('1080p'), StreamVariant.linesOf('Auto')), (2160, 1080, 0));
  });

  test('on a TV nothing taller than 1080p is listened to; elsewhere anything is', () {
    expect(tooHeavyToHear(lines: 2160, tv: true), isTrue);
    expect(tooHeavyToHear(lines: 1440, tv: true), isTrue);
    expect(tooHeavyToHear(lines: 1080, tv: true), isFalse);
    expect(tooHeavyToHear(lines: 0, tv: true), isFalse, reason: 'a size not known yet is not held against it');
    expect(tooHeavyToHear(lines: 2160, tv: false), isFalse, reason: 'a phone or a PC has the room');
  });
}
