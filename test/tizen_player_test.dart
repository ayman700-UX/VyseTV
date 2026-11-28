// The Samsung TV player's Dart side (lib/mpv/player/platform/player_tizen.dart), with this test
// playing the TV: a stand-in for Samsung's plugin answers the player's calls and sends the
// events the TV's player sends, as Samsung's plugin hands them to Dart.
//
// What this proves is the logic on this side of Samsung's plugin. It says nothing about a TV.
import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_avplay/video_player.dart' show AudioTrack, TextTrack, Track, TrackType, VideoTrack;
import 'package:video_player_avplay/video_player_platform_interface.dart';
import 'package:vyse_tv/core/platform/tizen_tv.dart';
import 'package:vyse_tv/data/playback/playback_failure.dart';
import 'package:vyse_tv/mpv/models.dart' as m;
import 'package:vyse_tv/mpv/player/platform/player_tizen.dart';
import 'package:vyse_tv/mpv/player/player.dart';

/// Samsung's plugin, as far as the player uses it: what it was asked, and its answers.
class _Tv extends VideoPlayerPlatform {
  final calls = <String>[];
  final sources = <DataSource>[];
  final events = <int, StreamController<VideoEvent>>{};
  final geometries = <List<int>>[];
  final modes = <DisplayMode>[];
  final speeds = <double>[];
  int _next = 0;
  // Where the TV's film is: [position] when last set, and on from there while it plays (null:
  // the TV says nothing, and the player's own clock is all there is).
  int? position;
  Stopwatch? _running;

  void moveTo(int ms) {
    position = ms;
    _running?.reset();
  }
  bool takesAudioSwitch = true;
  bool crops = true;
  bool refusesSpeed = false;
  int activeAudio = 0;

  final audio = [
    AudioTrack(trackId: 1, mimetype: 'audio/x-eac3', language: 'eng', channel: 6, bitrate: 640000),
    AudioTrack(trackId: 2, mimetype: 'audio/x-ac3', language: 'fra', channel: 2, bitrate: 192000),
  ];
  final text = [
    TextTrack(trackId: 3, mimetype: 'text/x-subrip', language: 'eng'),
    TextTrack(trackId: 4, mimetype: 'text/x-pgs', language: 'fra'),
  ];
  final video = [VideoTrack(trackId: 0, mimetype: 'video/x-h265', width: 3840, height: 2160, bitrate: 20000000)];

  @override
  Future<void> init() async => calls.add('init');

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _next++;
    sources.add(dataSource);
    events[id] = StreamController<VideoEvent>();
    calls.add('create $id');
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose $playerId');
    unawaited(events[playerId]?.close());
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play $playerId');
    (_running ??= clock.stopwatch()).start();
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause $playerId');
    _running?.stop();
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek $playerId ${position.inMilliseconds}');
    if (this.position != null) moveTo(position.inMilliseconds);
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    final at = position;
    if (at == null) throw PlatformException(code: 'position', message: 'not now');
    return Duration(milliseconds: at + (_running?.elapsedMilliseconds ?? 0));
  }

  @override
  Future<List<AudioTrack>> getAudioTracks(int playerId) async => audio;

  @override
  Future<List<TextTrack>> getTextTracks(int playerId) async => text;

  @override
  Future<List<VideoTrack>> getVideoTracks(int playerId) async => video;

  @override
  Future<List<Track>> getActiveTrackInfo(int playerId) async => [video.first, audio[activeAudio]];

  @override
  Future<bool> setTrackSelection(int playerId, Track track) async {
    calls.add('select ${track.trackType.name} ${track.trackId}');
    return track.trackType != TrackType.audio || takesAudioSwitch;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    if (refusesSpeed && speed != 1.0) throw PlatformException(code: 'speed', message: 'refused');
    speeds.add(speed);
    calls.add('speed $playerId $speed');
  }

  @override
  Future<bool> setDisplayMode(int playerId, DisplayMode displayMode) async {
    modes.add(displayMode);
    return displayMode != DisplayMode.croppedFull || crops;
  }

  @override
  Future<void> setDisplayGeometry(int playerId, int x, int y, int width, int height) async => geometries.add([x, y, width, height]);

  @override
  Future<void> suspend(int playerId) async => calls.add('suspend $playerId');

  @override
  Future<void> restore(int playerId, {DataSource? dataSource, int resumeTime = -1}) async => calls.add('restore $playerId');
}

