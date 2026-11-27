// VyseTV addition (not in upstream).
//
// The player on a Samsung TV (Tizen): the TV's own media player.
//
// A Samsung TV plays video through its own player (the one behind its web apps' AVPlay). An
// app hands it an address; the TV fetches, reads the container, decodes in hardware and shows
// the picture on its video plane, under the app's surface, with its own picture chain (4K and
// HDR where the set has them) and its own sound settings. Samsung's Flutter plugin for it
// (video_player_avplay) is used here through its platform interface, not its widget: the
// native side is Samsung's, and everything that decides anything is here, in Dart, where it
// can be tested with a stand-in for the TV (test/tizen_player_test.dart).
//
// What that means for the rest of the app:
//  * No mpv. mpv's properties and commands mean nothing here ([mpvCore] is false); what both
//    engines understand goes through the [Player] interface.
//  * The picture is a hole in the interface over the TV's video plane (VyseVideo). The TV is
//    told the rectangle, in the screen's pixels ([setVideoRect]), and pulls the picture to it
//    whatever its shape, so the rectangle is cut to the picture's shape here ([pictureRect]).
//  * Headers. The TV can be told a cookie and a user agent and nothing else; a link with other
//    headers is opened through a relay on this device (support/header_relay.dart).
//  * Subtitles. A subtitle file is read here (support/subtitle_cues.dart) and its lines are
//    given out as `sub-text` in time with the film. A subtitle track inside the video is
//    switched on in the TV's player, which draws none itself: it hands each line over, as text
//    or (a Blu-ray's or a DVD's) as a picture, and the player page draws both.
//  * No volume of its own: the remote's volume is the TV's.
//
// See tizen/README.md for what is proven and what is not.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:video_player_avplay/video_player.dart' as avplay show AudioTrack, TextTrack, VideoTrack;
import 'package:video_player_avplay/video_player_platform_interface.dart' as avplay;

import '../../models.dart';
import '../../../core/platform/tv_memory.dart';
import '../../support/app_logger.dart';
import '../../support/header_relay.dart';
import '../../support/subtitle_cues.dart';
import '../player_base.dart';
import '../video_rect_support.dart';
import '../vyse_extras.dart';

class PlayerTizen extends PlayerBase with VideoRectSupport {
  /// The video player.
  PlayerTizen() : this._(slot: 0, audioOnly: false);

  /// A sound-only player, for music and audiobooks; [secondary] is the second one (a watch
  /// party's music beside the app's own).
  PlayerTizen.audio({bool secondary = false}) : this._(slot: secondary ? 2 : 1, audioOnly: true);

  PlayerTizen._({required this.slot, required this.audioOnly})
    // (never used: this engine has no native side of its own, see [usesNativeChannels])
    : methodChannel = MethodChannel('vyse/tizen_media/$slot'),
      eventChannel = EventChannel('vyse/tizen_media/$slot/events') {
    // (the TV's player shares the app's memory: see TvMemory)
    if (!audioOnly) TvMemory.filmOpened();
  }

  final int slot;
  final bool audioOnly;

  @override
  final MethodChannel methodChannel;

  @override
  final EventChannel eventChannel;

  /// Samsung's plugin. A test puts a stand-in for the TV here.
  @visibleForTesting
  static avplay.VideoPlayerPlatform? debugTv;

  static avplay.VideoPlayerPlatform get _tv => debugTv ?? avplay.VideoPlayerPlatform.instance;

  // Samsung's `init` disposes every player there is, so it is said once for the whole app.
  static Future<void>? _tvReady;

  /// Tests: the next player starts the plugin again.
  @visibleForTesting
  static void debugForgetTv() => _tvReady = null;

  @override
  bool get usesNativeChannels => false;

  /// Nothing native of ours to call: what the base class would send there means nothing here.
  @override
  Future<T?> invoke<T>(String method, [dynamic args]) async => null;

  @override
  String get logPrefix => 'Tizen';

  @override
  String get playerType => 'tizen';

  @override
  bool get mpvCore => false;

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  bool get providesNativeStats => true;

  // ── what is open ──

  int? _id; // Samsung's player for what is open now
  StreamSubscription<avplay.VideoEvent>? _events;
  int _sources = 0; // the id of the newest load; events of an older one are not for us
  bool _loaded = false; // the TV said `initialized` for the current load
  bool _wantPlay = true; // play or pause, as last asked (applied once loaded)
  bool _started = false; // the first "playing" of this load was seen
  bool _ended = false;
  bool _suspended = false; // the app went to the background and the TV's player was put away
  Media? _media;
  bool _live = false;
  int _startMs = 0;
  int _durationMs = 0;
  int _videoW = 0, _videoH = 0;
  double _rate = 1.0;
  _Lifecycle? _lifecycle;

  // the rectangle last asked for, in the screen's pixels
  ({int x, int y, int w, int h})? _rect;
  avplay.DisplayMode? _mode;

  // ── tracks ──

  var _audio = <avplay.AudioTrack>[];
  var _text = <avplay.TextTrack>[];
  avplay.VideoTrack? _video;
  final _files = <_SubFile>[]; // subtitle files, read here
  int _audioIndex = 0;
  String _subId = 'no'; // 'no', 'tv:<index>' or 'file:<n>'

