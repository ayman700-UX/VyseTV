// HDR, Dolby Vision and Atmos (2026-11-25). Testers: "HDR or Dolby Vision does not work, and a
// lot of people simply get a black screen, no audio on their TV", and "it doesn't completely
// play the desired true Dolby format".
//
// What reading both engines found, and what is checked here:
//  - a player error was written to the report card and nowhere else: the spinner went and the
//    screen stayed black and silent, whatever the cause. It is now said, and a link that was
//    picked for you is moved on from;
//  - Passthrough was off on every device, so Dolby Atmos was always decoded here and never
//    reached a TV or receiver. On an Android TV it now starts on;
//  - nothing said how a video ended up on screen. Stream info and the report card now do ("On
//    screen", "Heard as"), and a line comes up once when a link plays in a lesser form.
//
// As the engine tests are: the real player page on a PC, with the bed standing in for the
// Media3 plugin and the device (Bed.exoEvent, Bed.exoAnswers, Bed.deviceAnswers) and made-up
// film sources. No TV is involved: what a decoder or a receiver does with a stream is not
// something these can show.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/playback_failure.dart';
import 'package:vyse_tv/data/playback/playback_report.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/mpv/mpv.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';
import 'playback_report_test.dart' show begin, fact, playing, tcl;

/// A TV whose screen takes HDR10 and nothing more, with no Dolby Vision decoder.
const hdr10Tv = <String, Object?>{
  'device': 'Xiaomi MiTV',
  'android': '11',
  'sdk': 30,
  'displayHdr': ['HDR10', 'HLG'],
  'dvDecoders': <String>[],
  'dvProfile5': false,
  'dvProfile7': false,
  'dvProfile8': false,
  'dvBridgeReady': true,
  'dvAutoMode': 'HEVC_STRIP',
};

/// A TV with no HDR at all.
const sdrTv = <String, Object?>{'device': 'Old TV', 'android': '9', 'sdk': 28, 'displayHdr': <String>[], 'dvDecoders': <String>[]};

