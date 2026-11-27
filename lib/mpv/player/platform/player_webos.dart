// VyseTV addition (not in upstream).
//
// The player on an LG webOS TV: the TV's own media player.
//
// An LG TV plays video through one system service (the same one behind its USB player and a web
// app's <video>). An app hands it an address; the TV fetches, reads the container, decodes in
// hardware and shows the picture on its video plane, under the app's surface. That is where the
// TV's whole picture chain is: 4K, HDR10, HLG, Dolby Vision, and Dolby Digital / Atmos handed to
// a receiver as the TV's sound settings say. LG's own Flutter video plugin plays this way, and
// this engine does what that plugin does, through VyseTV's own small native side
// (packages/vyse_webos: it passes calls on to LG's NDL media library and hands back the
// player's events as they come, as text; everything that decides anything is here, in Dart,
// where it can be tested).
//
// What that means for the rest of the app:
//  * No mpv. mpv's properties and commands mean nothing here ([mpvCore] is false); what both
//    engines understand goes through the [Player] interface.
//  * The picture is a hole in the interface over the TV's video plane. The hole is the app's
//    (VyseVideo); where the plane sits is told to the compositor as an "exported window"
//    ([setVideoRect]), by a channel LG's Flutter embedder provides.
//  * Headers. The TV fetches the video itself and cannot be given a link's HTTP headers, so a
//    link that has some is opened through a relay on this device (support/header_relay.dart).
//  * Subtitles. A subtitle file is read here (support/subtitle_cues.dart) and its lines are
//    given out as `sub-text` in time with the film; the player page draws them. A subtitle track
//    inside the video file is switched on in the TV's player.
//  * No volume of its own: the remote's volume is the TV's.
//
// Older webOS. LG's Flutter is for webOS 26; the same build is also packaged for older sets
// (webos/README.md, "Older webOS"). Their media player is the same one with less to it, so the
// native side says what this TV has ([_tvHas]) and the player goes the older way where it has
// to: on a set that cannot put a window of its video plane under an app (webOS 4), no window
// is asked for and the picture is placed by the media library itself.
//
// See webos/README.md for what is proven and what is not.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../../support/app_logger.dart';
import '../../support/header_relay.dart';
import '../../support/subtitle_cues.dart';
import '../player_base.dart';
import '../video_rect_support.dart';

/// What the TV's player said it is showing, for the Stream info panel and the report card.
@immutable
class WebosNowPlaying {
  const WebosNowPlaying({this.video = const {}, this.audio = const {}, this.source = const {}});

  /// The `videoInfo` event: width, height, frameRate, hdrType, and for HDR its mastering data.
  final Map<String, Object?> video;

  /// The `audioInfo` event: sampleRate, channels, immersive.
  final Map<String, Object?> audio;

  /// The `sourceInfo` event: container, tracks, duration.
  final Map<String, Object?> source;
}

class PlayerWebos extends PlayerBase with VideoRectSupport {
  /// The video player (the TV's first player slot).
  PlayerWebos() : this._(slot: 0, audioOnly: false);

  /// A sound-only player, for music and audiobooks. Its own slot, so it never takes the
  /// video's; [secondary] is the second one (a watch party's music beside the app's own).
  PlayerWebos.audio({bool secondary = false}) : this._(slot: secondary ? 2 : 1, audioOnly: true);

  PlayerWebos._({required this.slot, required this.audioOnly})
    : methodChannel = MethodChannel('vyse/webos_media/$slot'),
      eventChannel = EventChannel('vyse/webos_media/$slot/events');

  /// Which of the TV's player slots this is (the native side keeps one player per slot).
  final int slot;
  final bool audioOnly;

  @override
  final MethodChannel methodChannel;

  @override
  final EventChannel eventChannel;

  /// LG's embedder: makes, places and removes the window the TV's video plane shows in.
  static const _windows = MethodChannel('webos/exported_windows');

  @override
  String get logPrefix => 'webOS';

  @override
  String get playerType => 'webos';

  @override
  bool get mpvCore => false;

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  bool get providesNativeStats => true;

  // (the TV reports the picture's size and rate once it is decoding, not from the container)
  @override
  bool get detectsFpsAfterRender => true;

  // The native side ignores a dispose that is not from the player it has now.
  @override
  bool get nativeDisposeIsStaleGuarded => true;

  // ── what is open ──

  Future<void>? _initFuture;
  String? _windowId;
  Future<String?>? _windowFuture;
  int _sources = 0; // the id of the newest load; events of an older one are not for us
  bool _loaded = false; // the TV said loadCompleted for the current load
  bool _wantPlay = true; // play or pause, as last asked (applied once loaded)
  bool _started = false; // the first "playing" of this load was seen
  bool _ended = false;
  bool _lost = false; // the TV took its decoder back (another app); reopened on return
  bool _taken = false; // on a TV with one player, another of the app's players has it now
  Media? _media;
  bool _live = false;
  int _durationMs = 0;
  int _videoW = 0, _videoH = 0;
  double _rate = 1.0;
  WebosNowPlaying _now = const WebosNowPlaying();

  /// What the TV's player last said about the stream it is showing.
  WebosNowPlaying get nowPlaying => _now;

  // the rectangle last asked for, in the interface's own pixels
  ({int x, int y, int w, int h})? _rect;

  // ── tracks ──

