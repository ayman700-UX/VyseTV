// The LG webOS player's Dart side (lib/mpv/player/platform/player_webos.dart), with this test
// playing the TV: it answers the player's calls and sends the events the TV's media player
// sends, in the JSON LG's own Flutter video plugin reads them from.
//
// What this proves is the logic on this side of the channel. It says nothing about a TV.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/webos.dart';
import 'package:vyse_tv/mpv/models.dart';
import 'package:vyse_tv/mpv/player/platform/player_webos.dart';
import 'package:vyse_tv/mpv/player/player.dart';
import 'package:vyse_tv/mpv/support/header_relay.dart';

const _methods = StandardMethodCodec();

/// The TV's side: what the player asked of it, and its answers.
class _Tv {
  final calls = <String>[]; // "0 load", "windows create", …
  final loads = <Map<Object?, Object?>>[];
  final resizes = <Map<Object?, Object?>>[];
  var windows = 0;
  int? position;

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.allMessagesHandler = (channel, handler, message) {
      if (handler != null) return handler(message);
      if (channel.startsWith('flutter/')) return messenger.delegate.send(channel, message);
      if (message == null) return Future.value(null);
      final call = _methods.decodeMethodCall(message);
      final args = call.arguments is Map ? call.arguments as Map<Object?, Object?> : const <Object?, Object?>{};
      if (channel == 'webos/exported_windows') {
        calls.add('windows ${call.method}');
        if (call.method == 'create') return Future.value(_methods.encodeSuccessEnvelope('window-${++windows}'));
        if (call.method == 'resize') resizes.add(args);
        return Future.value(_methods.encodeSuccessEnvelope(null));
      }
      final slot = RegExp(r'^vyse/webos_media/(\d)(/events)?$').firstMatch(channel);
      if (slot != null) {
        if (slot[2] != null) return Future.value(_methods.encodeSuccessEnvelope(null)); // listen / cancel
        calls.add('${slot[1]} ${call.method}');
        if (call.method == 'initialize') return Future.value(_methods.encodeSuccessEnvelope(true));
        if (call.method == 'load') loads.add(args);
        if (call.method == 'position') return Future.value(_methods.encodeSuccessEnvelope(position));
        return Future.value(_methods.encodeSuccessEnvelope(null));
      }
      return Future.value(_methods.encodeSuccessEnvelope(null));
    };
  }

  /// An event of the TV's player, sent the way the native side sends it.
  Future<void> says(WidgetTester t, Object event, {int slot = 0}) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'vyse/webos_media/$slot/events',
      _methods.encodeSuccessEnvelope(<String, Object?>{
        'type': 'event',
        'name': 'media',
        'data': <String, Object?>{'json': event is String ? event : jsonEncode(event)},
      }),
      (_) {},
    );
    await t.pump();
  }

  Future<void> appIs(WidgetTester t, String state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'vyse/webos_media/0/events',
      _methods.encodeSuccessEnvelope(<String, Object?>{
        'type': 'event',
        'name': 'app',
        'data': <String, Object?>{'state': state},
      }),
      (_) {},
    );
    await t.pump();
  }

  Map<String, Object?> get lastPayload => (jsonDecode(loads.last['payload']! as String) as Map).cast<String, Object?>();
}

