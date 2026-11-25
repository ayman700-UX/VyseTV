// The same on a phone, where the engine is mpv (2026-11-25): a video the player gives up says
// why instead of leaving a black, silent screen. On a phone the middle of the screen is the
// play button while the controls are up, so the line sits under it; once they hide, it is the
// message in the middle, as on a TV. t4_journeys_hdr_test.dart has the TV and the rest.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/playback_failure.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/screens/player/player_page.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
  });
  final phone = OnScreens([Screens.phone]);
  late FakeRoute route;
  setUp(() {
    PlayerPage.debugTouch = true;
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    PlayerPage.debugTouch = null;
    debugFilmSources = null;
    Bed.http.route = route;
  });

  testWidgets('a phone: mpv gives the film up, and the screen says why with the controls up and after they hide', (t) async {
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    await Bed.videoProperty(t, 'paused-for-cache', false);
    // (mpv's end of file with an error: -13 is "loading failed")
    await Bed.videoEvent(t, 'end-file', {'reason': 4, 'error': -13});
    await Bed.settle(t, rounds: 4);
    expect(find.text("This link didn't play: the link did not answer. Pick another source"), findsOneWidget, reason: 'under the play button, while the controls are up');
    expect(find.byType(PlaybackProblem), findsNothing, reason: 'not on top of the play button');
    expect(t.takeException(), isNull, reason: 'the line fits a phone');
    await Bed.picture(t, 'hdr/did_not_play_controls');

    await t.pump(const Duration(seconds: 6)); // the controls hide
    await Bed.settle(t, rounds: 2);
    final problem = find.byType(PlaybackProblem);
    expect(problem, findsOneWidget, reason: 'in the middle, where the spinner was');
    expect(find.descendant(of: problem, matching: find.text("This link didn't play")), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text('The link did not answer')), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text('Pick another source')), findsOneWidget);
    expect(t.takeException(), isNull);
    await Bed.picture(t, 'hdr/did_not_play');
    await Bed.closePlayer(t);
  }, variant: phone);

  // mpv ends a file only when both halves are gone. With one left it plays on and says so in
  // its log alone: a picture with no sound, or sound over a black screen.
  testWidgets('mpv gives up the sound and plays on: the screen says so', (t) async {
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    await Bed.videoProperty(t, 'paused-for-cache', false);
    await Bed.videoEvent(t, 'log-message', {'prefix': 'ad', 'level': 'error', 'text': "Failed to initialize a decoder for codec 'truehd'.\n"});
    await Bed.settle(t, rounds: 2);
    expect(find.text("No sound: this device can't play this audio track · try another track or source"), findsOneWidget);
    expect(find.byType(PlaybackProblem), findsNothing, reason: 'the picture is playing: nothing covers it');
    // (said once for a video, however often mpv logs it)
    await t.pump(const Duration(seconds: 6));
    await Bed.videoEvent(t, 'log-message', {'prefix': 'ad', 'level': 'error', 'text': "Failed to initialize a decoder for codec 'truehd'."});
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('No sound'), findsNothing);
    await Bed.closePlayer(t);
  }, variant: phone);

  testWidgets('with Passthrough on, a sound output that will not open is decoded here from then on', (t) async {
    AppSettings.audioPassthrough.set(true);
    addTearDown(() => AppSettings.audioPassthrough.set(AppSettings.passthroughStartsOn));
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    final before = Bed.videoCalls.length;
    await Bed.videoEvent(t, 'log-message', {'prefix': 'cplayer', 'level': 'error', 'text': 'Could not open/initialize audio device -> no sound.'});
    await Bed.settle(t, rounds: 3);
    expect(find.text('This device would not take the sound untouched · decoding it here for now'), findsOneWidget);
    final after = Bed.videoCalls.skip(before).where((c) => c.contains('audio-spdif')).toList();
    expect(after, isNotEmpty, reason: 'mpv is told to stop sending the sound on untouched');
    expect(after.last, isNot(contains('eac3')));
    await Bed.closePlayer(t);
  }, variant: phone);

  testWidgets('mpv gives up the picture and plays the sound on: No picture, in the middle', (t) async {
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 2));
    await Bed.videoProperty(t, 'paused-for-cache', false);
    Bed.videoProperties['vid'] = 'no';
    addTearDown(() => Bed.videoProperties.remove('vid'));
    await Bed.videoEvent(t, 'log-message', {'prefix': 'cplayer', 'level': 'error', 'text': 'Could not initialize video chain.'});
    await t.pump(const Duration(seconds: 3));
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('No picture'), findsOneWidget);
    await t.pump(const Duration(seconds: 6)); // the controls hide
    await Bed.settle(t, rounds: 2);
    final problem = find.byType(PlaybackProblem);
    expect(find.descendant(of: problem, matching: find.text('No picture')), findsOneWidget);
    expect(find.descendant(of: problem, matching: find.text("This device can't decode this video's picture")), findsOneWidget);
    await Bed.closePlayer(t);
  }, variant: phone);

  test('only the lines mpv gives a half up on count, word for word', () {
    String? part(String text, {String prefix = 'cplayer', bool error = true}) => PlaybackFailure.droppedPart(error: error, prefix: prefix, text: text);
    expect(part('Could not open/initialize audio device -> no sound.'), 'audio');
    expect(part('Audio filter initialized failed!'), 'audio');
    expect(part('Could not initialize video chain.'), 'video');
    expect(part('Error opening/initializing the selected video_out (--vo) device.'), 'video');
    expect(part("Failed to initialize a decoder for codec 'hevc'.", prefix: 'vd'), 'video');
    expect(part("Failed to initialize a decoder for codec 'eac3'.", prefix: 'ad'), 'audio');
    expect(part("Failed to initialize a decoder for codec 'truehd'.", prefix: ''), 'audio', reason: 'by the codec, where the log does not say which chain');
    expect(part('Cannot convert decoder/filter output to any format supported by the output.', prefix: 'af'), 'audio');
    expect(part('Cannot convert decoder/filter output to any format supported by the output.', prefix: 'vf'), isNull, reason: 'mpv tries software decoding next');
    expect(part('Could not open codec.', prefix: 'vd'), isNull, reason: 'one decoder of several: the next is tried');
    expect(part('Could not initialize video chain.', error: false), isNull);
    expect(part('http: HTTP error 404 Not Found', prefix: 'ffmpeg'), isNull);
  });

  test('a phone does not start with Passthrough on: its speakers take plain sound', () {
    expect(AppSettings.passthroughStartsOn, isFalse);
  });
}