  // ── subtitle lines and their clock ──

  SubtitleCues _cues = SubtitleCues.empty;
  _TvLine? _tvLine; // the last line the TV handed over, for a track inside the video
  double _subDelay = 0; // seconds, as mpv's sub-delay: positive shows lines later
  bool _subVisible = true;
  int _clockMs = 0; // the film's time at [_clock] zero, in the source's own time
  // (the clock package's, not dart:core's: a test's made-up time moves it too)
  final _clock = clock.stopwatch();
  Timer? _subTimer;
  Timer? _positionPoll;

  // ── start-up ──

  Future<void> _ensureInitialized() async {
    if (initialized) return;
    try {
      await (_tvReady ??= _tv.init());
      if (disposed) throw StateError('Player was disposed during initialization');
      initialized = true;
      _lifecycle ??= _Lifecycle(this)..attach();
    } catch (e) {
      _tvReady = null;
      if (!disposed) errorController.add(PlayerError(e.toString(), cause: PlayerError.playerInitFailed));
      rethrow;
    }
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
    await _close();
    _forget();
    _media = media;
    _live = isLive;
    _wantPlay = play;
    final source = ++_sources;

    try {
      final (address, told) = await _addressFor(media);
      // (subtitle files handed over with the video: read before it starts, so the first line
      // is up with the first frame)
      for (final s in externalSubtitles ?? const <SubtitleTrack>[]) {
        final uri = s.uri;
        if (uri != null && uri.isNotEmpty) await _readSubtitleFile(uri, title: s.title, language: s.language, select: s.isDefault);
      }
      if (disposed || source != _sources) return;
      handlePlayerEvent('start-file', {'sourceId': source});
      handlePropertyChange('pause', !play);
      handlePropertyChange('paused-for-cache', true);
      _startMs = isLive ? 0 : sourceStart.inMilliseconds;
      _clockMs = _startMs;
      final id = await _tv.create(dataSource(address, streaming: told));
      if (id == null || id < 0) throw PlatformException(code: 'CREATE', message: "The TV's player did not take the video");
      if (disposed || source != _sources) {
        unawaited(_quiet(() => _tv.dispose(id)));
        return;
      }
      _id = id;
      _events = _tv.videoEventsFor(id).listen((e) => _onEvent(source, e), onError: (Object e) => _onError(source, e));
      unawaited(_placePicture());
    } catch (_) {
      if (!disposed && source == _sources) {
        configureTimeline(duration: previousTimelineDuration, offset: previousTimelineOffset);
        restorePlaybackProgress(previousState, position: previousPosition);
        restoreTracks(previousState);
        restoreExternalSubtitleMetadata(previousExternalSubtitleMetadata);
        setSeekable(previousState.seekable);
      }
      rethrow;
    }
  }

  /// What the TV's player is given for an address. (Public for the tests.)
  ///
  /// No start position: Samsung's start option never reaches its player (the native side
  /// reads it as a 64-bit number, and a number that small is sent as 32 bits), so the start is
  /// a seek before the first play ([_onLoaded]).
  @visibleForTesting
  static avplay.DataSource dataSource(String address, {Map<avplay.StreamingPropertyType, String> streaming = const {}}) {
    final path = (Uri.tryParse(address)?.path ?? address).toLowerCase();
    final web = address.startsWith('http://') || address.startsWith('https://');
    return avplay.DataSource(
      // (a file on this device goes to the TV's other player, which takes no headers)
      sourceType: web ? avplay.DataSourceType.network : avplay.DataSourceType.file,
      uri: address,
      formatHint: path.endsWith('.mpd') ? avplay.VideoFormat.dash : (path.endsWith('.m3u8') || path.endsWith('.m3u') ? avplay.VideoFormat.hls : null),
      streamingProperty: web && streaming.isNotEmpty ? streaming : null,
    );
  }