/// What Media3 says of a profile 8 film with Atmos that it plays through the HEVC decoder,
/// its sound decoded to 5.1.
const p8AsHdr10 = <String, Object?>{
  'videoCodec': 'dvhe.08.06',
  'videoMimeType': 'video/dolby-vision',
  'videoWidth': 3840,
  'videoHeight': 2160,
  'videoDecoderName': 'c2.mtk.hevc.decoder',
  'colorTransfer': 6,
  'audioMimeType': 'audio/eac3-joc',
  'audioSampleRate': 48000,
  'audioChannels': 6,
  'audioOutputEncoding': 2,
  'audioOutputChannels': 6,
  'firstFrameMs': 3100,
  'dvConversionActive': false,
  'dvConversionMode': 'HEVC_STRIP',
  'dvConversionDebugMode': 'AUTO',
  'dvSourceProfile': 8,
  'dvPlaybackPath': 'HDR fallback',
  'dvPlaybackReason': 'Profile 8 is being decoded through the HEVC/HDR10-compatible path',
};

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  late FakeRoute route;
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
    PlaybackReport.debugReset();
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv?token=SECRET123', type: 'mkv')]),
      FilmSource(id: 'second', name: 'Second', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/second.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
    AppSettings.mpvHandOver.set(true);
    debugFilmSources = null;
    Bed.http.route = route;
    Bed.exoAnswers.clear();
    Bed.deviceAnswers.clear();
  });
  final tv = OnScreens([Screens.tv]);

  String key() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Pressable>()?.tooltip ?? '';
  PlayerPanel panel(WidgetTester t) => t.widget<PlayerPanel>(find.byType(PlayerPanel));
  Finder inMenu(Finder what) => find.descendant(of: find.byType(PlayerPanel), matching: what);

  Future<void> goTo(WidgetTester t, String name) async {
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.left(t);
    }
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.right(t);
    }
    expect(key(), name);
  }

  /// The links the player was asked to open, oldest first.
  List<String> opened() => [
    for (final c in Bed.exoCalls)
      if (c.startsWith('open ')) RegExp(r'files\.test/(\w+)\.mkv').firstMatch(c)?[1] ?? c,
  ];

  /// Media3 gives the video up with [message], as its plugin reports it.
  Future<void> gaveUp(WidgetTester t, String message) async {
    await Bed.exoProperty(t, 'paused-for-cache', false);
    await Bed.exoEvent(t, 'end-file', {'reason': 'error', 'message': message});
  }

  // ── The black, silent screen ──

  testWidgets('a link picked for you that the player gives up is moved on from, at once and not 25 seconds later', (t) async {
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    expect(opened(), ['first']);
    await t.pump(const Duration(seconds: 3));
    await gaveUp(t, 'MediaCodecVideoRenderer error, index=0, format=Format(1, null, video/x-matroska, video/hevc, hvc1.2.4.L153.B0, -1, null, [3840, 2160, 23.976], [-1, -1]), format_supported=YES');
    await Bed.settle(t, rounds: 4);
    expect(opened(), ['first', 'second'], reason: 'the next source that answers plays');
    expect(find.byType(PlaybackProblem), findsNothing, reason: 'nothing to say while something else is opening');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('when nothing else plays either, the screen says why, and the remote reaches Sources', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    Bed.deviceAnswers['getPlaybackCapabilities'] = hdr10Tv;
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    await gaveUp(t, 'Video track present but no decoder available (video/dolby-vision)');
    await Bed.settle(t, rounds: 4);
    expect(opened(), ['first']);
    final problem = find.byType(PlaybackProblem);
    expect(problem, findsOneWidget, reason: 'where the spinner was');
    expect(find.descendant(of: problem, matching: find.text("This link didn't play")), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text('This device has no Dolby Vision decoder, and this video has no HDR10 picture to fall back on')), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text('Pick another source')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'nothing is loading any more');
    await Bed.picture(t, 'hdr/did_not_play');

    // the controls came up with it: Sources is a few presses away
    await Bed.down(t);
    await goTo(t, 'Sources');
    // and the card keeps the engine's own words
    await goTo(t, 'Stream info');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect((panel(t).open, panel(t).tab), (true, MenuTab.info));
    await Bed.down(t);
    await Bed.settle(t, rounds: 1);
    expect(inMenu(find.textContaining('Did not play: Video track present but no decoder available (video/dolby-vision)')), findsOneWidget);
    await Bed.back(t);
    await Bed.closePlayer(t);
    expect(PlaybackReport.last.value!.summary, endsWith('did not play'));
  }, variant: tv);

  testWidgets('with the switch to mpv turned off, a picture Media3 cannot decode says where to turn it on', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    AppSettings.mpvHandOver.set(false);
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    await gaveUp(t, 'Decoder hang: c2.mtk.dvhe.stn.decoder accepted input but produced no output');
    await Bed.settle(t, rounds: 4);
    final problem = find.byType(PlaybackProblem);
    expect(find.descendant(of: problem, matching: find.text("This device's decoder took the video and showed nothing")), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text("Turn on Switch to mpv when Media3 can't play, in Settings > Playback, or pick another source")), findsOneWidget);
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('a film that stops part way says Playback stopped, over the picture', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    await Bed.openPlayer(t);
    await Bed.exoEvent(t, 'playback-restart');
    await Bed.exoProperty(t, 'paused-for-cache', false);
    // (the player passes positions on a few times a second, by the clock: let one through)
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
    await Bed.exoProperty(t, 'time-pos', 1200.0); // (no length given: nothing is kept of where it stopped)
    await t.pump(const Duration(seconds: 6));
    await gaveUp(t, 'Source error');
    await Bed.settle(t, rounds: 4);
    final problem = find.byType(PlaybackProblem);
    expect(find.descendant(of: problem, matching: find.text('Playback stopped')), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text('The link did not answer')), findsOneWidget);
    await Bed.closePlayer(t);
  }, variant: tv);

  // ── A lesser form is never silent ──

  testWidgets('Dolby Vision shown as HDR10 says so once, and Stream info says what is on screen and how the sound leaves', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    AppSettings.audioPassthrough.set(false);
    addTearDown(() => AppSettings.audioPassthrough.set(AppSettings.passthroughStartsOn));
    Bed.exoAnswers['getStats'] = p8AsHdr10;
    Bed.deviceAnswers['getPlaybackCapabilities'] = hdr10Tv;
    await Bed.openPlayer(t);
    await Bed.exoEvent(t, 'playback-restart');
    await Bed.settle(t, rounds: 3);
    expect(find.text('Dolby Vision shown as HDR10 · this screen has no Dolby Vision\nAtmos decoded to 5.1 · Passthrough is off'), findsOneWidget, reason: 'the picture, then the sound');
    await Bed.picture(t, 'hdr/shown_as_hdr10');
    await t.pump(const Duration(seconds: 6)); // (the line goes by itself)

    await Bed.down(t);
    await goTo(t, 'Stream info');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(inMenu(find.text('HDR10, its HDR10 layer')), findsOneWidget, reason: 'On screen');
    expect(inMenu(find.text('Decoded here to 5.1')), findsOneWidget, reason: 'Heard as');
    await Bed.picture(t, 'hdr/stream_info');
    await Bed.back(t);
    await Bed.closePlayer(t);
    final last = PlaybackReport.last.value!;
    expect(fact(last.card, 'Outcome', 'On screen'), 'HDR10, its HDR10 layer');
    expect(fact(last.card, 'Outcome', 'Heard as'), 'Decoded here to 5.1');
  }, variant: tv);

  testWidgets('a film that plays as it is says nothing', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    Bed.exoAnswers['getStats'] = {...playing, 'audioMimeType': 'audio/eac3-joc', 'audioOutputEncoding': 18};
    Bed.deviceAnswers['getPlaybackCapabilities'] = tcl;
    await Bed.openPlayer(t);
    await Bed.exoEvent(t, 'playback-restart');
    await Bed.settle(t, rounds: 3);
    expect(find.textContaining('shown as'), findsNothing);
    expect(find.textContaining('decoded'), findsNothing);
    await Bed.closePlayer(t);
    final last = PlaybackReport.last.value!;
    expect(fact(last.stream, 'Video', 'On screen'), 'Dolby Vision');
    expect(fact(last.stream, 'Audio', 'Heard as'), 'Passed through as Dolby Digital Plus with Atmos');
  }, variant: tv);

  // ── Passthrough ──

  testWidgets('an Android TV starts with Passthrough on, and the player tells the engine so', (t) async {
    expect(AppSettings.passthroughStartsOn, isTrue);
    AppSettings.audioPassthrough.set(AppSettings.passthroughStartsOn);
    debugFilmSources = [debugFilmSources!.first];
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    final said = Bed.exoCalls.where((c) => c.startsWith('setAudioPassthrough') || (c.startsWith('initialize') && c.contains('audioPassthroughEnabled')));
    expect(said, isNotEmpty);
    expect(said.last, contains('true'), reason: 'Dolby and DTS go to the TV as they are when it takes them');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('in a small tile (a watch party room) the reason is one short block, and nothing runs over', (t) async {
    for (final size in const [Size(320, 180), Size(240, 135), Size(560, 240)]) {
      await t.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: size,
            child: const Center(
              child: PlaybackProblem(title: "This link didn't play", why: 'this device has no Dolby Vision decoder, and this video has no HDR10 picture to fall back on', hint: 'Pick another source'),
            ),
          ),
        ),
      ));
      expect(t.takeException(), isNull, reason: '$size');
      expect(find.textContaining("This link didn't play: this device has no Dolby Vision decoder"), findsOneWidget, reason: '$size');
    }
  });

  // ── Memory: a 4K remux on a TV ──

  // mpv fills the read-ahead it is allowed. Its Android core sets that from the device's memory
  // (32 to 100 MB); the player page replaced it with 400 MB ahead and 128 MB behind, which only
  // a high-bitrate film (a 4K HDR or Dolby Vision remux) ever fills, on TVs with 2 GB in all.
  testWidgets('on Android the player leaves the read-ahead memory to the engine, also for the mpv Media3 hands over to', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    final queued = [for (final c in Bed.exoCalls) if (c.startsWith('setMpvProperty')) c];
    expect(queued.where((c) => c.contains('name: cache-secs')), isNotEmpty, reason: 'how far ahead, in seconds, is still said');
    expect(queued.where((c) => c.contains('demuxer-max-bytes') || c.contains('demuxer-max-back-bytes')), isEmpty);
    await Bed.closePlayer(t);
  }, variant: tv);

  // ── A slow link ──

  // Media3 gave a link that sends nothing four tries, about 43 seconds, then handed the video to
  // mpv, which the app tells to wait 60 (120 for a torrent). The plugin now takes mpv's
  // `network-timeout` as Media3's patience too (SlowLinkPolicy.kt): it has to be said before the
  // video is opened, each time.
  testWidgets('the player says how long to wait for a link before it opens it, on Media3 as on mpv', (t) async {
    debugFilmSources = [debugFilmSources!.first];
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    final said = Bed.exoCalls.indexWhere((c) => c.startsWith('setMpvProperty') && c.contains('name: network-timeout'));
    final open = Bed.exoCalls.indexWhere((c) => c.startsWith('open '));
    expect(said, greaterThanOrEqualTo(0));
    expect(Bed.exoCalls[said], contains('value: 60'));
    expect(open, greaterThan(said), reason: 'before the open, so the first read is already under it');
    await Bed.closePlayer(t);
  }, variant: tv);

  test('the report card says how long Media3 asks a quiet link', () {
    String? quiet(Object? ms) => fact(begin().withMedia3({'videoMimeType': 'video/hevc', 'networkPatienceMs': ?ms}).card, 'Decision', 'A quiet link');
    expect(quiet(60000), 'Asked again for 60 s, as mpv is');
    expect(quiet(120000), 'Asked again for 120 s, as mpv is');
    expect(quiet(0), "Media3's own four tries, about 40 s");
    expect(quiet(null), isNull, reason: 'an older plugin, or mpv: nothing is claimed');
  });

  // ── The words ──

  test('why a video did not play, in plain words', () {
    ({String title, String why, String hint}) w(String m, {String? cause, bool started = false, bool off = false, bool others = true}) =>
        PlaybackFailure.words(m, cause: cause, started: started, handOverOff: off, otherSources: others);
    expect(w('Video track present but no decoder available (video/av01)').why, 'this device has no decoder for this picture (AV1)');
    expect(w('Audio track present but no decoder available (audio/true-hd, audio/vnd.dts.hd)').why, 'this device has no decoder for this sound (TrueHD, DTS-HD)');
    expect(w('HTTP 404', cause: 'server-http-404').why, 'the server no longer has this file');
    expect(w('Response code: 403').why, 'the server refused it (403)');
    expect(w('HTTP 500', cause: 'server-http-500').why, 'the server is not answering (500)');
    expect(w('loading failed').why, 'the link did not answer');
    expect(w('unrecognized file format').why, 'it is not a video file the player can read');
    expect(w('audio output initialization failed').why, 'this device would not take the sound');
    expect(w('video output initialization failed').why, 'the picture could not be shown on this screen');
    expect(w('Playback stalled while buffering for 30000ms').why, 'the link stopped sending');
    expect(w('Playback error').why, '', reason: 'nothing known is not dressed up');
    expect(w('Odd thing at https://cdn.example.net/a/b.mkv?token=SECRET').why, 'Odd thing at cdn.example.net', reason: 'an unknown sentence is shown, never an address');
    expect(w('loading failed', others: false).hint, '', reason: 'a media server has no other source to offer');
    expect(w('loading failed', started: true).title, 'Playback stopped');
    expect(PlaybackFailure.line(w('loading failed')), "This link didn't play: the link did not answer. Pick another source");
    expect(PlaybackFailure.line(w('Playback error')), "This link didn't play. Pick another source");
    // (the mpv switch only matters for what a decoder could not do)
    expect(w('loading failed', off: true).hint, 'Pick another source');
  });

  test('what is on screen, by what the engine did and what the screen takes', () {
    PlaybackReport r(Map<String, Object?> exo, Map<String, Object?> caps) => begin().withMedia3(exo).withDevice(caps);
    // profile 5 on a Dolby Vision TV: as it is
    expect((r(playing, tcl).onScreen, r(playing, tcl).lesser), ('Dolby Vision', null));
    // profile 8 through the HEVC decoder
    expect(r(p8AsHdr10, hdr10Tv).onScreen, 'HDR10, its HDR10 layer');
    expect(r(p8AsHdr10, hdr10Tv).lesser, startsWith('Dolby Vision shown as HDR10 · this screen has no Dolby Vision'), reason: 'the picture first (the sound, decoded here, follows)');
    expect(r(p8AsHdr10, tcl).lesser, startsWith('Dolby Vision shown as HDR10 · no Dolby Vision decoder here plays it'));
    expect(r(p8AsHdr10, sdrTv).onScreen, 'SDR, mapped by the TV from its HDR10 layer');
    // profile 7: converted, or its Dolby Vision taken out
    final p7 = {...playing, 'videoCodec': 'dvhe.07.06', 'dvSourceProfile': 7};
    expect(r({...p7, 'dvPlaybackPath': 'P7 -> P8.1', 'dvConversionActive': true}, tcl).onScreen, 'Dolby Vision, profile 7 converted to 8.1');
    expect(r({...p7, 'dvPlaybackPath': 'P7 -> HEVC', 'dvConversionMode': 'HEVC_STRIP', 'dvConversionActive': true}, hdr10Tv).lesser, 'Dolby Vision shown as HDR10 · this screen has no Dolby Vision');
    // a Dolby Vision decoder on a box whose screen has none: the box converts
    expect(r(playing, hdr10Tv).onScreen, "Converted by the TV's Dolby Vision decoder");
    // plain HDR10
    const hdr10 = {'videoMimeType': 'video/hevc', 'videoCodec': 'hvc1.2.4.L153.B0', 'colorTransfer': 6};
    expect((r(hdr10, hdr10Tv).onScreen, r(hdr10, hdr10Tv).lesser), ('HDR10', null));
    expect((r(hdr10, sdrTv).onScreen, r(hdr10, sdrTv).lesser), ('SDR, mapped by the TV', 'HDR10 shown as SDR · this screen has no HDR'));
    // a device that does not say what its screen takes (a PC): nothing is claimed
    expect(begin(engine: 'mpv').withMpv(const {'video-params/w': '3840', 'video-params/gamma': 'pq'}).onScreen, '');
    // mpv on a TV, by the way it took the video
    PlaybackReport m(String route, Map<String, Object?> caps, [String gamma = 'pq']) =>
        begin(engine: 'mpv').withMpv({'video-params/w': '3840', 'video-params/gamma': gamma, 'dvSourceProfile': 5, 'dvRoute': route}).withDevice(caps);
    expect(m('dv-decoder', tcl).onScreen, 'Dolby Vision');
    expect(m('reshaped', hdr10Tv).lesser, 'Dolby Vision is decoded in software here · it may stutter');
    expect(m('base-layer', hdr10Tv).lesser, 'Dolby Vision shown as HDR10 · this screen has no Dolby Vision');
  });

  test('how the sound leaves: passed through or decoded, and why Atmos was decoded', () {
    PlaybackReport r(Map<String, Object?> exo, {bool passthrough = true, bool forced = false}) =>
        begin().withMedia3({'videoMimeType': 'video/hevc', ...exo}).withSoundSettings(passthrough: passthrough, decodeForced: forced);
    const atmos = {'audioMimeType': 'audio/eac3-joc', 'audioChannels': 6};
    expect(r({...atmos, 'audioOutputEncoding': 18}).heard, 'Passed through as Dolby Digital Plus with Atmos');
    expect(r({...atmos, 'audioOutputEncoding': 6}).heard, 'Passed through as Dolby Digital Plus, Atmos inside');
    expect(r({...atmos, 'audioOutputEncoding': 6}).lesser, isNull);
    final decoded = {...atmos, 'audioOutputEncoding': 2, 'audioOutputChannels': 2};
    expect(r(decoded, passthrough: false).heard, 'Decoded here to stereo');
    expect(r(decoded, passthrough: false).lesser, 'Atmos decoded to stereo · Passthrough is off');
    expect(r(decoded, forced: true).lesser, 'Atmos decoded to stereo · levelling or Stereo is on');
    expect(r(decoded).lesser, "Atmos decoded to stereo · the TV's sound output does not take it");
    // TrueHD in its carrier, and plain surround decoded (nothing lesser about that)
    expect(r({'audioMimeType': 'audio/true-hd', 'audioOutputEncoding': 13}).heard, 'Passed through as TrueHD');
    expect(r({'audioMimeType': 'audio/ac3', 'audioOutputEncoding': 4, 'audioOutputChannels': 6}, passthrough: false).lesser, isNull);
    expect(r(const {'audioMimeType': 'audio/eac3-joc'}).heard, '', reason: 'until the sound output is open, nothing is said');
    // mpv
    PlaybackReport m(Map<String, Object?> mpv) => begin(engine: 'mpv').withMpv({'audio-codec-name': 'eac3', ...mpv}).withSoundSettings(passthrough: false);
    expect(m({'audio-params/format': 'spdif-eac3', 'current-tracks/audio/codec-profile': 'Dolby Digital Plus + Dolby Atmos'}).heard, 'Passed through as Dolby Digital Plus, Atmos inside');
    expect(m({'audio-params/format': 'spdif-truehd'}).heard, 'Passed through as TrueHD');
    expect(m({'audio-params/format': 'floatp', 'audio-params/hr-channels': '5.1(side)', 'audio-out-params/hr-channels': 'stereo', 'current-tracks/audio/codec-profile': 'Dolby Digital Plus + Dolby Atmos'}).lesser, 'Atmos decoded to stereo · Passthrough is off');
  });
}