VideoEvent _loaded({Duration length = const Duration(minutes: 90)}) =>
    VideoEvent(eventType: VideoEventType.initialized, duration: DurationRange(Duration.zero, length), size: const Size(3840, 2160));

VideoEvent _playing(bool on) => VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: on);

VideoEvent _line(List<String> rows, int ms) =>
    VideoEvent(eventType: VideoEventType.subtitleUpdate, subtitlesInfo: SubtitlesInfo(ms, [for (final r in rows) {'text': r, 'attributes': const []}], const {}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Tv tv;

  setUp(() {
    tv = _Tv();
    PlayerTizen.debugTv = tv;
    PlayerTizen.debugForgetTv();
    SharedPreferences.setMockInitialValues({});
    PlayerTizen.debugResetPlayers(basicFirst: false);
    TizenTv.debugIs = true;
  });

  tearDown(() {
    PlayerTizen.debugTv = null;
    TizenTv.debugIs = null;
  });

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

  Future<void> say(WidgetTester t, VideoEvent e, {int id = 0}) async {
    tv.events[id]!.add(e);
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
  }

  Future<PlayerTizen> opened(WidgetTester t, {String uri = 'https://cdn.example/film.mkv', Duration? start, bool play = true, Map<String, String>? headers}) async {
    final player = keep(PlayerTizen());
    await player.open(m.Media(uri, start: start, headers: headers), play: play);
    await t.pump();
    return player;
  }

  Future<PlayerTizen> playing(WidgetTester t, {Duration? start}) async {
    final player = await opened(t, start: start);
    await say(t, _loaded());
    await say(t, _playing(true));
    return player;
  }

  test('on a Samsung TV the app asks for this player, for video and for music', () async {
    final video = Player();
    final music = Player.audio();
    final party = Player.audio(secondary: true);
    addTearDown(() async {
      await video.dispose();
      await music.dispose();
      await party.dispose();
    });
    expect(video, isA<PlayerTizen>());
    expect(video.playerType, 'tizen');
    expect(video.mpvCore, isFalse);
    expect((music as PlayerTizen).audioOnly, isTrue);
    expect((party as PlayerTizen).slot, 2);
  });

  group('what the TV is given', () {
    test('a file on the web: as it is, its kind left to the TV', () {
      final s = PlayerTizen.dataSource('https://cdn.example/film.mkv');
      expect(s.sourceType, DataSourceType.network);
      expect(s.formatHint, isNull);
      expect(s.streamingProperty, isNull);
      // (no start option: Samsung's never reaches its player; the start is a seek)
      expect(s.playerOptions, isNull);
    });

    test('a stream says its kind', () {
      expect(PlayerTizen.dataSource('https://h/live/index.m3u8?t=1').formatHint, VideoFormat.hls);
      expect(PlayerTizen.dataSource('https://h/manifest.mpd').formatHint, VideoFormat.dash);
    });

    test('a file on this device goes as one', () {
      expect(PlayerTizen.dataSource('/opt/usr/home/film.mp4').sourceType, DataSourceType.file);
    });

    test('a cookie and a user agent are told to the TV; any other header needs the relay', () {
      expect(PlayerTizen.streamingHeaders({'User-Agent': 'libmpv', 'cookie': 'a=1'}), {
        StreamingPropertyType.userAgent: 'libmpv',
        StreamingPropertyType.cookie: 'a=1',
      });
      expect(PlayerTizen.streamingHeaders({'User-Agent': 'x', 'Referer': 'https://site/'}), isNull);
      final s = PlayerTizen.dataSource('https://h/a.mkv', streaming: {StreamingPropertyType.userAgent: 'libmpv'});
      expect(s.streamingProperty, {StreamingPropertyType.userAgent: 'libmpv'});
    });
  });

  tvTest('a link with a user agent opens directly, with the agent told to the TV', (t) async {
    await opened(t, headers: {'User-Agent': 'libmpv'});
    expect(tv.sources.single.uri, 'https://cdn.example/film.mkv');
    expect(tv.sources.single.streamingProperty, {StreamingPropertyType.userAgent: 'libmpv'});
  });

  tvTest('opening: loads, lists its tracks, starts where asked, then plays', (t) async {
    tv.activeAudio = 1;
    final player = await opened(t, start: const Duration(minutes: 12));
    expect(tv.calls.take(2), ['init', 'create 0']);
    expect(player.state.buffering, isTrue);

    await say(t, _loaded());
    expect(player.state.duration, const Duration(minutes: 90));
    expect(player.state.seekable, isTrue);
    expect(player.state.tracks.audio.map((a) => '${a.id} ${a.language} ${a.codec} ${a.channels}'), ['1 eng eac3 6', '2 fra ac3 2']);
    // (the TV said the French one is on)
    expect(player.state.track.audio?.id, '2');
    expect(player.state.tracks.subtitle.map((s) => '${s.id} ${s.language} ${s.codec}'), ['tv:0 eng subrip', 'tv:1 fra hdmv_pgs_subtitle']);
    expect(player.currentVideoSize, (3840, 2160));
    // the start is a seek before the first play
    expect(tv.calls.where((c) => c.startsWith('seek') || c.startsWith('play')), ['seek 0 720000', 'play 0']);

    await say(t, _playing(true));
    expect(player.state.playing, isTrue);
    expect(player.state.buffering, isFalse);

    // the TV's player says nothing of the position: it is asked twice a second
    tv.moveTo(725000);
    await t.pump(const Duration(milliseconds: 600));
    expect(player.currentPosition.inMilliseconds, inInclusiveRange(725000, 725600));
  });

  tvTest('opened paused: loaded and left paused', (t) async {
    final player = await opened(t, play: false);
    await say(t, _loaded());
    expect(tv.calls, isNot(contains('play 0')));
    expect(player.state.playing, isFalse);
    expect(player.state.buffering, isFalse);
    await t.runAsync(player.play);
    expect(tv.calls.last, 'play 0');
  });

  tvTest('init is said once for the whole app', (t) async {
    await opened(t);
    await opened(t);
    expect(tv.calls.where((c) => c == 'init'), hasLength(1));
  });

  tvTest('a new video closes the one before', (t) async {
    final player = await playing(t);
    await player.open(const m.Media('https://cdn.example/next.mkv'));
    await t.pump();
    expect(tv.calls, containsAllInOrder(['dispose 0', 'create 1']));
    expect(tv.events[0]!.isClosed, isTrue);
  });

  tvTest('audio tracks switch in the TV, and a refused switch changes nothing', (t) async {
    final player = await playing(t);
    expect(player.state.track.audio?.id, '1');
    await player.selectAudioTrack(player.state.tracks.audio[1]);
    await t.pump();
    expect(tv.calls.last, 'select audio 2');
    expect(player.state.track.audio?.id, '2');

    tv.takesAudioSwitch = false;
    await player.selectAudioTrack(player.state.tracks.audio[0]);
    await t.pump();
    expect(player.state.track.audio?.id, '2');
  });

  tvTest("a subtitle track inside the video: switched on in the TV, its lines drawn here", (t) async {
    final player = await playing(t);
    await say(t, _line(['ignored while none is on'], 2000));
    expect(player.currentSubText, '');

    await player.selectSubtitleTrack(player.state.tracks.subtitle.first);
    await t.pump();
    expect(tv.calls.last, 'select text 3');
    expect(player.state.track.subtitle?.id, 'tv:0');

    await say(t, _line([r'<i>Hello</i>', r'{\an8}there\Nfriend'], 2000));
    expect(player.currentSubText, 'Hello\nthere\nfriend');
    // the TV says for how long: taken down by the app's clock
    await t.pump(const Duration(milliseconds: 2100));
    expect(player.currentSubText, '');

    // later by a second (the sync panel): shown a second after the TV hands it over
    await player.setProperty('sub-delay', '1.0');
    await say(t, _line(['Later'], 2000));
    expect(player.currentSubText, '');
    await t.pump(const Duration(milliseconds: 1100));
    expect(player.currentSubText, 'Later');

    // hidden and shown again
    await player.setProperty('sub-visibility', 'no');
    expect(player.currentSubText, '');
    await player.setProperty('sub-visibility', 'yes');
    expect(player.currentSubText, 'Later');

    // off
    await player.selectSubtitleTrack(m.SubtitleTrack.off);
    await t.pump();
    expect(player.currentSubText, '');
    expect(player.state.track.subtitle?.id, 'no');
  });

  tvTest("a Blu-ray's picture subtitles come out as pictures", (t) async {
    final player = await playing(t);
    await player.selectSubtitleTrack(player.state.tracks.subtitle[1]);
    await t.pump();
    expect(tv.calls.last, 'select text 4');
    final png = Uint8List.fromList(List.filled(64, 7));
    await say(
      t,
      VideoEvent(
        eventType: VideoEventType.subtitleUpdate,
        subtitlesInfo: SubtitlesInfo(1500, const [], {'picture': png, 'pictureWidth': 600.0, 'pictureHeight': 80.0}),
      ),
    );
    expect(player.currentSubPicture?.bytes, png);
    expect(player.currentSubPicture?.width, 600);
    expect(player.currentSubText, '');
    await t.pump(const Duration(milliseconds: 1600));
    expect(player.currentSubPicture, isNull);
  });

  tvTest('a subtitle file is read here and its lines given out in time', (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_tizen_sub');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}film.en.srt')
      ..writeAsStringSync('1\n00:00:10,000 --> 00:00:12,000\nFirst\n\n2\n00:00:13,000 --> 00:00:15,000\nSecond\n');
    final player = await playing(t);
    final took = await t.runAsync(() => player.addSubtitleFile(Uri.file(file.path).toString(), title: 'English', language: 'en'));
    expect(took, isTrue);
    await t.pump();
    final listed = player.state.tracks.subtitle.last;
    expect(listed.isExternal, isTrue);
    expect(player.state.track.subtitle?.id, listed.id);

    tv.moveTo(10200);
    await t.pump(const Duration(milliseconds: 600));
    expect(player.currentSubText, 'First');
    // the TV's position moves on as it plays, and the line comes down on time
    await t.pump(const Duration(milliseconds: 1900));
    expect(player.currentSubText, '');
    tv.moveTo(13500);
    await t.pump(const Duration(milliseconds: 600));
    expect(player.currentSubText, 'Second');

    // paused, the clock stands still and so does the line (the TV's position too: the clock
    // follows it)
    await tv.pause(0);
    await say(t, _playing(false));
    await t.pump(const Duration(seconds: 5));
    expect(player.currentSubText, 'Second');
  });

  tvTest('seeking: in the TV, at normal speed, and the film goes on from there', (t) async {
    final player = await playing(t);
    await player.seek(const Duration(minutes: 30));
    await t.pump();
    expect(tv.calls.last, 'seek 0 1800000');
    expect(player.state.position, const Duration(minutes: 30));

    await player.setRate(1.5);
    expect(player.state.rate, 1.5);
    tv.calls.clear();
    await player.seek(const Duration(minutes: 40));
    await t.pump();
    expect(tv.calls, ['speed 0 1.0', 'seek 0 2400000', 'speed 0 1.5']);
  });

  tvTest('a speed the TV refuses leaves the speed as it was', (t) async {
    final player = await playing(t);
    tv.refusesSpeed = true;
    await player.setRate(2.0);
    expect(player.state.rate, 1.0);
  });

  tvTest('played out: stays open at its end, and Play starts it over', (t) async {
    final player = await playing(t);
    await say(t, VideoEvent(eventType: VideoEventType.completed));
    expect(player.state.completed, isTrue);
    expect(player.state.playing, isFalse);
    tv.calls.clear();
    await player.play();
    await t.pump();
    expect(tv.calls, ['seek 0 0', 'play 0']);
    expect(player.state.completed, isFalse);
  });

  tvTest('faults: said in words', (t) async {
    final player = await opened(t);
    final errors = <m.PlayerError>[];
    player.streams.error.listen(errors.add);
    // (before the video was ready, the streaming player gives way to the basic one first)
    tv.events[0]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported file'));
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect(tv.calls, contains('create 1'));
    tv.events[1]!.addError(PlatformException(code: 'MediaPlayer error', message: 'Error: Not supported file'));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(errors.single.message, "The TV can't read this file (Not supported file)");
    expect(PlayerTizen.errorNote('Error: Connection timed out'), "The TV couldn't reach the video (Connection timed out)");
    expect(PlayerTizen.errorNote(''), "The TV couldn't play this");
  });

  test("the TV's GStreamer faults: what happened, and where, without the file and line", () {
    const json = 'Error: {"detail_info":"../subprojects/gstreamer/libs/gst/base/gstbasesrc.c(3248): gst_base_src_loop (): '
        '/GstPlayBin3:playbin/GstURISourceBin:urisourcebin0/GstSoupHTTPSrc:source:\\nstreaming stopped, reason error (-5)","error_code":"x"}';
    expect(PlayerTizen.errorNote(json), "The TV couldn't fetch the video (streaming stopped, reason error (-5), in GstSoupHTTPSrc)");
    const typefind = '{"detail_info":"gstbasesrc.c(3248): gst_base_src_loop (): /GstPlayBin3:playbin/GstHLSDemux:hlsdemux0: '
        'streaming stopped, reason not-negotiated (-4)"}';
    expect(PlayerTizen.errorNote(typefind), "The TV can't read this stream (streaming stopped, reason not-negotiated (-4), in GstHLSDemux)");
    // (cut short, as it can reach the app)
    expect(PlayerTizen.gstreamerLine('{"detail_info":"x.c(1): f (): /GstFoo:foo:\\nstreaming stopped, reason not-linked (-1)'),
        'streaming stopped, reason not-linked (-1), in GstFoo');
    expect(PlayerTizen.gstreamerLine('Not supported media format'), isNull);
    expect(PlayerTizen.errorNote('Error: Not supported media format'), "The TV can't read this stream (Not supported media format)");
  });

  test('what the TV plays on without', () {
    expect(PlayerTizen.partGone('Error: Not supported audio codec but video can be played'), 'audio');
    expect(PlayerTizen.partGone('Error: Not supported video codec but audio can be played'), 'video');
    expect(PlayerTizen.partGone('Error: Not supported subtitle format'), 'subtitle');
    expect(PlayerTizen.partGone('Error: Not supported media format'), isNull);
  });

  tvTest('a fault the TV plays on after (a seek it could not make) does not end the film', (t) async {
    tv.position = 0;
    final player = await playing(t);
    final errors = <m.PlayerError>[];
    final logs = <m.PlayerLog>[];
    player.streams.error.listen(errors.add);
    player.streams.log.listen(logs.add);
    await t.pump(const Duration(seconds: 2));
    tv.events[0]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported media format'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(errors, isEmpty, reason: 'the TV went on playing: nothing to end');
    expect(logs.map((l) => l.text), contains(contains('it played on')));
    expect(player.state.playing, isTrue);
  });

  tvTest('a fault the TV really stopped at, before the film ever played, ends it', (t) async {
    final player = await opened(t);
    await say(t, _loaded());
    final errors = <m.PlayerError>[];
    player.streams.error.listen(errors.add);
    tv.events[0]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Streaming connection failed'));
    for (var i = 0; i < 9; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(errors.single.message, startsWith("The TV couldn't reach the video"));
    expect(tv.calls.where((c) => c.startsWith('create')), ['create 0'], reason: 'nothing to open again where it was');
  });

  // (Moonfin's player does the same: a fault after the film has played is a hiccup of the
  // stream or of the TV's pipeline far more often than a film that can't be played)
  tvTest('a fault the TV stopped at after the film played: opened again where it was, with its subtitles and sound; the third time ends it', (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_tizen_again');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}film.en.srt')..writeAsStringSync('1\n00:00:01,000 --> 01:00:00,000\nA line\n');
    tv.position = 0;
    final player = await playing(t);
    await t.runAsync(() => player.addSubtitleFile(Uri.file(file.path).toString(), title: 'English', language: 'en'));
    await player.selectAudioTrack(player.state.tracks.audio[1]);
    expect(player.state.track.audio?.id, '2');
    final errors = <m.PlayerError>[];
    final logs = <m.PlayerLog>[];
    player.streams.error.listen(errors.add);
    player.streams.log.listen(logs.add);
    await t.pump(const Duration(seconds: 3));
    for (var round = 1; round <= 2; round++) {
      tv.position = null; // (it says no position: neither playing nor paused)
      tv.events[round - 1]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported media format'));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(errors, isEmpty, reason: 'round $round: opened again, not ended');
      expect(tv.calls, contains('create $round'));
      expect(logs.map((l) => l.text), contains(contains('opened again where it was')));
      tv.position = 3000;
      tv.activeAudio = 0;
      await say(t, _loaded(), id: round);
      expect(tv.calls.where((c) => c.startsWith('seek $round ')), isNotEmpty, reason: 'round $round: back where it was');
      await say(t, _playing(true), id: round);
      expect(tv.calls, contains('select audio 2'), reason: 'round $round: the sound track it had');
      expect(player.state.track.audio?.id, '2');
      expect(player.state.track.subtitle?.id, 'file:0', reason: 'round $round: the subtitle file it had');
      expect(player.currentSubText, 'A line');
      tv.calls.remove('select audio 2');
      await t.pump(const Duration(seconds: 2));
    }
    tv.position = null;
    tv.events[2]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported media format'));
    for (var i = 0; i < 9; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(errors.single.message, startsWith("The TV can't read this stream"), reason: 'the third time: the link is taken to be gone');
    expect(tv.calls, isNot(contains('create 3')));
  });

  test('a sound track instead of one the TV cannot play: the same language, never DTS or TrueHD', () {
    AudioTrack a(int id, String mime, String lang) => AudioTrack(trackId: id, mimetype: mime, language: lang, channel: 6, bitrate: 0);
    final tracks = [a(1, 'audio/x-dts', 'eng'), a(2, 'audio/x-true-hd', 'eng'), a(3, 'audio/x-ac3', 'fre'), a(4, 'audio/x-eac3', 'en')];
    expect(PlayerTizen.soundInstead(tracks, 1), 3, reason: "'en' is 'eng'; French is not put on in its place");
    expect(PlayerTizen.soundInstead([a(1, 'audio/x-dts', 'eng'), a(2, 'audio/x-ac3', 'fra')], 1), isNull);
    expect(PlayerTizen.soundInstead([a(1, 'audio/x-dts', 'und'), a(2, 'audio/x-ac3', 'fra')], 1), 1, reason: 'no language said: any it plays');
    // (a track the TV does not list, its language unknown: the first it lists that it plays)
    expect(PlayerTizen.soundInstead([a(2, 'audio/x-dts', 'eng'), a(3, 'audio/x-aac', 'eng')], 9), 1);
  });

  tvTest("a sound the TV cannot play: another track in the same language is put on once it plays", (t) async {
    tv.audio
      ..clear()
      ..addAll([
        AudioTrack(trackId: 1, mimetype: 'audio/x-dts', language: 'eng', channel: 6, bitrate: 1509000),
        AudioTrack(trackId: 2, mimetype: 'audio/x-ac3', language: 'eng', channel: 6, bitrate: 640000),
      ]);
    tv.position = 0;
    final player = await opened(t);
    final logs = <m.PlayerLog>[];
    player.streams.log.listen(logs.add);
    // (said while it prepares: the switch waits until it plays)
    tv.events[0]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported audio codec but video can be played'));
    await t.pump();
    await say(t, _loaded());
    expect(tv.calls, isNot(contains('select audio 2')));
    await say(t, _playing(true));
    expect(tv.calls, contains('select audio 2'));
    expect(player.state.track.audio?.id, '2');
    expect(logs.where((l) => l.prefix == 'tv-part'), isEmpty, reason: 'it has sound: nothing to say on the page');
    expect(logs.map((l) => l.text), contains(contains('playing the eng AC3 track instead')));
  });

  tvTest('a sound the TV cannot play: the film goes on and the page is told which half is gone', (t) async {
    tv.position = 0;
    final player = await playing(t);
    final errors = <m.PlayerError>[];
    final logs = <m.PlayerLog>[];
    player.streams.error.listen(errors.add);
    player.streams.log.listen(logs.add);
    tv.events[0]!.addError(PlatformException(code: 'PlusPlayer error', message: 'Error: Not supported audio codec but video can be played'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(errors, isEmpty);
    final said = logs.firstWhere((l) => l.prefix == 'tv-part');
    expect(PlaybackFailure.droppedPart(error: true, prefix: said.prefix, text: said.text), 'audio');
  });

  tvTest("after a seek the subtitles follow the TV's own position, whatever its events left out", (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_tizen_seek');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}film.en.srt')
      ..writeAsStringSync('1\n00:29:57,000 --> 00:29:59,500\nJust before\n\n2\n00:30:00,000 --> 00:30:03,000\nAsked for\n');
    tv.position = 0;
    final player = await playing(t);
    await t.runAsync(() => player.addSubtitleFile(Uri.file(file.path).toString(), title: 'English', language: 'en'));
    await t.pump(const Duration(seconds: 2));
    await player.seek(const Duration(minutes: 30));
    await t.pump();
    // the TV says it is loading and never that it is done, and it landed a few seconds early
    // (on a key frame)
    await say(t, VideoEvent(eventType: VideoEventType.bufferingStart));
    tv.moveTo(30 * 60000 - 4000);
    await t.pump(const Duration(milliseconds: 2500));
    expect(player.currentSubText, 'Just before', reason: "the line for where the TV is, not where it was asked to go");
    expect(player.state.buffering, isFalse, reason: 'it moves, so nothing is loading');
  });

  group('where the picture goes', () {
    const screen = (x: 0, y: 0, w: 1920, h: 1080);

    test('a film wider than the screen: bars above and below', () {
      final p = PlayerTizen.pictureRect(box: screen, videoW: 1920, videoH: 800);
      expect((p.x, p.y, p.w, p.h, p.crop), (0, 140, 1920, 800, false));
    });

    test('a 4:3 picture: bars at the sides', () {
      final p = PlayerTizen.pictureRect(box: screen, videoW: 1440, videoH: 1080);
      expect((p.x, p.y, p.w, p.h), (240, 0, 1440, 1080));
    });

    test('shown as 4:3 whatever the file says', () {
      final p = PlayerTizen.pictureRect(box: screen, videoW: 3840, videoH: 2160, forcedAspect: 4 / 3);
      expect((p.x, p.w), (240, 1440));
    });

    test('pulled to the screen, and made smaller', () {
      expect(PlayerTizen.pictureRect(box: screen, videoW: 1920, videoH: 800, fit: 2).h, 1080);
      final small = PlayerTizen.pictureRect(box: screen, videoW: 1920, videoH: 1080, zoom: .5);
      expect((small.x, small.y, small.w, small.h), (480, 270, 960, 540));
    });

    test('cropped to cover: the TV crops on the whole screen, a smaller box shows it whole', () {
      expect(PlayerTizen.pictureRect(box: screen, videoW: 1920, videoH: 800, fit: 1).crop, isTrue);
      const tile = (x: 100, y: 100, w: 640, h: 360);
      final p = PlayerTizen.pictureRect(box: tile, videoW: 1920, videoH: 800, fit: 1, wholeScreen: false);
      expect((p.w, p.h, p.crop), (640, 267, false));
    });

    test('before its size is known: the box', () {
      final p = PlayerTizen.pictureRect(box: screen, videoW: 0, videoH: 0);
      expect((p.w, p.h), (1920, 1080));
    });
  });

  tvTest('the TV is told where the picture goes, in the screen pixels, and how', (t) async {
    final player = await playing(t);
    final size = t.view.physicalSize;
    await player.setVideoRect(left: 0, top: 0, right: size.width.round(), bottom: size.height.round(), devicePixelRatio: t.view.devicePixelRatio);
    final h = (size.width * 2160 / 3840).round();
    expect(tv.geometries.last, [0, (size.height.round() - h) ~/ 2, size.width.round(), h]);
    expect(tv.modes, isEmpty, reason: "Samsung's player starts in the mode that takes a rectangle");

    await player.setBoxFitMode(1);
    expect(tv.modes.last, DisplayMode.croppedFull);
    expect(tv.geometries.last, [0, 0, size.width.round(), size.height.round()]);

    await player.setBoxFitMode(0);
    expect(tv.modes.last, DisplayMode.dstRoi);
    expect(tv.geometries.last[3], h);

    // a TV that will not crop: the whole picture
    tv.crops = false;
    await player.setBoxFitMode(1);
    expect(tv.modes.last, DisplayMode.croppedFull);
    expect(tv.geometries.last[3], h);
  });

  tvTest('the app going to the background puts the player away, and back brings it back', (t) async {
    await playing(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(tv.calls.last, 'suspend 0');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(tv.calls.reversed.take(2).toList().reversed, ['restore 0', 'play 0']);
  });

  tvTest('stats for the Stream info panel', (t) async {
    final player = await playing(t);
    final s = await player.getStats();
    expect(s['engine'], 'tizen');
    expect(s['videoCodec'], 'hevc');
    expect(s['videoWidth'], 3840);
    expect(s['audioCodec'], 'eac3');
    expect(s['audioChannels'], 6);
  });

  test("a line's markup is taken out", () {
    expect(PlayerTizen.tvSubtitleText([
      {'text': r'{\an8}<b>One</b>'},
      {'text': 'Two &amp; three'},
    ]), 'One\nTwo & three');
    expect(PlayerTizen.codecOf('audio/mpeg'), 'mpeg');
    expect(PlayerTizen.codecOf('video/x-h264'), 'h264');
  });

  group("the TV's two players", () {
    bool basic(DataSource d) => d.playerOptions?['vyseBasicPlayer'] == true;

    tvTest("a video the streaming player never says is ready opens again on the basic player, where it was", (t) async {
      final player = await opened(t, start: const Duration(minutes: 7));
      final logs = <m.PlayerLog>[];
      player.streams.log.listen(logs.add);
      expect(basic(tv.sources.single), isFalse);
      await t.pump(PlayerTizen.readyWait - const Duration(seconds: 1));
      expect(tv.sources, hasLength(1), reason: 'not before its time');
      await t.pump(const Duration(seconds: 2));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      expect(tv.calls, containsAllInOrder(['dispose 0', 'create 1']));
      expect(basic(tv.sources[1]), isTrue);
      expect(logs.where((l) => l.prefix == 'tv-basic').single.text, "The TV's streaming player didn't start it in 20 s");
      await say(t, _loaded(), id: 1);
      expect(tv.calls, containsAllInOrder(['seek 1 420000', 'play 1']), reason: 'where it was to start');
      expect(player.onBasicPlayer, isTrue);
    });

    tvTest('a streaming player that says it cannot prepare gives way at once', (t) async {
      await opened(t);
      tv.events[0]!.addError(PlatformException(code: 'PrepareFailed', message: "The TV's player could not prepare the video."));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      expect(basic(tv.sources.last), isTrue);
      await say(t, _loaded(), id: 1);
      expect(tv.calls, contains('play 1'));
    });

    tvTest('neither player starting it ends it, with the reason', (t) async {
      final player = await opened(t);
      final errors = <m.PlayerError>[];
      player.streams.error.listen(errors.add);
      await t.pump(PlayerTizen.readyWait + const Duration(seconds: 1));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      expect(basic(tv.sources.last), isTrue);
      await t.pump(const Duration(seconds: 61));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(errors.single.message, "The TV's player didn't start this video (neither of its two players did)");
    });

    tvTest('a torrent on this device gets longer before the basic player is tried', (t) async {
      await opened(t, uri: 'http://127.0.0.1:8090/stream/film.mkv');
      await t.pump(const Duration(seconds: 30));
      expect(tv.sources, hasLength(1));
      await t.pump(const Duration(seconds: 16));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      expect(basic(tv.sources.last), isTrue);
    });

    tvTest('two videos in a row saved by the basic player: this TV starts on it from then on', (t) async {
      for (var n = 0; n < 2; n++) {
        await opened(t);
        final id = tv.sources.length - 1;
        await t.pump(PlayerTizen.readyWait + const Duration(seconds: 1));
        for (var i = 0; i < 6; i++) {
          await t.pump();
        }
        await say(t, _loaded(), id: id + 1);
      }
      await opened(t);
      expect(basic(tv.sources.last), isTrue, reason: 'the third video goes straight to the basic player');
    });

    tvTest('a video the streaming player plays starts the count again', (t) async {
      await opened(t);
      await t.pump(PlayerTizen.readyWait + const Duration(seconds: 1));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      await say(t, _loaded(), id: 1);
      await opened(t);
      await say(t, _loaded(), id: 2);
      await opened(t);
      await t.pump(PlayerTizen.readyWait + const Duration(seconds: 1));
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      await say(t, _loaded(), id: 4);
      await opened(t);
      expect(basic(tv.sources.last), isFalse, reason: 'one rescue since the streaming player last played');
    });

    test('a file on this device never asks for the basic player (it is the only one there)', () {
      expect(PlayerTizen.dataSource('/opt/usr/home/film.mkv', basic: true).playerOptions, isNull);
      expect(PlayerTizen.dataSource('https://cdn.example/film.mkv', basic: true).playerOptions, {'vyseBasicPlayer': true});
      expect(PlayerTizen.dataSource('https://cdn.example/film.mkv').playerOptions, isNull);
    });
  });
}