  /// The address the TV is given, and what of the link's headers it is told itself: the link
  /// with its cookie and user agent, or a relay on this device when it has other headers.
  Future<(String, Map<avplay.StreamingPropertyType, String>)> _addressFor(Media media) async {
    final headers = media.headers;
    final uri = Uri.tryParse(media.uri);
    if (headers == null || headers.isEmpty || uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return (media.uri, const <avplay.StreamingPropertyType, String>{});
    // (what the app's own relays hand out is already on this device and wants none)
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') return (media.uri, const <avplay.StreamingPropertyType, String>{});
    final told = streamingHeaders(headers);
    if (told != null) return (media.uri, told);
    return (await HeaderRelay.instance.wrap(media.uri, headers), const <avplay.StreamingPropertyType, String>{});
  }

  /// A link's headers as the TV's player takes them, or null when one of them is a header it
  /// cannot be told (anything but a cookie and a user agent).
  @visibleForTesting
  static Map<avplay.StreamingPropertyType, String>? streamingHeaders(Map<String, String> headers) {
    final out = <avplay.StreamingPropertyType, String>{};
    for (final e in headers.entries) {
      switch (e.key.toLowerCase()) {
        case 'cookie':
          out[avplay.StreamingPropertyType.cookie] = e.value;
        case 'user-agent':
          out[avplay.StreamingPropertyType.userAgent] = e.value;
        default:
          return null;
      }
    }
    return out;
  }

  void _forget() {
    _loaded = false;
    _started = false;
    _ended = false;
    _suspended = false;
    _durationMs = 0;
    _startMs = 0;
    _videoW = _videoH = 0;
    _mode = null;
    _audio = [];
    _text = [];
    _video = null;
    _files.clear();
    _audioIndex = 0;
    _subId = 'no';
    _cues = SubtitleCues.empty;
    _tvLine = null;
    _polledMs = null;
    _stillPolls = 0;
    _stopClock();
    vyseResetForNewFile();
  }

  /// Puts away the TV's player for what was open (Samsung's has one player per video).
  Future<void> _close() async {
    final id = _id;
    _id = null;
    final events = _events;
    _events = null;
    _loaded = false;
    _stopClock();
    // (not waited for: nothing comes of it, and its own future may never be one to wait on)
    unawaited(events?.cancel());
    if (id != null) await _quiet(() => _tv.dispose(id));
  }

  // ── what the TV's player says ──

  void _onEvent(int source, avplay.VideoEvent e) {
    if (disposed || source != _sources) return;
    switch (e.eventType) {
      case avplay.VideoEventType.initialized:
        unawaited(_onLoaded(source, e));
      case avplay.VideoEventType.restored:
        _onRestored();
      case avplay.VideoEventType.isPlayingStateUpdate:
        if (e.isPlaying == true) {
          _onPlaying();
        } else {
          _clockPause();
          handlePropertyChange('pause', true);
        }
      case avplay.VideoEventType.bufferingStart:
        _clockPause();
        handlePropertyChange('paused-for-cache', true);
      case avplay.VideoEventType.bufferingEnd:
        if (state.playing) _clockRun();
        handlePropertyChange('paused-for-cache', false);
      case avplay.VideoEventType.completed:
        _onEnded();
      case avplay.VideoEventType.subtitleUpdate:
        _onTvSubtitle(e.subtitlesInfo);
      default:
        break;
    }
  }

  Future<void> _onLoaded(int source, avplay.VideoEvent e) async {
    final id = _id;
    if (_loaded || id == null) return;
    _loaded = true;
    final range = e.duration;
    _durationMs = _live || range == null ? 0 : range.end.inMilliseconds;
    if (_durationMs > 0) handlePropertyChange('duration', _durationMs / 1000);
    setSeekable(!_live && _durationMs > 0);
    final size = e.size;
    if (size != null && size.width > 0 && size.height > 0) _videoSize(size.width.round(), size.height.round());
    await _readTracks(id);
    if (disposed || source != _sources) return;
    handlePlayerEvent('file-loaded', {'sourceId': source});
    unawaited(_placePicture());
    _watchPosition();
    // where it starts (see [dataSource])
    if (_startMs > 0) await _quiet(() => _seekTv(id, _startMs));
    if (disposed || source != _sources) return;
    if (_rate != 1.0) await _quiet(() => _tv.setPlaybackSpeed(id, _rate));
    _applySubtitleChoice();
    if (_wantPlay) {
      await _quiet(() => _tv.play(id));
    } else {
      handlePropertyChange('pause', true);
      handlePropertyChange('paused-for-cache', false);
    }
  }

  Future<void> _readTracks(int id) async {
    _audio = await _quiet(() => _tv.getAudioTracks(id)) ?? [];
    _text = await _quiet(() => _tv.getTextTracks(id)) ?? [];
    final videos = await _quiet(() => _tv.getVideoTracks(id)) ?? const <avplay.VideoTrack>[];
    _video = videos.isEmpty ? null : videos.first;
    for (final t in await _quiet(() => _tv.getActiveTrackInfo(id)) ?? const []) {
      if (t is avplay.AudioTrack) {
        final i = _audio.indexWhere((a) => a.trackId == t.trackId);
        if (i >= 0) _audioIndex = i;
      } else if (t is avplay.VideoTrack) {
        _video = t;
      }
    }
    final v = _video;
    if (_videoW == 0 && v != null && v.width > 0 && v.height > 0) _videoSize(v.width, v.height);
    _publishTracks();
  }

  void _videoSize(int w, int h) {
    if (w == _videoW && h == _videoH) return;
    _videoW = w;
    _videoH = h;
    vyseHandleProperty('dwidth', w);
    vyseHandleProperty('dheight', h);
    // (the rectangle is cut to the picture's shape: place it again now that it is known)
    unawaited(_placePicture());
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

  /// The tracks as mpv would list them, which is what the rest of the player reads.
  void _publishTracks() {
    final v = _video;
    handlePropertyChange('track-list', [
      if (!audioOnly)
        {
          'type': 'video',
          'id': '1',
          'selected': true,
          if (v != null) 'codec': codecOf(v.mimetype),
          if (v != null && v.width > 0) 'demux-w': v.width,
          if (v != null && v.height > 0) 'demux-h': v.height,
        },
      for (var i = 0; i < _audio.length; i++)
        {
          'type': 'audio',
          'id': '${i + 1}',
          'lang': _audio[i].language,
          'codec': codecOf(_audio[i].mimetype),
          if (_audio[i].channel > 0) 'demux-channel-count': _audio[i].channel,
          if (_audio[i].bitrate > 0) 'demux-bitrate': _audio[i].bitrate,
          'selected': i == _audioIndex,
        },
      for (var i = 0; i < _text.length; i++)
        {'type': 'sub', 'id': 'tv:$i', 'lang': _text[i].language, 'codec': codecOf(_text[i].mimetype), 'selected': _subId == 'tv:$i'},
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

  /// A track's codec by the name mpv gives it, from the type the TV says (`video/x-h265`,
  /// `audio/x-eac3`, `text/x-subrip`...).
  @visibleForTesting
  static String codecOf(String mimetype) {
    var t = mimetype.toLowerCase().trim();
    final slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(slash + 1);
    if (t.startsWith('x-')) t = t.substring(2);
    return switch (t) {
      'h265' || 'hevc' => 'hevc',
      'h264' || 'avc' => 'h264',
      'vp9' || 'vp8' || 'av1' => t,
      'eac3' || 'e-ac3' || 'ec3' => 'eac3',
      'ac3' => 'ac3',
      'aac' || 'mp4a' || 'mpeg-4' => 'aac',
      'dts' || 'dtshd' || 'dts-hd' => 'dts',
      'truehd' || 'mlp' => 'truehd',
      'subrip' || 'srt' => 'subrip',
      'ssa' || 'ass' => 'ass',
      'vtt' || 'webvtt' => 'webvtt',
      'pgs' || 'hdmv-pgs' || 'pgssub' => 'hdmv_pgs_subtitle',
      'vobsub' || 'dvdsub' || 'dvd' => 'dvd_subtitle',
      _ => t,
    };
  }

  /// Something the TV's player said went wrong. It says a lot it gets over by itself: a seek it
  /// could not make where it was asked, a track it cannot read. Ending the film on every one of
  /// them left "Playback stopped" on screen over a film that played on, and the subtitles
  /// stopped with it (a Samsung tester, 2026-11-27: "The stream still works ... but this
  /// playback stopped error stayed"). So: a half of the video the TV plays on without is said
  /// as such; once the film is open, it ends only if the TV's player has really stopped; before
  /// that, it did not play.
  void _onError(int source, Object error) {
    if (disposed || source != _sources) return;
    final code = error is PlatformException ? error.code : '';
    final message = error is PlatformException ? (error.message ?? '') : error.toString();
    appLogger.w('[Tizen] player error $code $message');
    final what = errorNote(message);
    switch (partGone(message)) {
      case 'subtitle':
        // (the line is in the log; the film goes on, without that subtitle)
        logController.add(PlayerLog(level: PlayerLogLevel.warn, prefix: 'tv', text: what));
        return;
      case 'audio' || 'video':
        // (the player page says it: no sound, or no picture, and what to do)
        logController.add(PlayerLog(level: PlayerLogLevel.error, prefix: 'tv-part', text: what));
        return;
    }
    if (_loaded && _id != null) {
      unawaited(_endIfStopped(source, what));
      return;
    }
    _end(source, what);
  }

  /// The film ends with [what] on screen.
  void _end(int source, String what) {
    if (disposed || source != _sources) return;
    _clockPause();
    logController.add(PlayerLog(level: PlayerLogLevel.error, prefix: 'tv', text: what));
    handlePlayerEvent('end-file', {'reason': 'error', 'message': what, 'sourceId': source});
  }

  /// After a fault with a film open: looks at the TV's player for a few seconds, and ends the
  /// film only if it has stopped. The TV gives a position only while it plays or is paused, so
  /// a position that moves (or one that is there at all while paused) means it carries on.
  Future<void> _endIfStopped(int source, String what) async {
    final id = _id;
    int? last;
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (disposed || source != _sources || id == null || id != _id) return;
      final at = (await _quiet(() => _tv.getPosition(id)))?.inMilliseconds ?? 0;
      if (disposed || source != _sources || id != _id) return;
      if (at <= 0) {
        // (stopped; a film that had not started yet is given its few seconds to)
        if (_started) break;
        continue;
      }
      if (!_wantPlay || (last != null && at > last)) {
        appLogger.i('[Tizen] played on after: $what');
        logController.add(PlayerLog(level: PlayerLogLevel.warn, prefix: 'tv', text: '$what · it played on'));
        _tick(at);
        if (_wantPlay) _clockRun();
        handlePropertyChange('paused-for-cache', false);
        return;
      }
      last = at;
    }
    _end(source, what);
  }

  /// Which half of the video the TV plays on without, by its own words: 'audio', 'video' or
  /// 'subtitle'; null for a fault that is not one of those.
  @visibleForTesting
  static String? partGone(String message) {
    final m = message.toLowerCase();
    if (m.contains('not supported subtitle')) return 'subtitle';
    if (m.contains('not supported audio codec')) return 'audio';
    if (m.contains('not supported video codec')) return 'video';
    return null;
  }

  /// A fault of the TV's player in words: what the screen and the report card show.
  ///
  /// The TV says some in its media framework's own terms, a JSON text whose `detail_info` is a
  /// GStreamer line ("…gstbasesrc.c(3248): gst_base_src_loop (): /GstPlayBin:…/GstSoupHTTPSrc:
  /// source:\nstreaming stopped, reason error (-5)"). Of that, what it says happened and in
  /// which part of the player is kept: the rest was a file name and a line number, cut off on
  /// screen (a Samsung tester's photo, 2026-11-27).
  @visibleForTesting
  static String errorNote(String message) {
    var said = message.replaceFirst(RegExp(r'^Error:\s*'), '').trim();
    final framework = gstreamerLine(said);
    if (framework != null) said = framework;
    final m = said.toLowerCase();
    final kind = m.contains('not supported file') || m.contains('file format not supported')
        ? "The TV can't read this file"
        : m.contains('not supported audio')
        ? "The TV can't play this sound"
        : m.contains('not supported video')
        ? "The TV can't play this picture"
        : m.contains('subtitle')
        ? "The TV can't read this subtitle"
        : m.contains('not-negotiated') || m.contains('not-linked') || m.contains('not supported media format')
        ? "The TV can't read this stream"
        : m.contains('forbidden') || m.contains('403') || m.contains('not found') || m.contains('404') || (m.contains('reason error') && m.contains('httpsrc'))
        ? "The TV couldn't fetch the video"
        : m.contains('connection') || m.contains('network') || m.contains('timed out') || m.contains('timeout')
        ? "The TV couldn't reach the video"
        : m.contains('no such file')
        ? "The TV couldn't find the video"
        : "The TV couldn't play this";
    return said.isEmpty ? kind : '$kind ($said)';
  }

  /// What a GStreamer error the TV hands over says, shortened: its last line ("streaming
  /// stopped, reason not-negotiated (-4)") and the part of the player it came from
  /// ("GstSoupHTTPSrc"). Null when [said] is not one.
  @visibleForTesting
  static String? gstreamerLine(String said) {
    String? detail;
    if (said.startsWith('{')) {
      try {
        final j = jsonDecode(said);
        if (j is Map) {
          final d = j['detail_info'] ?? j['detail'] ?? j['message'];
          if (d is String && d.trim().isNotEmpty) detail = d;
        }
      } catch (_) {
        // (cut short: the field is read as far as it goes)
        detail = RegExp(r'"detail_info"\s*:\s*"((?:[^"\\]|\\.)*)').firstMatch(said)?.group(1)?.replaceAll(r'\n', '\n');
      }
    } else if (said.contains('.c(') && said.contains('/Gst')) {
      detail = said;
    }
    if (detail == null) return null;
    final lines = detail.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    // the part of the player: the last element named in the path ("…/GstSoupHTTPSrc:source:")
    final element = RegExp(r'/Gst(\w+):[\w-]+(?::|$)').allMatches(detail).map((m) => 'Gst${m[1]}').lastOrNull;
    // what happened: the last line, after that path if it is on the same line
    var what = lines.last;
    final path = RegExp(r'/Gst\w+:[\w-]+:\s*').allMatches(what).lastOrNull;
    if (path != null && path.end < what.length) {
      what = what.substring(path.end);
    } else if (what.contains('.c(')) {
      what = what.split('): ').last;
    }
    what = what.trim();
    if (what.isEmpty) return element;
    return element == null || what.contains(element) ? what : '$what, in $element';
  }

  // ── the app going away and coming back ──

  /// Gone to the background: the TV's player is put away where it is, as Samsung's own widget
  /// does (the TV wants its decoder back for whatever comes to the front).
  Future<void> _appPaused() async {
    final id = _id;
    if (id == null || !_loaded || _suspended) return;
    _suspended = true;
    _clockPause();
    await _quiet(() => _tv.suspend(id));
  }

  /// Back in front: the player is brought back where it was, or opened again there.
  Future<void> _appResumed() async {
    final id = _id;
    if (id == null || !_suspended) return;
    _suspended = false;
    _polledMs = null;
    try {
      await _tv.restore(id);
    } catch (e) {
      appLogger.w('[Tizen] not restored, opened again: $e');
      await _openAgain();
      return;
    }
    // (playing again once it says it is back: see [_onRestored])
    if (_wantPlay) await _quiet(() => _tv.play(id));
  }

  void _onRestored() {
    final id = _id;
    if (id != null && _wantPlay) unawaited(_quiet(() => _tv.play(id)));
  }

  /// Opens what was playing again, where it was.
  Future<void> _openAgain() async {
    final media = _media;
    if (media == null) return;
    final at = currentPosition;
    await _quiet(() => open(Media(media.uri, headers: media.headers, start: at), play: _wantPlay, isLive: _live, timelineDuration: configuredTimelineDuration, timelineOffset: timelineOffset));
  }

  // ── position ──

  void _tick(int ms) {
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

  int? _polledMs; // the TV's position at the last ask (null: none since the open or a seek)
  int _stillPolls = 0; // asks in a row it did not move
  bool _polling = false;

  /// The TV says nothing of the position by itself: it is asked, twice a second, for as long as
  /// a film is open, playing or not. What it answers is the film's clock, whatever it did or did
  /// not say about playing and loading: subtitles follow the TV's own position. (They followed
  /// its events, and around a seek the TV leaves some out: the clock stood still, or ran on
  /// while the TV loaded, and a Samsung tester's subtitles "went out of sync entirely" after
  /// fast-forwarding, 2026-11-27.)
  void _watchPosition() {
    _positionPoll ??= Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(_pollPosition()));
  }

  Future<void> _pollPosition() async {
    final id = _id;
    if (disposed || id == null || !_loaded || _suspended || _seeking > 0 || _polling) return;
    _polling = true;
    try {
      final at = await _quiet(() => _tv.getPosition(id));
      if (at == null || disposed || id != _id || _seeking > 0) return;
      final ms = at.inMilliseconds;
      // (it says 0 while it is neither playing nor paused: not a position)
      if (ms <= 0) return;
      final last = _polledMs;
      _polledMs = ms;
      if (last != null && ms > last) {
        // moving: it plays, whatever was said, and nothing is loading
        _stillPolls = 0;
        if (_wantPlay && !_ended) _clockRun();
        if (state.buffering) handlePropertyChange('paused-for-cache', false);
      } else if (last != null && ++_stillPolls >= 2) {
        // a second without moving: it stopped (to load, or paused), and the lines stop with it
        _clockPause();
      }
      _tick(ms);
    } finally {
      _polling = false;
    }
  }

  // ── subtitles ──

  /// Shows the line for the film's time now (a file's, or the TV's last one) and wakes again
  /// when that next changes.
  void _showLine() {
    if (_subId.startsWith('file:')) {
      vyseShowSubPicture(null);
      if (!_subVisible || _cues.isEmpty) {
        _say('');
        return;
      }
      _say(_cues.textAt(_clockNowMs() / 1000 - _subDelay));
    } else if (_subId.startsWith('tv:')) {
      final line = _tvLine;
      final now = _clockNowMs();
      final on = _subVisible && line != null && now >= line.from && (line.until == null || now < line.until!);
      _say(on ? line.text : '');
      vyseShowSubPicture(on ? line.picture : null);
    } else {
      _say('');
      vyseShowSubPicture(null);
      return;
    }
    _armSubTimer();
  }

  void _armSubTimer() {
    _subTimer?.cancel();
    _subTimer = null;
    if (!_clock.isRunning || !_subVisible) return;
    final double wait; // seconds of film
    if (_subId.startsWith('file:') && !_cues.isEmpty) {
      final now = _clockNowMs() / 1000 - _subDelay;
      final next = _cues.nextChangeAfter(now);
      if (next == null) return;
      wait = next - now;
    } else if (_subId.startsWith('tv:') && _tvLine != null) {
      final line = _tvLine!, now = _clockNowMs();
      final next = now < line.from ? line.from : line.until;
      if (next == null || next <= now) return;
      wait = (next - now) / 1000;
    } else {
      return;
    }
    final ms = (wait * 1000 / (_rate <= 0 ? 1 : _rate)).ceil().clamp(10, 60000).toInt();
    _subTimer = Timer(Duration(milliseconds: ms), _showLine);
  }

  void _say(String text) => vyseHandleProperty('sub-text', text);

  /// A line of a subtitle track inside the video, as the TV hands it over: shown from now (or
  /// later, by the subtitle delay) for as long as the TV says.
  void _onTvSubtitle(avplay.SubtitlesInfo? info) {
    if (info == null || !_subId.startsWith('tv:')) return;
    final now = _clockNowMs();
    final from = now + (_subDelay > 0 ? (_subDelay * 1000).round() : 0);
    final ms = info.textDuration ?? 0;
    // (a line with no length stays until the next, but not for ever)
    final until = from + (ms > 0 ? ms : 8000);
    final picture = info.pictureInfo;
    final bytes = picture?['picture'];
    if (bytes is Uint8List && bytes.isNotEmpty) {
      final w = picture?['pictureWidth'], h = picture?['pictureHeight'];
      _tvLine = _TvLine(
        text: '',
        picture: SubPicture(bytes, width: w is num ? w.toDouble() : 0, height: h is num ? h.toDouble() : 0),
        from: from,
        until: until,
      );
    } else {
      _tvLine = _TvLine(text: tvSubtitleText(info.textsInfo), from: from, until: until);
    }
    _showLine();
  }

  /// The text of a line as the TV hands it over (one entry per row), as plain lines: the
  /// subtitle file's own markup (`<i>`, `{\an8}`, `\N`) taken out.
  @visibleForTesting
  static String tvSubtitleText(List<dynamic>? rows) {
    final out = <String>[];
    for (final r in rows ?? const []) {
      final said = r is Map ? r['text'] : r;
      if (said is! String) continue;
      final plain = said
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');
      for (final line in plain.split('\n')) {
        if (line.trim().isNotEmpty) out.add(line.trim());
      }
    }
    return out.join('\n');
  }

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
      appLogger.w('[Tizen] subtitle file not read: $e');
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
    _tvLine = null;
    final player = _id;
    if (_loaded && player != null && id.startsWith('tv:')) {
      final index = int.tryParse(id.substring(3)) ?? -1;
      if (index >= 0 && index < _text.length) unawaited(_quiet(() => _tv.setTrackSelection(player, _text[index])));
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
    final id = _id;
    if (_loaded && id != null) {
      final ok = await _quiet(() => _tv.setTrackSelection(id, _audio[index]));
      if (ok != true) {
        appLogger.w('[Tizen] the TV did not switch to audio track ${index + 1}');
        return;
      }
    }
    _audioIndex = index;
    _publishTracks();
  }

  // ── the controls ──

  @override
  Future<void> play() async {
    _wantPlay = true;
    final id = _id;
    // (still opening: it plays once loaded, as [_wantPlay] now says)
    if (id == null) return;
    if (_ended) {
      // (played out: Play starts it over, as mpv's keep-open does)
      _ended = false;
      handlePropertyChange('eof-reached', false);
      await seek(timelineOffset);
    }
    if (!_loaded) return;
    try {
      await _tv.play(id);
    } catch (e) {
      // (the TV took its decoder for something else meanwhile: opened again where it was)
      appLogger.w('[Tizen] play refused, opened again: $e');
      await _openAgain();
    }
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    final id = _id;
    if (_loaded && id != null) {
      await _quiet(() => _tv.pause(id));
    }
    _clockPause();
    handlePropertyChange('pause', true);
  }

  @override
  Future<void> stop() async {
    _sources++;
    _say('');
    vyseShowSubPicture(null);
    await _close();
    setSeekable(false);
    handlePropertyChange('pause', true);
  }

  int _seeking = 0;

  /// A seek in the TV's player. It seeks at normal speed only, so a film playing faster or
  /// slower is put back to normal speed for it.
  Future<void> _seekTv(int id, int ms) async {
    _seeking++;
    try {
      final fast = _rate != 1.0;
      if (fast) await _quiet(() => _tv.setPlaybackSpeed(id, 1.0));
      await _tv.seekTo(id, Duration(milliseconds: ms)).timeout(const Duration(seconds: 30));
      if (fast) await _quiet(() => _tv.setPlaybackSpeed(id, _rate));
    } finally {
      _seeking--;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final id = _id;
    if (!_loaded || id == null) return;
    final target = sourcePositionFor(position).inMilliseconds;
    await runSeek(position, () async {
      _tvLine = null;
      _polledMs = null;
      try {
        await _seekTv(id, target);
      } catch (e) {
        // (the TV gave the seek up or refused it: where it really is, the next ask says)
        appLogger.w('[Tizen] seek to $target ms: $e');
      }
      if (id != _id) return;
      _polledMs = null;
      _stillPolls = 0;
      _ended = false;
      _clockMs = target;
      _clock.reset();
      _showLine();
      handlePlayerEvent('playback-restart', {'sourceId': _sources, 'positionSeconds': target / 1000});
    });
  }

  /// The TV has one volume, and it is the remote's. Kept so the interface's own number moves.
  @override
  Future<void> setVolume(double volume) async {
    if (!disposed) setVolumeState(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    if (disposed || rate <= 0) return;
    if (_clock.isRunning) {
      _clockMs = _clockNowMs();
      _clock.reset();
    }
    final id = _id;
    if (_loaded && id != null) {
      try {
        await _tv.setPlaybackSpeed(id, rate);
      } catch (e) {
        // (the TV refuses some speeds, and any in a film's last seconds)
        appLogger.w('[Tizen] speed $rate refused: $e');
        return;
      }
    }
    _rate = rate;
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
        _showLine();
      case 'sub-visibility':
        _subVisible = value != 'no';
        _showLine();
      case 'video-aspect-override':
        final forced = _aspectOf(value);
        if (forced != _forcedAspect) {
          _forcedAspect = forced;
          await _placePicture();
        }
      default:
        // an mpv property: nothing here to set
        break;
    }
  }

  @override
  Future<String?> getProperty(String name) async {
    if (disposed) return null;
    return switch (name) {
      'pause' => state.playing ? 'no' : 'yes',
      'volume' => state.volume.toString(),
      'speed' => state.rate.toString(),
      'time-pos' => (state.position.inMilliseconds / 1000.0).toString(),
      'duration' => (state.duration.inMilliseconds / 1000.0).toString(),
      'seekable' => state.seekable ? 'yes' : 'no',
      'width' || 'dwidth' => _videoW > 0 ? '$_videoW' : null,
      'height' || 'dheight' => _videoH > 0 ? '$_videoH' : null,
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
    final v = _video;
    final a = _audioIndex < _audio.length ? _audio[_audioIndex] : null;
    return {
      'engine': 'tizen',
      if (_videoW > 0) 'videoWidth': _videoW,
      if (_videoH > 0) 'videoHeight': _videoH,
      if (v != null) 'videoCodec': codecOf(v.mimetype),
      if (v != null && v.bitrate > 0) 'videoBitrate': v.bitrate,
      if (a != null) 'audioCodec': codecOf(a.mimetype),
      if (a != null && a.channel > 0) 'audioChannels': a.channel,
      if (a != null && a.bitrate > 0) 'audioBitrate': a.bitrate,
      'durationMs': _durationMs,
    };
  }

  /// Nothing to do: the picture goes with the page that shows it, and the sound stops with the
  /// pause the app does itself.
  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async => true;

  // ── where the picture sits ──

  /// The video's place in the interface, in the screen's pixels: what the TV's player takes.
  @override
  Future<void> setVideoRect({required int left, required int top, required int right, required int bottom, required double devicePixelRatio}) async {
    if (disposed || audioOnly) return;
    _rect = (x: left, y: top, w: right - left, h: bottom - top);
    await _placePicture();
  }

  // The picture's shape (the player's More > Picture).
  int _fit = 0; // 0 the whole picture, 1 cropped to cover the box, 2 pulled to the box
  double? _forcedAspect; // shown as 16:9, 4:3 or 21:9 whatever the file says; null: its own shape
  double _zoom = 1.0;

  @override
  Future<void> setBoxFitMode(int mode) async {
    if (disposed || mode == _fit) return;
    _fit = mode;
    await _placePicture();
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    if (disposed || scale <= 0 || scale == _zoom) return;
    _zoom = scale;
    await _placePicture();
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

  /// Where the TV's picture goes, in the screen's pixels.
  ///
  /// The TV pulls the whole picture to the rectangle it is given, whatever their shapes, so
  /// the black bars are made here: the picture is laid in the box at its own shape ([fit] 0,
  /// or the shape [forcedAspect] says), made smaller by a [zoom] under 1, or pulled to the box
  /// ([fit] 2). Cropped to cover the box ([fit] 1, or a [zoom] over 1) the TV cannot be told a
  /// part of the picture: on the whole screen ([wholeScreen]) it is asked to crop the picture
  /// to the screen itself (`crop`), and in a smaller box the whole picture is shown instead.
  @visibleForTesting
  static ({int x, int y, int w, int h, bool crop}) pictureRect({
    required ({int x, int y, int w, int h}) box,
    required int videoW,
    required int videoH,
    int fit = 0,
    double? forcedAspect,
    double zoom = 1,
    bool wholeScreen = true,
  }) {
    final z = zoom > 0 && zoom < 1 ? zoom : 1.0;
    ({int x, int y, int w, int h, bool crop}) centred(double w, double h) {
      final dw = w.round().clamp(1, box.w < 1 ? 1 : box.w).toInt(), dh = h.round().clamp(1, box.h < 1 ? 1 : box.h).toInt();
      return (x: box.x + (box.w - dw) ~/ 2, y: box.y + (box.h - dh) ~/ 2, w: dw, h: dh, crop: false);
    }

    if (fit == 2) return centred(box.w * z, box.h * z);
    if ((fit == 1 || zoom > 1) && wholeScreen) return (x: box.x, y: box.y, w: box.w, h: box.h, crop: true);
    final aspect = forcedAspect ?? (videoW > 0 && videoH > 0 ? videoW / videoH : null);
    if (aspect == null || box.w <= 0 || box.h <= 0) return (x: box.x, y: box.y, w: box.w, h: box.h, crop: false);
    final wider = box.w / box.h > aspect; // the box is wider than the picture
    final w = wider ? box.h * aspect : box.w.toDouble();
    final h = wider ? box.h.toDouble() : box.w / aspect;
    return centred(w * z, h * z);
  }

  Future<void> _placePicture() async {
    final id = _id, rect = _rect;
    if (id == null || rect == null || audioOnly || rect.w <= 0 || rect.h <= 0) return;
    var p = pictureRect(box: rect, videoW: _videoW, videoH: _videoH, fit: _fit, forcedAspect: _forcedAspect, zoom: _zoom, wholeScreen: _coversScreen(rect));
    if (p.crop) {
      if (await _setMode(id, avplay.DisplayMode.croppedFull)) {
        await _quiet(() => _tv.setDisplayGeometry(id, p.x, p.y, p.w, p.h));
        return;
      }
      // (the TV would not crop: the whole picture, then)
      p = pictureRect(box: rect, videoW: _videoW, videoH: _videoH, forcedAspect: _forcedAspect);
    }
    await _setMode(id, avplay.DisplayMode.dstRoi);
    if (id != _id) return;
    await _quiet(() => _tv.setDisplayGeometry(id, p.x, p.y, p.w, p.h));
  }

  /// The mode the TV draws the picture in. Its own, after it is made, is the rectangle it is
  /// given (dstRoi); a crop to the screen is the other one used.
  Future<bool> _setMode(int id, avplay.DisplayMode mode) async {
    if (_mode == mode) return true;
    if (_mode == null && mode == avplay.DisplayMode.dstRoi) {
      _mode = mode; // (what Samsung's player starts in)
      return true;
    }
    final ok = await _quiet(() => _tv.setDisplayMode(id, mode)) ?? false;
    if (ok && id == _id) _mode = mode;
    return ok;
  }

  /// Whether the box is the whole screen (give or take a pixel's rounding).
  static bool _coversScreen(({int x, int y, int w, int h}) r) {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return false;
      final size = views.first.physicalSize;
      return r.x <= 1 && r.y <= 1 && r.w >= size.width - 2 && r.h >= size.height - 2;
    } catch (_) {
      return false; // (no binding: a test)
    }
  }

  static Future<T?> _quiet<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } catch (e) {
      appLogger.d('[Tizen] $e');
      return null;
    }
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (disposed) return;
    if (!audioOnly) TvMemory.filmClosed();
    _sources++;
    _lifecycle?.detach();
    _lifecycle = null;
    await _close();
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
  }
}

/// Tells the player when the app goes to the background and comes back.
class _Lifecycle with WidgetsBindingObserver {
  _Lifecycle(this.player);
  final PlayerTizen player;

  void attach() {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // (no binding: a test that drives the player without one)
    }
  }

  void detach() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(player._appPaused());
    if (state == AppLifecycleState.resumed) unawaited(player._appResumed());
  }
}

class _TvLine {
  const _TvLine({required this.text, this.picture, required this.from, this.until});
  final String text;
  final SubPicture? picture;
  final int from; // film time (source ms)
  final int? until;
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