  var _audio = <_TvTrack>[];
  var _text = <_TvTrack>[];
  final _files = <_SubFile>[]; // subtitle files, read here
  int _audioIndex = 0;
  String _subId = 'no'; // 'no', 'tv:<index>' or 'file:<n>'

  // ── subtitle lines (from a file) and their clock ──

  SubtitleCues _cues = SubtitleCues.empty;
  double _subDelay = 0; // seconds, as mpv's sub-delay: positive shows lines later
  bool _subVisible = true;
  int _clockMs = 0; // the film's time at [_clock] zero, in the source's own time
  // (the clock package's, not dart:core's: a test's made-up time moves it too)
  final _clock = clock.stopwatch();
  Timer? _subTimer;
  Timer? _positionPoll;
  int _lastTickAt = 0;

  // ── start-up ──

  Future<void> _ensureInitialized() async {
    if (initialized) return;
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final ok = await invoke<bool>('initialize', {'instanceId': nativeInstanceId, 'audioOnly': audioOnly});
      if (disposed) throw StateError('Player was disposed during initialization');
      if (ok != true) throw const PlayerInitializationException();
      initialized = true;
    } catch (e) {
      _initFuture = null;
      if (!disposed) errorController.add(PlayerError(e.toString(), cause: PlayerError.playerInitFailed));
      rethrow;
    }
  }

  // ── what this TV has ──

  static Future<Map<String, bool>>? _tv;

  /// What the TV's media library and compositor have, by the native side's names for it
  /// (`exportedWindows`, `displayWindow`, `players`, `muteDisplay`, `initWithWindowId`). Asked
  /// once. A webOS 26 set has all of it; anything not said counts as there, so a native side
  /// that does not know the question changes nothing.
  Future<bool> _tvHas(String what) async {
    final has = await (_tv ??= () async {
      try {
        final said = await invoke<Map<Object?, Object?>>('capabilities');
        return <String, bool>{
          for (final e in (said ?? const <Object?, Object?>{}).entries)
            if (e.key is String && e.value is bool) e.key! as String: e.value! as bool,
        };
      } catch (_) {
        return const <String, bool>{};
      }
    }());
    return has[what] ?? true;
  }

  /// Tests: the next player asks its TV again.
  @visibleForTesting
  static void debugForgetTv() => _tv = null;

  // True once it is known that this TV cannot put a window under the app: the picture is then
  // placed by the media library ([_placeWindow]).
  bool _noWindows = false;

  /// Before webOS 26 the media library is started once and keeps the window it was started
  /// with for good (it learns it through VyseTV's stand-in for SDL, see the native side): a
  /// window made for a later video would never be used, and one taken away under it leaves the
  /// next video with nowhere to go (an open project on such a set: "the second video never
  /// loaded"). So there one window is made, and every video of the app's life shows in it.
  static String? _keptWindow;

  /// Tests: the next player makes its window again.
  @visibleForTesting
  static void debugForgetWindow() => _keptWindow = null;

  /// The id of the window the TV's video plane shows in, made the first time it is needed.
  /// Null for sound alone, and on a TV that has no such windows.
  Future<String?> _window() {
    if (audioOnly) return Future.value(null);
    final have = _windowId;
    if (have != null) return Future.value(have);
    return _windowFuture ??= () async {
      try {
        if (!await _tvHas('exportedWindows')) {
          _noWindows = true;
          return null;
        }
        final keep = !await _tvHas('initWithWindowId');
        final kept = _keptWindow;
        if (keep && kept != null) {
          _windowId = kept;
          _noWindows = false;
          return kept;
        }
        final id = await _windows.invokeMethod<String>('create', <String, Object?>{});
        if (id != null && id.isNotEmpty && id != 'invalid') {
          _windowId = id;
          _noWindows = false;
          if (keep) _keptWindow = id;
        }
      } catch (e) {
        appLogger.w('[webOS] no exported window: $e');
      } finally {
        _windowFuture = null;
      }
      // A TV whose library knows such windows and whose compositor gave none (the feature is
      // not on this set, or not for this app): better a picture placed the older way than no
      // picture. Asked for again the next time a video opens.
      if (_windowId == null && await _tvHas('displayWindow')) {
        appLogger.w('[webOS] no window from the compositor: the media library places the picture');
        _noWindows = true;
      }
      return _windowId;
    }();
  }

  // ── open ──

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    if (disposed) return;
    await _ensureInitialized();
    final startPosition = media.start ?? timelineOffset;
    final previousState = state;
    final previousPosition = currentPosition;
    final previousTimelineDuration = configuredTimelineDuration;
    final previousTimelineOffset = this.timelineOffset;
    final previousExternalSubtitleMetadata = snapshotExternalSubtitleMetadata();
    configureTimeline(duration: timelineDuration, offset: timelineOffset);
    final sourceStart = sourcePositionFor(startPosition);
    clearTracks();
    setExternalSubtitleMetadata(externalSubtitles);
    resetPlaybackProgress(startPosition);
    setSeekable(false);
    _forget();
    _media = media;
    _live = isLive;
    _wantPlay = play;
    final id = ++_sources;

    try {
      final address = await _addressFor(media);
      final windowId = await _window();
      if (disposed || id != _sources) return;
      // (a TV that has no such windows shows the picture without one: see [_placeWindow])
      if (!audioOnly && windowId == null && !_noWindows) {
        throw PlatformException(code: 'NO_WINDOW', message: 'The TV gave no window for the picture');
      }
      // (subtitle files handed over with the video: read before it starts, so the first line
      // is up with the first frame)
      for (final s in externalSubtitles ?? const <SubtitleTrack>[]) {
        final uri = s.uri;
        if (uri != null && uri.isNotEmpty) await _readSubtitleFile(uri, title: s.title, language: s.language, select: s.isDefault);
      }
      if (disposed || id != _sources) return;
      handlePlayerEvent('start-file', {'sourceId': id});
      handlePropertyChange('pause', !play);
      handlePropertyChange('paused-for-cache', true);
      _clockMs = sourceStart.inMilliseconds;
      await invoke('load', {
        'uri': address,
        'payload': jsonEncode(loadPayload(address, appId: _appId, windowId: windowId, startMs: sourceStart.inMilliseconds, live: isLive)),
        'windowId': windowId ?? '',
      });
    } catch (_) {
      if (!disposed && id == _sources) {
        configureTimeline(duration: previousTimelineDuration, offset: previousTimelineOffset);
        restorePlaybackProgress(previousState, position: previousPosition);
        restoreTracks(previousState);
        restoreExternalSubtitleMetadata(previousExternalSubtitleMetadata);
        setSeekable(previousState.seekable);
      }
      rethrow;
    }
  }

  static String get _appId => Platform.environment['FLUTTER_APP_ID'] ?? '';

  /// The address the TV is given: the link itself, or a relay on this device when the link
  /// needs headers the TV cannot send.
  Future<String> _addressFor(Media media) async {
    final headers = media.headers;
    final uri = Uri.tryParse(media.uri);
    if (headers == null || headers.isEmpty || uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return media.uri;
    // (what the app's own relays hand out is already on this device and wants none)
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') return media.uri;
    return HeaderRelay.instance.wrap(media.uri, headers);
  }

  /// What the TV's player is told with an address: which kind of stream, whose window, where
  /// to start. (Kept apart and public: the tests read it.)
  @visibleForTesting
  static Map<String, Object?> loadPayload(String address, {required String appId, String? windowId, int startMs = 0, bool live = false}) {
    final path = Uri.tryParse(address)?.path.toLowerCase() ?? address.toLowerCase();
    final String? transport;
    if (address.startsWith('udp://')) {
      transport = 'UDP';
    } else if (address.startsWith('rtp://')) {
      transport = 'RTP';
    } else if (address.startsWith('rtsp://')) {
      transport = 'RTSP';
    } else if (path.endsWith('.m3u8') || path.endsWith('.m3u')) {
      transport = 'HLS';
    } else if (path.endsWith('.mpd')) {
      transport = 'MPEG-DASH';
    } else {
      transport = null; // a file: the TV works it out
    }
    return {
      'mediaTransportType': ?transport,
      'option': {
        if (appId.isNotEmpty) 'appId': appId,
        if (windowId != null && windowId.isNotEmpty) 'windowId': windowId,
        // (a live stream has no "start": it begins where it is)
        if (startMs > 0 && !live)
          'transmission': {
            'playTime': {'start': startMs},
          },
      },
    };
  }

  void _forget() {
    _loaded = false;
    _started = false;
    _ended = false;
    _lost = false;
    _taken = false;
    _durationMs = 0;
    _videoW = _videoH = 0;
    _audio = [];
    _text = [];
    _files.clear();
    _audioIndex = 0;
    _subId = 'no';
    _cues = SubtitleCues.empty;
    _now = const WebosNowPlaying();
    _stopClock();
    vyseResetForNewFile();
  }

  // ── what the TV's player says ──

  @override
  void handlePlayerEvent(String name, Map? data) {
    if (disposed) return;
    if (name == 'media') {
      final text = data?['json'];
      if (text is String) onPlayerMessage(text);
      return;
    }
    if (name == 'app') {
      final state = data?['state'];
      if (state is String) _appStateChanged(state);
      return;
    }
    if (name == 'taken') {
      _onTaken();
      return;
    }
    super.handlePlayerEvent(name, data);
  }

  /// One event of the TV's player, as the JSON it sends. (Public for the tests, which play the
  /// TV's part.)
  @visibleForTesting
  void onPlayerMessage(String text) {
    if (disposed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final e = decoded;
    if (e['loadCompleted'] != null) {
      _onLoaded();
    } else if (e['playing'] != null) {
      _onPlaying();
    } else if (e['paused'] != null) {
      _clockPause();
      handlePropertyChange('pause', true);
    } else if (e['currentTime'] != null) {
      final t = e['currentTime'];
      final ms = _int(t is Map ? t['currentTime'] : t);
      if (ms != null) _tick(ms);
    } else if (e['bufferingStart'] != null) {
      _clockPause();
      handlePropertyChange('paused-for-cache', true);
    } else if (e['bufferingEnd'] != null) {
      if (state.playing) _clockRun();
      handlePropertyChange('paused-for-cache', false);
    } else if (e['seekDone'] != null) {
      handlePlayerEvent('playback-restart', {'sourceId': _sources, 'positionSeconds': _clockNowMs() / 1000});
    } else if (e['endOfStream'] != null) {
      _onEnded();
    } else if (e['sourceInfo'] is Map) {
      _onSourceInfo((e['sourceInfo'] as Map).cast<String, Object?>());
    } else if (e['videoInfo'] is Map) {
      _onVideoInfo((e['videoInfo'] as Map).cast<String, Object?>());
    } else if (e['audioInfo'] is Map) {
      _now = WebosNowPlaying(video: _now.video, audio: (e['audioInfo'] as Map).cast<String, Object?>(), source: _now.source);
    } else if (e['bufferRange'] is Map) {
      // (the end of what is fetched, in seconds)
      final end = (e['bufferRange'] as Map)['endTime'];
      if (end is num && end >= 0) handlePropertyChange('demuxer-cache-time', end.toDouble());
    } else if (e['trackSelected'] is Map) {
      _onTrackSelected((e['trackSelected'] as Map).cast<String, Object?>());
    } else if (e['subtitleData'] is Map) {
      // a line of a subtitle track inside the file, when the TV hands its text over
      final said = (e['subtitleData'] as Map)['subtitleData'];
      if (_subId.startsWith('tv:') && said is String) _say(said.trim());
    } else if (e['error'] is Map) {
      final err = e['error'] as Map;
      _onError(_int(err['errorCode']) ?? 0, err['errorText'] is String ? err['errorText'] as String : '');
    }
  }

  static int? _int(Object? v) => v is int ? v : (v is num && v.isFinite ? v.toInt() : null);

  void _onLoaded() {
    _loaded = true;
    handlePlayerEvent('file-loaded', {'sourceId': _sources});
    // (without a window the media library is told where the picture goes, once it has one)
    if (_noWindows) unawaited(_placeWindow());
    if (_rate != 1.0) unawaited(_quiet(() => invoke('setRate', {'rate': _rate})));
    _applySubtitleChoice();
    if (_wantPlay) {
      unawaited(_quiet(() => invoke('play')));
    } else {
      handlePropertyChange('pause', true);
      handlePropertyChange('paused-for-cache', false);
    }
  }

  void _onPlaying() {
    handlePropertyChange('pause', false);
    handlePropertyChange('paused-for-cache', false);
    _clockRun();
    _watchPosition();
    if (!_started) {
      _started = true;
      handlePlayerEvent('playback-restart', {'sourceId': _sources, 'positionSeconds': _clockNowMs() / 1000});
    }
  }

  void _onEnded() {
    if (_ended) return;
    _ended = true;
    _clockPause();
    handlePropertyChange('pause', true);
    // (as mpv with keep-open: the film stays open at its end, and Play starts it over)
    handlePropertyChange('eof-reached', true);
  }

  void _onSourceInfo(Map<String, Object?> info) {
    final programs = info['programInfo'];
    final p = programs is List && programs.isNotEmpty && programs.first is Map ? (programs.first as Map).cast<String, Object?>() : const <String, Object?>{};
    final duration = _int(p['duration']) ?? _int(info['duration']) ?? 0;
    final audio = _tracks(p['audioTrackInfo']);
    final text = _tracks(p['subtitleTrackInfo']);
    // The TV first sends an empty one (no length, no tracks), then the real one.
    if (duration <= 0 && audio.isEmpty && (_int(p['numVideoTracks']) ?? 0) == 0 && (_int(p['numAudioTracks']) ?? 0) == 0) return;
    _now = WebosNowPlaying(video: _now.video, audio: _now.audio, source: info);
    _durationMs = duration;
    if (duration > 0) handlePropertyChange('duration', duration / 1000);
    final seekable = info['seekable'];
    setSeekable(!_live && (seekable is bool ? seekable : duration > 0));
    _audio = audio;
    _text = text;
    if (_audioIndex >= _audio.length) _audioIndex = 0;
    _publishTracks();
  }

  static List<_TvTrack> _tracks(Object? list) {
    if (list is! List) return [];
    final out = <_TvTrack>[];
    for (final t in list) {
      if (t is! Map) continue;
      out.add(
        _TvTrack(
          index: out.length,
          language: t['language'] is String ? t['language'] as String : '',
          codec: t['codec'] is String ? t['codec'] as String : (t['type'] is String ? t['type'] as String : ''),
          channels: _int(t['channels']),
          sampleRate: _int(t['sampleRate']),
        ),
      );
    }
    return out;
  }

  /// The tracks as mpv would list them, which is what the rest of the player reads.
  void _publishTracks() {
    handlePropertyChange('track-list', [
      if (_videoW > 0 || !audioOnly) {'type': 'video', 'id': '1', 'selected': true},
      for (final t in _audio)
        {
          'type': 'audio',
          'id': '${t.index + 1}',
          'lang': t.language,
          'codec': t.codec,
          if (t.channels != null) 'demux-channel-count': t.channels,
          if (t.sampleRate != null) 'demux-samplerate': t.sampleRate,
          'selected': t.index == _audioIndex,
        },
      for (final t in _text) {'type': 'sub', 'id': 'tv:${t.index}', 'lang': t.language, 'codec': t.codec, 'selected': _subId == 'tv:${t.index}'},
      for (final f in _files)
        {
          'type': 'sub',
          'id': f.id,
          'title': f.title,
          'lang': f.language,
          'codec': f.codec,
          'external': true,
          'external-filename': f.uri,
          'selected': _subId == f.id,
        },
    ]);
    if (_subId == 'no') handlePropertyChange('sid', 'no');
  }

  void _onVideoInfo(Map<String, Object?> info) {
    _now = WebosNowPlaying(video: info, audio: _now.audio, source: _now.source);
    final w = _int(info['width']) ?? 0, h = _int(info['height']) ?? 0;
    if (w <= 0 || h <= 0) return;
    final changed = w != _videoW || h != _videoH;
    _videoW = w;
    _videoH = h;
    if (changed) {
      vyseHandleProperty('dwidth', w);
      vyseHandleProperty('dheight', h);
      // (the plane is cut from the picture's own size: say it again now that it is known)
      unawaited(_placeWindow());
    }
  }

  void _onTrackSelected(Map<String, Object?> t) {
    final index = _int(t['index']);
    if (index == null) return;
    if (t['type'] == 'audio' && index >= 0 && index < _audio.length) {
      _audioIndex = index;
      _publishTracks();
    }
  }

  // Codes of the TV's player (LG's own names for them in its web engine).
  static const _seekFailed = 700;
  static const _decoderTaken = {600, 601, 602, 61456};

  void _onError(int code, String text) {
    appLogger.w('[webOS] player error $code $text');
    if (code == _seekFailed) return; // (the seek did not happen; playback goes on where it was)
    if (_decoderTaken.contains(code)) {
      // Another app, or the TV itself, took the decoder. Not a fault of the video: it is
      // opened again where it was when the app is in front again.
      _lost = true;
      _loaded = false;
      _clockPause();
      handlePropertyChange('pause', true);
      unawaited(_quiet(() => invoke('unload')));
      return;
    }
    _clockPause();
    final what = errorNote(code, text);
    logController.add(PlayerLog(level: PlayerLogLevel.error, prefix: 'tv', text: what));
    handlePlayerEvent('end-file', {'reason': 'error', 'message': what, 'sourceId': _sources});
  }

  /// A fault of the TV's player in words: the report card shows it, and "it said it can't play
  /// this one" from a TV then tells which part.
  @visibleForTesting
  static String errorNote(int code, String text) {
    final kind = switch (code) {
      200 => "The TV can't play this sound",
      201 => "The TV can't play this picture",
      202 => "The TV couldn't find the video",
      203 || 204 => "The TV can't read this file",
      210 => "The TV can't read this subtitle",
      300 => "The TV couldn't reach the video",
      301 => "The TV won't play over an open Wi-Fi",
      >= 400 && < 500 => 'The stream stopped answering',
      1000 => "The TV's player stopped",
      _ => "The TV couldn't play this",
    };
    return '$kind ($code${text.isEmpty ? '' : ' $text'})';
  }

  // ── the app going away and coming back ──

  void _appStateChanged(String state) {
    // (LG's embedder names them as Flutter does: AppLifecycleState.resumed, .hidden, .paused)
    if (state.endsWith('resumed') && _lost) unawaited(_openAgain());
  }

  /// A TV with one player for the whole app (before webOS 6): another of the app's players
  /// has just been given it, the film in place of the music or the other way round, and what
  /// this one was playing is unloaded. Nothing is wrong with it. It shows as paused, and is
  /// opened again where it was when it is asked to play (not when the app comes back to the
  /// front: that would take the player from the one that has it).
  void _onTaken() {
    _taken = true;
    _loaded = false;
    _wantPlay = false;
    _clockPause();
    handlePropertyChange('pause', true);
  }

  /// Opens what was playing again, where it was.
  Future<void> _openAgain() async {
    final media = _media;
    if (media == null) return;
    _lost = false;
    _taken = false;
    final at = currentPosition;
    await _quiet(() => open(Media(media.uri, headers: media.headers, start: at), play: _wantPlay, isLive: _live, timelineDuration: configuredTimelineDuration, timelineOffset: timelineOffset));
  }

  // ── position ──

  void _tick(int ms) {
    _lastTickAt = _wall.elapsedMilliseconds;
    _clockMs = ms;
    if (_clock.isRunning) {
      _clock
        ..reset()
        ..start();
    } else {
      _clock.reset();
    }
    handlePropertyChange('time-pos', ms / 1000);
    _showLine();
  }

  final _wall = clock.stopwatch()..start();

  /// The film's time now, between two of the TV's position reports (source time, ms).
  int _clockNowMs() => _clockMs + (_clock.elapsedMilliseconds * _rate).round();

  void _clockRun() {
    if (!_clock.isRunning) _clock.start();
    _armSubTimer();
  }

  void _clockPause() {
    if (_clock.isRunning) {
      _clockMs = _clockNowMs();
      _clock
        ..stop()
        ..reset();
    }
    _subTimer?.cancel();
    _subTimer = null;
  }

  void _stopClock() {
    _clock
      ..stop()
      ..reset();
    _subTimer?.cancel();
    _subTimer = null;
    _positionPoll?.cancel();
    _positionPoll = null;
  }

  /// The TV reports the position as it plays. Should a set not do so, it is asked.
  void _watchPosition() {
    _positionPoll ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      if (disposed || !_loaded || !state.playing || state.buffering) return;
      if (_wall.elapsedMilliseconds - _lastTickAt < 1500) return;
      final at = await _quiet(() => invoke<int>('position'));
      if (at != null && at >= 0 && !disposed && _loaded) _tick(at);
    });
  }

  // ── subtitles ──

  /// Shows the line of the chosen subtitle file for the film's time now, and wakes again when
  /// that next changes.
  void _showLine() {
    if (!_subId.startsWith('file:')) return;
    if (!_subVisible || _cues.isEmpty) {
      _say('');
      return;
    }
    _say(_cues.textAt(_clockNowMs() / 1000 - _subDelay));
    _armSubTimer();
  }

  void _armSubTimer() {
    _subTimer?.cancel();
    _subTimer = null;
    if (!_clock.isRunning || !_subId.startsWith('file:') || !_subVisible || _cues.isEmpty) return;
    final now = _clockNowMs() / 1000 - _subDelay;
    final next = _cues.nextChangeAfter(now);
    if (next == null) return;
    final wait = ((next - now) * 1000 / (_rate <= 0 ? 1 : _rate)).ceil().clamp(10, 60000).toInt();
    _subTimer = Timer(Duration(milliseconds: wait), _showLine);
  }

  void _say(String text) => vyseHandleProperty('sub-text', text);

  Future<_SubFile?> _readSubtitleFile(String uri, {String? title, String? language, bool select = false}) async {
    final already = _files.where((f) => f.uri == uri).firstOrNull;
    if (already != null) {
      if (select) _subId = already.id;
      return already;
    }
    try {
      final parsed = Uri.tryParse(uri);
      final path = parsed != null && parsed.isScheme('file') ? parsed.toFilePath() : uri;
      final content = await File(path).readAsString();
      final cues = SubtitleCues.parse(content);
      final lower = path.toLowerCase();
      final file = _SubFile(
        id: 'file:${_files.length}',
        uri: uri,
        title: title ?? '',
        language: language ?? '',
        codec: lower.endsWith('.ass') || lower.endsWith('.ssa') ? 'ass' : (lower.endsWith('.vtt') ? 'webvtt' : 'subrip'),
        cues: cues,
      );
      _files.add(file);
      if (select) _subId = file.id;
      return file;
    } catch (e) {
      appLogger.w('[webOS] subtitle file not read: $e');
      return null;
    }
  }

  @override
  Future<bool> addSubtitleFile(String uri, {String? title, String? language}) async {
    if (disposed) return false;
    final file = await _readSubtitleFile(uri, title: title, language: language, select: true);
    if (file == null || disposed) return true; // (ours to handle either way: mpv's commands mean nothing here)
    _applySubtitleChoice();
    _publishTracks();
    handlePropertyChange('sid', _subId);
    return true;
  }

  /// Puts on what [_subId] says: a file's lines from here, a track of the video's in the TV's
  /// player, or nothing.
  void _applySubtitleChoice() {
    final id = _subId;
    final file = _files.where((f) => f.id == id).firstOrNull;
    _cues = file?.cues ?? SubtitleCues.empty;
    if (file == null) _say('');
    if (_loaded) {
      if (id.startsWith('tv:')) {
        final index = int.tryParse(id.substring(3)) ?? 0;
        unawaited(_quiet(() async {
          await invoke('selectTrack', {'type': 'text', 'index': index});
          await invoke('setSubtitleEnable', {'enable': _subVisible});
        }));
      } else {
        unawaited(_quiet(() => invoke('setSubtitleEnable', {'enable': false})));
      }
    }
    _showLine();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    if (disposed) return;
    final id = track.id;
    if (id == SubtitleTrack.off.id) {
      _subId = 'no';
    } else if (id.startsWith('tv:') || id.startsWith('file:')) {
      _subId = id;
    } else if (track.uri != null) {
      // (a file named by its address rather than by our id)
      final file = await _readSubtitleFile(track.uri!, title: track.title, language: track.language);
      if (file == null) return;
      _subId = file.id;
    } else {
      return;
    }
    _applySubtitleChoice();
    _publishTracks();
    handlePropertyChange('sid', _subId);
  }

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    if (disposed) return;
    final index = (int.tryParse(track.id) ?? 0) - 1;
    if (index < 0 || index >= _audio.length) return;
    _audioIndex = index;
    if (_loaded) await invoke('selectTrack', {'type': 'audio', 'index': index});
    _publishTracks();
  }

  // ── the controls ──

  @override
  Future<void> play() async {
    _wantPlay = true;
    if (_taken || _lost) {
      // (its player went to another: Play is what brings it back)
      await _openAgain();
      return;
    }
    if (_ended) {
      // (played out: Play starts it over, as mpv's keep-open does)
      _ended = false;
      handlePropertyChange('eof-reached', false);
      await seek(timelineOffset);
    }
    if (_loaded) await invoke('play');
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    if (_loaded) {
      await invoke('pause');
    } else {
      handlePropertyChange('pause', true);
    }
  }

  @override
  Future<void> stop() async {
    _sources++;
    _loaded = false;
    _lost = false;
    _taken = false;
    _stopClock();
    _say('');
    await invoke('unload');
    setSeekable(false);
    handlePropertyChange('pause', true);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_loaded) return;
    final target = sourcePositionFor(position).inMilliseconds;
    await runSeek(position, () async {
      await invoke('seek', {'positionMs': target});
      _ended = false;
      _clockMs = target;
      _clock.reset();
      _showLine();
    });
  }

  /// The TV has one volume, and it is the remote's. Kept so the interface's own number moves.
  @override
  Future<void> setVolume(double volume) async {
    if (!disposed) setVolumeState(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    if (disposed) return;
    if (_clock.isRunning) {
      _clockMs = _clockNowMs();
      _clock.reset();
    }
    _rate = rate;
    if (_loaded) await invoke('setRate', {'rate': rate});
    if (!disposed) setRateState(rate);
    _armSubTimer();
  }

  @override
  Future<void> setProperty(String name, String value) async {
    if (disposed) return;
    switch (name) {
      case 'pause':
        await (value == 'yes' ? pause() : play());
      case 'volume':
        await setVolume(double.tryParse(value) ?? 100);
      case 'speed':
        await setRate(double.tryParse(value) ?? 1.0);
      case 'sub-delay':
        _subDelay = double.tryParse(value) ?? 0;
        if (_subId.startsWith('tv:') && _loaded) {
          await _quiet(() => invoke('setSubtitleSync', {'ms': (_subDelay * 1000).round()}));
        }
        _showLine();
      case 'sub-visibility':
        _subVisible = value != 'no';
        if (_subId.startsWith('tv:') && _loaded) {
          await _quiet(() => invoke('setSubtitleEnable', {'enable': _subVisible}));
        }
        _showLine();
      case 'video-aspect-override':
        final forced = _aspectOf(value);
        if (forced != _forcedAspect) {
          _forcedAspect = forced;
          await _placeWindow();
        }
      default:
        // an mpv property: nothing here to set
        break;
    }
  }

  @override
  Future<String?> getProperty(String name) async {
    if (disposed) return null;
    final fps = _now.video['frameRate'];
    return switch (name) {
      'pause' => state.playing ? 'no' : 'yes',
      'volume' => state.volume.toString(),
      'speed' => state.rate.toString(),
      'time-pos' => (state.position.inMilliseconds / 1000.0).toString(),
      'duration' => (state.duration.inMilliseconds / 1000.0).toString(),
      'seekable' => state.seekable ? 'yes' : 'no',
      'width' || 'dwidth' => _videoW > 0 ? '$_videoW' : null,
      'height' || 'dheight' => _videoH > 0 ? '$_videoH' : null,
      'container-fps' || 'estimated-vf-fps' => fps is num && fps > 0 ? '$fps' : null,
      _ => null,
    };
  }

  /// mpv commands have nothing to act on here.
  @override
  // ignore: no-empty-block
  Future<void> command(List<String> args) async {}

  @override
  Future<Map<String, dynamic>> getStats() async {
    if (disposed) return {};
    final v = _now.video, a = _now.audio, s = _now.source;
    final vui = v['VUI'];
    final transfer = vui is Map ? _int(vui['transferCharacteristics']) : null;
    final programs = s['programInfo'];
    final program = programs is List && programs.isNotEmpty && programs.first is Map ? programs.first as Map : const <Object?, Object?>{};
    final pictures = program['videoTrackInfo'];
    final picture = pictures is List && pictures.isNotEmpty && pictures.first is Map ? pictures.first as Map : const <Object?, Object?>{};
    return {
      'engine': 'webos',
      if (_videoW > 0) 'videoWidth': _videoW,
      if (_videoH > 0) 'videoHeight': _videoH,
      if (picture['codec'] is String) 'videoCodec': picture['codec'],
      if (v['frameRate'] != null) 'videoFps': v['frameRate'],
      if (v['hdrType'] != null) 'hdrType': v['hdrType'],
      'transfer': ?transfer,
      if (v['bitRate'] != null) 'videoBitrate': v['bitRate'],
      if (a['channels'] != null) 'audioChannels': a['channels'],
      if (a['sampleRate'] != null) 'audioSampleRate': a['sampleRate'],
      if (a['immersive'] != null) 'audioImmersive': a['immersive'],
      if (s['container'] != null) 'container': s['container'],
      if (_audioIndex < _audio.length) 'audioCodec': _audio[_audioIndex].codec,
      'durationMs': _durationMs,
    };
  }

  /// Hidden (the app is behind another) the TV is told to blank the plane; the sound stops
  /// with the pause the app does itself.
  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async {
    if (disposed || audioOnly || !_loaded) return true;
    await _quiet(() => invoke('muteDisplay', {'mute': !visible}));
    return true;
  }

  // ── where the picture sits ──

  /// The video's place in the interface, given in device pixels. The compositor wants it in the
  /// interface's own (LG's video plugin passes the widget's rectangle as Flutter measures it),
  /// so it is taken back from device pixels here.
  @override
  Future<void> setVideoRect({required int left, required int top, required int right, required int bottom, required double devicePixelRatio}) async {
    if (disposed || audioOnly) return;
    final r = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    _rect = (x: (left / r).round(), y: (top / r).round(), w: ((right - left) / r).round(), h: ((bottom - top) / r).round());
    await _placeWindow();
  }

  // The picture's shape (the player's More > Picture). mpv and Media3 shape the picture inside
  // their own surface; here the plane is the picture, so its shape is worked out in [plane].
  int _fit = 0; // 0 the whole picture, 1 cropped to cover the box, 2 pulled to the box
  double? _forcedAspect; // shown as 16:9, 4:3 or 21:9 whatever the file says; null: its own shape
  double _zoom = 1.0;

  @override
  Future<void> setBoxFitMode(int mode) async {
    if (disposed || mode == _fit) return;
    _fit = mode;
    await _placeWindow();
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    if (disposed || scale <= 0 || scale == _zoom) return;
    _zoom = scale;
    await _placeWindow();
  }

  /// mpv's `video-aspect-override` as a number: `16:9`, `1.7778`, or `no` for the picture's own.
  static double? _aspectOf(String value) {
    final parts = value.split(':');
    if (parts.length == 2) {
      final a = double.tryParse(parts[0]), b = double.tryParse(parts[1]);
      return a != null && b != null && a > 0 && b > 0 ? a / b : null;
    }
    final n = double.tryParse(value);
    return n != null && n > 0 ? n : null;
  }

  /// Where the TV's video plane goes, and which part of the picture it shows.
  ///
  /// The TV pulls the part of the picture named by `src` (in the video's own pixels) to the
  /// rectangle `dst` (in the interface's), whatever their shapes: a plane as large as the box
  /// would show every film stretched to the screen. So the black bars are made here: the
  /// picture is laid in the box ([x], [y], [w], [h]) at its own shape ([fit] 0), cropped to
  /// cover it (1) or pulled to it (2), enlarged by [zoom], and whatever then runs past the box
  /// is cut from the source instead. [pixelAspect] is for a file whose pixels are not square;
  /// [forcedAspect] shows the picture at that shape whatever the file says.
  @visibleForTesting
  static ({List<int> src, List<int> dst})? plane({
    required int x,
    required int y,
    required int w,
    required int h,
    required int videoW,
    required int videoH,
    double pixelAspect = 1,
    int fit = 0,
    double? forcedAspect,
    double zoom = 1,
  }) {
    if (w <= 0 || h <= 0 || videoW <= 0 || videoH <= 0) return null;
    final aspect = forcedAspect ?? videoW * (pixelAspect > 0 ? pixelAspect : 1) / videoH;
    final wider = w / h > aspect; // the box is wider than the picture
    // the picture's size on screen, before the box cuts it
    double pw, ph;
    if (fit == 2) {
      pw = w.toDouble();
      ph = h.toDouble();
    } else if ((fit == 1) == wider) {
      pw = w.toDouble();
      ph = w / aspect;
    } else {
      ph = h.toDouble();
      pw = h * aspect;
    }
    final z = zoom > 0 ? zoom : 1.0;
    pw *= z;
    ph *= z;
    // what of it the box shows, and the same share of the video's own pixels (kept even: the
    // TV's scaler takes whole chroma samples)
    final showW = pw < w ? pw : w.toDouble(), showH = ph < h ? ph : h.toDouble();
    int even(double v, int most) => (v.round() & ~1).clamp(2, most).toInt();
    final sw = even(videoW * showW / pw, videoW), sh = even(videoH * showH / ph, videoH);
    final dw = showW.round().clamp(1, w).toInt(), dh = showH.round().clamp(1, h).toInt();
    return (
      src: [((videoW - sw) ~/ 2) & ~1, ((videoH - sh) ~/ 2) & ~1, sw, sh],
      dst: [x + (w - dw) ~/ 2, y + (h - dh) ~/ 2, dw, dh],
    );
  }

  Future<void> _placeWindow() async {
    final rect = _rect, id = _windowId;
    if (rect == null || (id == null && !_noWindows)) return;
    final par = _now.video['pixelAspectRatio'];
    final parW = par is Map ? par['width'] : null, parH = par is Map ? par['height'] : null;
    // Until the TV has said the picture's size there is nothing to cut the plane from.
    final p = plane(
      x: rect.x,
      y: rect.y,
      w: rect.w,
      h: rect.h,
      videoW: _videoW,
      videoH: _videoH,
      pixelAspect: parW is num && parH is num && parW > 0 && parH > 0 ? parW / parH : 1,
      fit: _fit,
      forcedAspect: _forcedAspect,
      zoom: _zoom,
    );
    if (p == null) return;
    if (id != null) {
      await _quiet(() => _windows.invokeMethod<void>('resize', {'windowId': id, 'srcRect': p.src, 'dstRect': p.dst}));
      return;
    }
    // No window (webOS 4): the media library takes a rectangle on the screen and nothing else.
    // It cannot be told to show a part of the picture, so the whole picture goes into the
    // rectangle it would have had uncropped: Fill and zooming in show as Fit there.
    if (!_loaded || !await _tvHas('displayWindow')) return;
    final whole = plane(
      x: rect.x,
      y: rect.y,
      w: rect.w,
      h: rect.h,
      videoW: _videoW,
      videoH: _videoH,
      pixelAspect: parW is num && parH is num && parW > 0 && parH > 0 ? parW / parH : 1,
      fit: _fit == 2 ? 2 : 0,
      forcedAspect: _forcedAspect,
      zoom: _zoom > 1 ? 1 : _zoom,
    );
    if (whole == null) return;
    await _quiet(() => invoke('setDisplayWindow', {'x': whole.dst[0], 'y': whole.dst[1], 'w': whole.dst[2], 'h': whole.dst[3]}));
  }

  static Future<T?> _quiet<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } catch (e) {
      appLogger.d('[webOS] $e');
      return null;
    }
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (disposed) return;
    _sources++;
    _stopClock();
    final id = _windowId;
    _windowId = null;
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
    // (after the player is gone: a plane taken away under a playing video is a black flash.
    // The window an older TV keeps for good stays: see [_keptWindow].)
    if (id != null && id != _keptWindow) await _quiet(() => _windows.invokeMethod<void>('dispose', {'windowId': id}));
  }
}

class _TvTrack {
  const _TvTrack({required this.index, required this.language, required this.codec, this.channels, this.sampleRate});
  final int index;
  final String language;
  final String codec;
  final int? channels;
  final int? sampleRate;
}

class _SubFile {
  const _SubFile({required this.id, required this.uri, required this.title, required this.language, required this.codec, required this.cues});
  final String id;
  final String uri;
  final String title;
  final String language;
  final String codec;
  final SubtitleCues cues;
}