const _film = {
  'sourceInfo': {
    'container': 'matroska',
    'seekable': true,
    'programInfo': [
      {
        'duration': 5400000,
        'numVideoTracks': 1,
        'numAudioTracks': 2,
        'audioTrackInfo': [
          {'language': 'eng', 'codec': 'eac3', 'channels': 6, 'sampleRate': 48000, 'trackId': 1},
          {'language': 'fra', 'codec': 'ac3', 'channels': 2, 'trackId': 2},
        ],
        'numSubtitleTracks': 1,
        'subtitleTrackInfo': [
          {'language': 'eng', 'type': 'srt', 'trackId': 3},
        ],
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Tv tv;

  setUp(() {
    tv = _Tv()..install();
    WebOS.debugIs = true;
  });

  tearDown(() {
    WebOS.debugIs = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.allMessagesHandler = null;
  });

  // Players a test made. They are closed inside the test, pass or fail: a player left open
  // keeps its channel, and the next test's player would wait for it.
  final made = <Player>[];
  T keep<T extends Player>(T player) {
    made.add(player);
    return player;
  }

  void tvTest(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
    try {
      await body(t);
    } finally {
      for (final p in made) {
        await t.runAsync(p.dispose);
      }
      made.clear();
    }
  });

  Future<PlayerWebos> opened(WidgetTester t, {String uri = 'http://127.0.0.1:8090/stream/film.mkv', Duration? start, bool play = true}) async {
    final player = keep(PlayerWebos());
    await t.runAsync(() => player.open(Media(uri, start: start), play: play));
    await t.pump();
    return player;
  }

  test('on an LG TV the app asks for this player, for video and for music', () async {
    final video = Player();
    final music = Player.audio();
    final party = Player.audio(secondary: true);
    addTearDown(() async {
      await video.dispose();
      await music.dispose();
      await party.dispose();
    });
    expect(video, isA<PlayerWebos>());
    expect(video.playerType, 'webos');
    expect(video.mpvCore, isFalse);
    expect((music as PlayerWebos).slot, 1);
    expect((party as PlayerWebos).slot, 2);
    expect(music.audioOnly, isTrue);
    // three players, three of the TV's slots: the film's is never taken by a song
    expect({(video as PlayerWebos).slot, music.slot, party.slot}, hasLength(3));
  });

  group('what the TV is told when a video opens', () {
    test('a file: whose window, and nothing about its kind', () {
      final p = PlayerWebos.loadPayload('http://127.0.0.1:8090/stream/film.mkv', appId: 'com.vyse.vysetv', windowId: 'window-1');
      expect(p, {
        'option': {'appId': 'com.vyse.vysetv', 'windowId': 'window-1'},
      });
    });

    test('where to start, for a film taken up again', () {
      final p = PlayerWebos.loadPayload('http://h/film.mp4', appId: 'a', windowId: 'w', startMs: 754000);
      expect((p['option']! as Map)['transmission'], {
        'playTime': {'start': 754000},
      });
    });

    test('a playlist is named as one, a live one without a start', () {
      expect(PlayerWebos.loadPayload('http://127.0.0.1:5000/hls/abc.m3u8?from=12.000', appId: 'a')['mediaTransportType'], 'HLS');
      expect(PlayerWebos.loadPayload('http://h/manifest.mpd', appId: 'a')['mediaTransportType'], 'MPEG-DASH');
      expect(PlayerWebos.loadPayload('rtsp://h/cam', appId: 'a')['mediaTransportType'], 'RTSP');
      final live = PlayerWebos.loadPayload('http://h/live.m3u8', appId: 'a', startMs: 9000, live: true);
      expect((live['option']! as Map).containsKey('transmission'), isFalse);
    });
  });

  tvTest('opening: a window for the picture, then the address and where to start', (t) async {
    final player = await opened(t, start: const Duration(minutes: 12));
    expect(tv.calls, containsAllInOrder(['0 initialize', 'windows create', '0 load']));
    expect(tv.loads.single['uri'], 'http://127.0.0.1:8090/stream/film.mkv');
    expect(tv.loads.single['windowId'], 'window-1');
    expect((tv.lastPayload['option']! as Map)['windowId'], 'window-1');
    expect(((tv.lastPayload['option']! as Map)['transmission']! as Map)['playTime'], {'start': 720000});
    // the page shows "loading" until the TV plays, and the resume point at once
    expect(player.state.buffering, isTrue);
    expect(player.state.position, const Duration(minutes: 12));
    expect(tv.calls, isNot(contains('0 play'))); // not before the TV has loaded it
  });

  tvTest('the TV loads, plays, and reports as it goes', (t) async {
    final player = await opened(t);
    final loaded = <void>[], restarts = <void>[];
    player.streams.fileLoaded.listen(loaded.add);
    player.streams.playbackRestart.listen(restarts.add);

    await tv.says(t, {'loadCompleted': {}});
    expect(loaded, hasLength(1));
    expect(tv.calls.last, '0 play');

    // (the TV first sends a sourceInfo with nothing in it)
    await tv.says(t, {
      'sourceInfo': {
        'programInfo': [
          {'duration': 0, 'numVideoTracks': 0, 'numAudioTracks': 0},
        ],
      },
    });
    expect(player.state.duration, Duration.zero);

    await tv.says(t, _film);
    expect(player.state.duration, const Duration(minutes: 90));
    expect(player.state.seekable, isTrue);
    expect(player.state.tracks.audio.map((a) => '${a.id} ${a.language} ${a.codec} ${a.channels}'), ['1 eng eac3 6', '2 fra ac3 2']);
    expect(player.state.track.audio?.id, '1');
    expect(player.state.tracks.subtitle.map((s) => '${s.id} ${s.language} ${s.isExternal}'), ['tv:0 eng false']);

    await tv.says(t, {
      'videoInfo': {'width': 3840, 'height': 2160, 'frameRate': 23.976, 'hdrType': 'dolbyVision'},
    });
    expect(player.currentVideoSize, (3840, 2160));
    expect(await player.getProperty('container-fps'), '23.976');
    expect((await player.getStats())['hdrType'], 'dolbyVision');

    await tv.says(t, {'playing': {}});
    expect(player.state.playing, isTrue);
    expect(player.state.buffering, isFalse);
    expect(restarts, hasLength(1));
    expect(player.state.hasRenderedFrame, isTrue);

    await tv.says(t, {'currentTime': 61500});
    expect(player.currentPosition, const Duration(milliseconds: 61500));
    await tv.says(t, {
      'currentTime': {'currentTime': 62000},
    });
    expect(player.currentPosition, const Duration(seconds: 62));

    // (how far ahead it has fetched, in seconds; the player takes such a report four times a
    // second at most, by the real clock)
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tv.says(t, {
      'bufferRange': {'beginTime': 0, 'endTime': 120, 'remainingTime': 58, 'percent': 3},
    });
    expect(player.state.buffer, const Duration(seconds: 120));

    await tv.says(t, {'bufferingStart': {}});
    expect(player.state.buffering, isTrue);
    await tv.says(t, {'bufferingEnd': {}});
    expect(player.state.buffering, isFalse);

    await tv.says(t, {'paused': {}});
    expect(player.state.playing, isFalse);
  });

  tvTest('opened paused, it stays paused once loaded', (t) async {
    final player = await opened(t, play: false);
    await tv.says(t, {'loadCompleted': {}});
    expect(tv.calls, isNot(contains('0 play')));
    expect(player.state.playing, isFalse);
    expect(player.state.buffering, isFalse);
    await t.runAsync(player.play);
    expect(tv.calls.last, '0 play');
  });

  tvTest('seeking, the rate, and the end', (t) async {
    final player = await opened(t);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, _film);
    await tv.says(t, {'playing': {}});

    await t.runAsync(() => player.seek(const Duration(minutes: 30)));
    expect(tv.calls.last, '0 seek');
    expect(player.state.position, const Duration(minutes: 30));

    await t.runAsync(() => player.setRate(1.5));
    expect(tv.calls.last, '0 setRate');
    expect(player.state.rate, 1.5);

    final done = <bool>[];
    player.streams.completed.listen(done.add);
    await tv.says(t, {'endOfStream': {}});
    expect(done, [true]);
    expect(player.state.playing, isFalse);

    // Play at the end starts it over
    tv.calls.clear();
    await t.runAsync(player.play);
    expect(tv.calls, ['0 seek', '0 play']);
    expect(player.state.completed, isFalse);
  });

  tvTest('the remote owns the volume: nothing is asked of the TV', (t) async {
    final player = await opened(t);
    tv.calls.clear();
    await player.setVolume(40);
    expect(player.state.volume, 40);
    expect(tv.calls, isEmpty);
  });

  tvTest('picking sound and a subtitle track of the video', (t) async {
    final player = await opened(t);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, _film);
    tv.calls.clear();

    await t.runAsync(() => player.selectAudioTrack(player.state.tracks.audio[1]));
    expect(tv.calls, ['0 selectTrack']);
    expect(player.state.track.audio?.language, 'fra');
    // the TV saying so again changes nothing
    await tv.says(t, {
      'trackSelected': {'type': 'audio', 'index': 1},
    });
    expect(player.state.track.audio?.id, '2');

    tv.calls.clear();
    await t.runAsync(() => player.selectSubtitleTrack(player.state.tracks.subtitle.single));
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tv.calls, ['0 selectTrack', '0 setSubtitleEnable']);
    expect(player.state.track.subtitle?.id, 'tv:0');

    // if the TV hands the line's text over, it is shown as any other line
    await tv.says(t, {
      'subtitleData': {'subtitleData': 'From inside the file', 'presentationTime': 1000},
    });
    expect(player.currentSubText, 'From inside the file');

    tv.calls.clear();
    await t.runAsync(() => player.selectSubtitleTrack(SubtitleTrack.off));
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tv.calls, ['0 setSubtitleEnable']);
    expect(player.currentSubText, '');
    expect(player.state.track.subtitle?.id, 'no');
  });

  tvTest('a subtitle file: its lines come up in time with the film', (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_webos_sub');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}film.en.srt')
      ..writeAsStringSync('1\n00:00:10,000 --> 00:00:12,000\nFirst\n\n2\n00:00:13,000 --> 00:00:15,000\nSecond\n');

    final player = await opened(t);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, _film);
    await tv.says(t, {'playing': {}});

    final took = await t.runAsync(() => player.addSubtitleFile(Uri.file(file.path).toString(), title: 'English', language: 'en'));
    expect(took, isTrue);
    await t.pump();
    final listed = player.state.tracks.subtitle.last;
    expect(listed.isExternal, isTrue);
    expect(listed.codec, 'subrip');
    expect(player.state.track.subtitle?.id, listed.id);

    final lines = <String>[];
    player.subText.listen(lines.add);

    await tv.says(t, {'currentTime': 9000});
    expect(player.currentSubText, '');
    await tv.says(t, {'currentTime': 10200});
    expect(player.currentSubText, 'First');
    // between two reports of the TV the app's own clock takes the line down on time
    await t.pump(const Duration(milliseconds: 1900));
    expect(player.currentSubText, '');
    await tv.says(t, {'currentTime': 13500});
    expect(player.currentSubText, 'Second');
    expect(lines, ['First', '', 'Second']);
    lines.clear();

    // later by two seconds (the sync panel): at 13.5 s it is the first line's turn again
    // (10 to 12 s in the file, so 12 to 14 s now), and the second comes at 15 s
    await player.setProperty('sub-delay', '2.000');
    expect(player.currentSubText, 'First');
    await tv.says(t, {'currentTime': 14500});
    expect(player.currentSubText, '');
    await tv.says(t, {'currentTime': 15500});
    expect(player.currentSubText, 'Second');

    // hidden and shown again
    await player.setProperty('sub-visibility', 'no');
    expect(player.currentSubText, '');
    await player.setProperty('sub-visibility', 'yes');
    expect(player.currentSubText, 'Second');

    // paused, the clock stands still and so does the line
    await tv.says(t, {'paused': {}});
    await t.pump(const Duration(seconds: 5));
    expect(player.currentSubText, 'Second');
  });

  tvTest('a subtitle file handed over with the video is on from the first frame', (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_webos_sub');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}a.vtt')..writeAsStringSync('WEBVTT\n\n00:00.000 --> 00:05.000\nOpening line\n');
    final player = keep(PlayerWebos());
    await t.runAsync(
      () => player.open(const Media('http://127.0.0.1:1/a.mkv'), externalSubtitles: [SubtitleTrack.uri(Uri.file(file.path).toString(), language: 'en', isDefault: true)]),
    );
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, _film);
    await tv.says(t, {'playing': {}});
    await tv.says(t, {'currentTime': 500});
    expect(player.currentSubText, 'Opening line');
    expect(player.state.track.subtitle?.isExternal, isTrue);
  });

  tvTest('where the picture sits: told once the TV knows its size, in the interface\'s pixels', (t) async {
    final player = await opened(t);
    await player.setVideoRect(left: 0, top: 0, right: 3840, bottom: 2160, devicePixelRatio: 2);
    expect(tv.resizes, isEmpty); // nothing to cut the plane from yet
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, {
      'videoInfo': {'width': 1920, 'height': 800},
    });
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    // a wide film on a 16:9 screen: the plane is the picture's own shape, with the black bars
    // left to the interface (a plane as large as the screen would stretch the film to it)
    expect(tv.resizes.single, {
      'windowId': 'window-1',
      'srcRect': [0, 0, 1920, 800],
      'dstRect': [0, 140, 1920, 800],
    });
    // a tile in a watch party's room
    await player.setVideoRect(left: 100, top: 50, right: 740, bottom: 410, devicePixelRatio: 1);
    expect(tv.resizes.last['dstRect'], [100, 96, 640, 267]);
  });

  test('the picture in its box: whole, cropped to cover, pulled to it, zoomed, forced to a shape', () {
    // a 2.4:1 film on a 1920 by 1080 screen
    ({List<int> src, List<int> dst}) on({int fit = 0, double zoom = 1, double? forced, int w = 1920, int h = 800, double par = 1}) =>
        PlayerWebos.plane(x: 0, y: 0, w: 1920, h: 1080, videoW: w, videoH: h, fit: fit, zoom: zoom, forcedAspect: forced, pixelAspect: par)!;

    // Fit: all of it, bars above and below
    expect(on().src, [0, 0, 1920, 800]);
    expect(on().dst, [0, 140, 1920, 800]);
    // Fill: the screen covered, the film's sides cut off (the film would be 2592 wide: 1920 of
    // that is 1422 of its own 1920 across)
    expect(on(fit: 1).dst, [0, 0, 1920, 1080]);
    expect(on(fit: 1).src, [248, 0, 1422, 800]);
    // Stretch: all of it, pulled to the screen
    expect(on(fit: 2).src, [0, 0, 1920, 800]);
    expect(on(fit: 2).dst, [0, 0, 1920, 1080]);
    // Zoom in on Fit: wider than the screen, so the sides are cut and the bars get thinner
    final z = on(zoom: 1.25);
    expect(z.dst, [0, 40, 1920, 1000]);
    expect(z.src, [192, 0, 1536, 800]);
    // Zoom out: smaller, in the middle, nothing cut
    expect(on(zoom: .5).dst, [480, 340, 960, 400]);
    expect(on(zoom: .5).src, [0, 0, 1920, 800]);
    // an old show squeezed into a wide frame, shown as 4:3
    expect(on(forced: 4 / 3, w: 1920, h: 1080).dst, [240, 0, 1440, 1080]);
    // pixels that are not square (a DVD's 720 by 576 shown 16:9)
    expect(on(w: 720, h: 576, par: 64 / 45).dst, [0, 0, 1920, 1080]);
    // a 4:3 picture: bars at the sides
    expect(on(w: 1440, h: 1080).dst, [240, 0, 1440, 1080]);
    // nothing to place before the TV has said the picture's size
    expect(PlayerWebos.plane(x: 0, y: 0, w: 1920, h: 1080, videoW: 0, videoH: 0), isNull);
  });

  tvTest('the More menu\'s shape and zoom move the plane; mpv\'s other properties do nothing', (t) async {
    final player = await opened(t);
    await player.setVideoRect(left: 0, top: 0, right: 1920, bottom: 1080, devicePixelRatio: 1);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, {
      'videoInfo': {'width': 1920, 'height': 800},
    });
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    tv.resizes.clear();

    await player.setBoxFitMode(1); // Fill
    expect(tv.resizes.last['srcRect'], [248, 0, 1422, 800]);
    expect(tv.resizes.last['dstRect'], [0, 0, 1920, 1080]);
    await player.setBoxFitMode(0);
    await player.setProperty('video-aspect-override', '16:9');
    expect(tv.resizes.last['dstRect'], [0, 0, 1920, 1080], reason: 'forced to 16:9, it fills a 16:9 screen');
    await player.setProperty('video-aspect-override', 'no');
    expect(tv.resizes.last['dstRect'], [0, 140, 1920, 800]);
    await player.setVideoZoom(1.25);
    expect(tv.resizes.last['dstRect'], [0, 40, 1920, 1000]);

    final before = tv.resizes.length;
    final calls = tv.calls.length;
    await player.setProperty('panscan', '1.0');
    await player.setProperty('sub-ass-force-margins', 'yes');
    await player.setProperty('glsl-shaders', 'x.glsl');
    await player.command(['sub-add', 'x.srt']);
    expect(tv.resizes.length, before);
    expect(tv.calls.length, calls, reason: 'nothing of mpv\'s reaches the TV');
  });

  tvTest('what the report card is told: the picture, its codec, HDR as the TV names it, the sound', (t) async {
    final player = await opened(t);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, {
      'sourceInfo': {
        'container': 'matroska',
        'seekable': true,
        'programInfo': [
          {
            'duration': 5400000,
            'numVideoTracks': 1,
            'videoTrackInfo': [
              {'codec': 'H265', 'width': 3840, 'height': 2160},
            ],
            'numAudioTracks': 1,
            'audioTrackInfo': [
              {'language': 'eng', 'codec': 'eac3', 'channels': 6, 'sampleRate': 48000},
            ],
          },
        ],
      },
    });
    await tv.says(t, {
      'videoInfo': {
        'width': 3840,
        'height': 2160,
        'frameRate': 23.976,
        'hdrType': 'HDR10',
        'VUI': {'transferCharacteristics': 16},
      },
    });
    await tv.says(t, {
      'audioInfo': {'channels': 6, 'sampleRate': 48000, 'immersive': 'atmos'},
    });
    final stats = await player.getStats();
    expect(stats, containsPair('engine', 'webos'));
    expect(stats, containsPair('videoWidth', 3840));
    expect(stats, containsPair('videoCodec', 'H265'));
    expect(stats, containsPair('hdrType', 'HDR10'));
    expect(stats, containsPair('transfer', 16));
    expect(stats, containsPair('videoFps', 23.976));
    expect(stats, containsPair('audioCodec', 'eac3'));
    expect(stats, containsPair('audioImmersive', 'atmos'));
  });

  tvTest('faults: said in words, and a failed seek is not one', (t) async {
    final player = await opened(t);
    final errors = <PlayerError>[];
    player.streams.error.listen(errors.add);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, {
      'error': {'errorCode': 700, 'errorText': 'seek failure'},
    });
    expect(errors, isEmpty);
    await tv.says(t, {
      'error': {'errorCode': 200, 'errorText': 'audio codec not supported'},
    });
    expect(errors.single.message, "The TV can't play this sound (200 audio codec not supported)");
    expect(PlayerWebos.errorNote(201, ''), "The TV can't play this picture (201)");
    expect(PlayerWebos.errorNote(404, 'x'), 'The stream stopped answering (404 x)');
  });

  tvTest('another app took the decoder: opened again where it was once the app is back', (t) async {
    final player = await opened(t);
    await tv.says(t, {'loadCompleted': {}});
    await tv.says(t, _film);
    await tv.says(t, {'playing': {}});
    await tv.says(t, {'currentTime': 600000});
    final errors = <PlayerError>[];
    player.streams.error.listen(errors.add);

    await tv.says(t, {
      'error': {'errorCode': 600, 'errorText': 'resource released'},
    });
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(errors, isEmpty);
    expect(tv.calls.last, '0 unload');
    expect(player.state.playing, isFalse);

    await tv.appIs(t, 'AppLifecycleState.resumed');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(tv.loads, hasLength(2));
    expect(((tv.lastPayload['option']! as Map)['transmission']! as Map)['playTime'], {'start': 600000});
  });

  tvTest('a link with headers of its own is opened through the relay on this device', (t) async {
    addTearDown(HeaderRelay.instance.debugReset);
    final player = keep(PlayerWebos());
    await t.runAsync(() => player.open(const Media('https://cdn.example.com/v/film.mp4?t=1', headers: {'Referer': 'https://site.example/'})));
    final given = tv.loads.single['uri']! as String;
    expect(given, matches(RegExp(r'^http://127\.0\.0\.1:\d+/r/\d+/v/film\.mp4$')));
    // (what is already on this device is left as it is)
    await t.runAsync(() => player.open(const Media('http://127.0.0.1:8090/stream/x.mkv', headers: {'Referer': 'https://site.example/'})));
    expect(tv.loads.last['uri'], 'http://127.0.0.1:8090/stream/x.mkv');
  });

  tvTest('music: no window, and its own slot', (t) async {
    final music = keep(PlayerWebos.audio());
    await t.runAsync(() => music.open(const Media('http://127.0.0.1:9/song.m4a')));
    expect(tv.calls, ['1 initialize', '1 load']);
    expect((tv.lastPayload['option']! as Map).containsKey('windowId'), isFalse);
    await tv.says(t, {'loadCompleted': {}}, slot: 1);
    expect(tv.calls.last, '1 play');
  });

  testWidgets('closing: the player first, then its window', (t) async {
    final player = PlayerWebos();
    await t.runAsync(() => player.open(const Media('http://127.0.0.1:1/a.mkv')));
    tv.calls.clear();
    await t.runAsync(player.dispose);
    expect(tv.calls, ['0 dispose', 'windows dispose']);
  });
}
