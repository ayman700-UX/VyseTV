import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/device_channel.dart';
import '../../core/platform/webos.dart';
import '../../core/platform/tizen_tv.dart';

/// One line of a report: what it is, and what it says.
typedef ReportFact = ({String label, String value});

/// A titled group of lines ("VIDEO": codec, resolution, bitrate).
typedef ReportSection = ({String title, List<ReportFact> facts});

/// What one playback was and how it went: the player's Stream info, and the report card a
/// tester photographs when something won't play.
///
/// It is made when a video is opened and filled in as things become known: what the player
/// says about the picture and the sound, what the TV can do with HDR and Dolby Vision, how long
/// the first frame took, and how it ended (played, handed from Media3 to mpv and what for, or
/// did not play). The newest one is kept after the player closes ([last]), so a film that never
/// started can still be reported from Settings.
///
/// It never holds an address. A link carries tokens, and an IPTV link its portal's sign-in:
/// only the host is kept ([hostOf]), and anything the engines say is cleaned of addresses
/// before it is stored ([scrub]).
class PlaybackReport {
  PlaybackReport._(this._f);

  /// A report for a video being opened now.
  factory PlaybackReport.begin({
    required String title,
    required String source,
    String link = '',
    required String url,
    required String engine,
    DateTime? when,
  }) => PlaybackReport._({
    'when': (when ?? DateTime.now()).toIso8601String(),
    'title': title,
    'source': source,
    'link': link,
    'host': hostOf(url),
    'engine': engine,
  });

  factory PlaybackReport.fromJson(Map<String, Object?> json) => PlaybackReport._(Map<String, Object?>.of(json));

  final Map<String, Object?> _f;

  Map<String, Object?> toJson() => _f;

  // ── Filling it in ──

  /// A copy with [changes] laid over it (a null value takes that fact away).
  PlaybackReport _with(Map<String, Object?> changes) {
    final next = Map<String, Object?>.of(_f);
    changes.forEach((k, v) => v == null ? next.remove(k) : next[k] = v);
    return PlaybackReport._(next);
  }

  /// What the device can do (the device channel's `getPlaybackCapabilities`: its model, what its
  /// display takes, its Dolby Vision decoders, the profile 7 conversion). Android only.
  PlaybackReport withDevice(Map<String, Object?> caps) => caps.isEmpty ? this : _with({'caps': _clean(caps)});

  /// What Media3 says about the video (its `getStats`), live or as it gave the video up.
  PlaybackReport withMedia3(Map<String, Object?> stats) => stats.isEmpty ? this : _with({'exo': _clean(stats)});

  /// What mpv says about the video (its properties, by their own names).
  PlaybackReport withMpv(Map<String, Object?> facts) => facts.isEmpty ? this : _with({'mpv': _clean(facts)});

  /// What an LG TV's player says about the video it is showing (its stats: the picture's size,
  /// rate and HDR type, the codecs of the tracks in use).
  PlaybackReport withTv(Map<String, Object?> facts) => facts.isEmpty ? this : _with({'tv': _clean(facts)});

  /// The audio track in use, as the player's own track list has it (what mpv or Media3 say
  /// about the decoded sound comes first when they say it).
  PlaybackReport withAudio({String? language, String? codec, int? channels, int? sampleRate}) => _with({
    'audio': {'language': ?language, 'codec': ?codec, 'channels': ?channels, 'sampleRate': ?sampleRate},
  });

  /// The subtitle showing: its name, its language, and where it is from ("Inside the file",
  /// "OpenSubtitles", an addon's name). All null: subtitles are off.
  PlaybackReport withSubtitle({String? name, String? language, String? origin}) => _with({
    'subtitle': name == null && language == null ? null : {'name': ?name, 'language': ?language, 'origin': ?origin},
  });

  /// How the sound settings stand: Passthrough on or off, and whether levelling or Stereo keep
  /// it from being used. They say why a Dolby track was decoded here and not sent on.
  PlaybackReport withSoundSettings({required bool passthrough, bool decodeForced = false}) {
    final now = {'passthrough': passthrough, 'forced': decodeForced};
    return mapEquals(_m('sound'), now) ? this : _with({'sound': now});
  }

  /// A first frame showed, [ms] after the open (the app's clock; Media3's own is used when it
  /// has one). After a hand-over it is mpv's, and says mpv played what Media3 gave up.
  PlaybackReport withFirstFrame(int ms) {
    if (handedOver) return _f['mpvFrameMs'] != null ? this : _with({'mpvFrameMs': ms, if (_f['firstFrameMs'] == null) 'firstFrameMs': ms});
    return _f['firstFrameMs'] != null ? this : _with({'firstFrameMs': ms});
  }

  /// It stopped to load again, once more.
  PlaybackReport withRebuffer() => _with({'rebuffers': ((_f['rebuffers'] as num?)?.toInt() ?? 0) + 1});

  /// Media3 handed the video to mpv: what for ([kind]: audio, video, stream, format, stuck,
  /// error), in the plugin's words, and how long after the open.
  PlaybackReport withHandOver({required String kind, String reason = '', String detail = '', int? afterMs}) => _with({
    'handOver': {'kind': kind, 'reason': scrub(reason), 'detail': scrub(detail), 'afterMs': ?afterMs},
  });

  /// It did not play, and why (the player's error, or the app's own words for it).
  PlaybackReport withFailure(String why) => _with({'failure': scrub(why)});

  /// What the player asked of the app's relay on this device and what went wrong there
  /// (RelayLog.line), for a video opened through one: whether a TV's player reached it at all.
  PlaybackReport withRelay(String line) => _with({'relay': scrub(line)});

  /// The player gave up one half of the video and played on with the other: [part] is 'audio'
  /// or 'video', [line] the engine's own words as it did.
  PlaybackReport withDropped(String part, String line) => _with({'dropped': {'part': part, 'line': scrub(line)}});

  /// A Samsung TV's video went to the TV's basic media player because its streaming player
  /// didn't start it ([why]).
  PlaybackReport withTvBasicPlayer(String why) => _with({'tvBasic': scrub(why)});

  /// The player closed, [afterMs] after the open.
  PlaybackReport closed(int afterMs) => _with({'closedAfterMs': afterMs});

  // ── Reading it ──

  String _s(String key) => (_f[key] as String?) ?? '';
  Map<String, Object?> _m(String key) => switch (_f[key]) {
    final Map<Object?, Object?> m => m.cast<String, Object?>(),
    _ => const {},
  };

  DateTime get when => DateTime.tryParse(_s('when')) ?? DateTime.fromMillisecondsSinceEpoch(0);
  String get title => _s('title');
  String get source => _s('source');
  String get host => _s('host');
  bool get onMedia3 => _s('engine') == 'media3';

  /// Played by an LG TV's own player (webOS).
  bool get onTv => _s('engine') == 'webos' || _s('engine') == 'tizen';

  /// The engine that played it, by name.
  String get _engineName => onTv ? "the TV's player" : (onMedia3 ? 'Media3' : 'mpv');

  /// What the engine said about the video under mpv's names for it: mpv's own words, or on an
  /// LG TV what its player said, renamed so every line below reads both the same way. (The
  /// TV's HDR type has no mpv name: it is kept as `tvHdr`, see [_hdr].)
  Map<String, Object?> get _mpvFacts {
    if (!onTv) return _m('mpv');
    final tv = _m('tv');
    if (tv.isEmpty) return const {};
    return {
      'video-params/w': tv['videoWidth'],
      'video-params/h': tv['videoHeight'],
      'container-fps': tv['videoFps'],
      'video-bitrate': tv['videoBitrate'],
      'video-codec': tv['videoCodec'],
      'audio-codec-name': tv['audioCodec'],
      'current-tracks/audio/demux-channel-count': tv['audioChannels'],
      'current-tracks/audio/demux-samplerate': tv['audioSampleRate'],
      'tvHdr': tv['hdrType'],
      // (the stream's own transfer function, as H.265 numbers it: 16 is PQ, 18 is HLG)
      'video-params/gamma': switch (tv['transfer']) {
        16 => 'pq',
        18 => 'hlg',
        final num _ => 'sdr',
        _ => null,
      },
      'tvImmersive': tv['audioImmersive'],
      'hwdec-current': "The TV's own",
    }..removeWhere((_, v) => v == null);
  }
  bool get handedOver => _m('handOver').isNotEmpty;
  int? get firstFrameMs => (_m('exo')['firstFrameMs'] as num?)?.toInt() ?? (_f['firstFrameMs'] as num?)?.toInt();
  bool get started => firstFrameMs != null;
  bool get failed => _s('failure').isNotEmpty;

  /// One line for a list: what it was and how it went ("The Body · handed to mpv").
  String get summary => [if (title.isNotEmpty) title, _outcomeShort].join(' · ');

  String get _outcomeShort {
    if (failed) return started ? 'stopped with an error' : 'did not play';
    if (handedOver) return _f['mpvFrameMs'] != null ? 'played on mpv, after Media3' : 'handed to mpv';
    if (started) return 'played on $_engineName';
    return _f['closedAfterMs'] == null ? 'starting' : 'closed before it started';
  }

  /// The engine line: Media3, mpv, or mpv after a hand-over and what that was for.
  String get engineLine {
    // (a Media3 player that has given one video to mpv plays the ones after it on mpv too)
    if (_s('engine') == 'mpv-kept') return 'mpv, since Media3 gave an earlier video up';
    if (onTv && _s('tvBasic').isNotEmpty) return "The TV's basic player (${_s('tvBasic')})";
    if (onTv) return "The TV's own player";
    if (!onMedia3) return 'mpv';
    if (!handedOver) return 'Media3';
    return 'mpv, after Media3 ${_handOverWords(_m('handOver')['kind'] as String? ?? '')}';
  }

  static String _handOverWords(String kind) => switch (kind) {
    'audio' => 'could not play the sound',
    'video' => 'could not play the picture',
    'stream' => 'lost the stream',
    'format' => 'could not read the file',
    'stuck' => 'got stuck',
    _ => 'could not play it',
  };

  /// Whether mpv has said anything about the video yet (it says nothing until it has it open).
  bool get _mpvKnows => _m('mpv')['video-params/w'] != null || _m('mpv')['audio-codec-name'] != null;

  /// Stream info: the source, the engine, the picture, the sound and the subtitle.
  List<ReportSection> get stream {
    // (after a hand-over the video is mpv's to describe, once it has it open)
    final exo = handedOver && _mpvKnows ? const <String, Object?>{} : _m('exo'), mpv = _mpvFacts;
    final link = _s('link');
    final subtitle = _m('subtitle');
    // (after a hand-over, until mpv has the video open, the decoder Media3 used is not what plays it)
    final decoder = handedOver && !_mpvKnows ? null : _str(exo['videoDecoderName']) ?? _mpvDecoder(mpv);
    return [
      (title: 'Source', facts: _facts([
        ('Source', source),
        ('Link', link),
        ('Server', host),
      ])),
      (title: 'Player engine', facts: _facts([
        ('Engine', engineLine),
        // (FFmpeg's decoder in the app, Media3's software path: "ffmpeg<version>-<codec>")
        ('Video decoder', decoder == null ? '' : (decoder.startsWith('ffmpeg') ? '$decoder (in the app, software)' : decoder)),
      ])),
      (title: 'Video', facts: _facts([
        ('Codec', _videoCodec(exo, mpv)),
        ('Resolution', _resolution(exo, mpv)),
        ('Bitrate', _bitrate(exo['videoBitrate'] ?? mpv['video-bitrate'])),
        ('Frame rate', _fps(exo['videoFps'] ?? mpv['container-fps'])),
        ('On screen', onScreen),
      ])),
      (title: 'Audio', facts: _facts([
        ('Codec', _audioCodec(exo, mpv)),
        ('Channels', _channels(exo, mpv)),
        ('Sample rate', _sampleRate(exo['audioSampleRate'] ?? mpv['current-tracks/audio/demux-samplerate'] ?? mpv['audio-params/samplerate'] ?? _m('audio')['sampleRate'])),
        ('Language', _str(_m('audio')['language']) ?? ''),
        ('Heard as', heard),
      ])),
      (title: 'Subtitle', facts: subtitle.isEmpty
          ? const [(label: 'Showing', value: 'Off')]
          : _facts([
              ('Name', _str(subtitle['name']) ?? ''),
              ('Language', _str(subtitle['language']) ?? ''),
              ('From', _str(subtitle['origin']) ?? ''),
            ])),
    ];
  }

  /// The report card: where it came from and what the device has, what was decided about
  /// Dolby Vision, and how it went.
  List<ReportSection> get card {
    final caps = _m('caps');
    // (what Media3 knew stays on the card after a hand-over: it is what went wrong there)
    final exo = _m('exo'), mpv = _mpvFacts;
    final display = _list(caps['displayHdr']);
    final decoders = _list(caps['dvDecoders']);
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    final asked = _str(exo['dvConversionDebugMode']) ?? (caps['dvAutoMode'] == null ? null : 'AUTO');
    final inEffect = _str(exo['dvConversionMode']) ?? _str(caps['dvAutoMode']) ?? '';
    final bridge = caps['dvBridgeReady'] as bool?;
    final converting = exo['dvConversionActive'] == true;
    final path = _str(exo['dvPlaybackPath']);
    return [
      (title: 'Source and hardware', facts: _facts([
        ('Source', [source, _s('link')].where((x) => x.isNotEmpty).join(' · ')),
        ('Server', host),
        ('When', _when),
        ('Device', [_str(caps['device']) ?? '', if (_str(caps['android']) != null) 'Android ${caps['android']}', if (_str(caps['webos']) != null) 'webOS ${caps['webos']}', if (_str(caps['tizen']) != null) 'Tizen ${caps['tizen']}'].where((x) => x.isNotEmpty).join(' · ')),
        ('Display', caps.isEmpty ? '' : (display.isEmpty ? 'No HDR' : display.join(', '))),
        ('Dolby Vision decoders', caps.isEmpty ? '' : (decoders.isEmpty ? 'None' : decoders.join('\n'))),
      ])),
      (title: 'Decision', facts: _facts([
        ('Engine', engineLine),
        ('Video decoder', _str(exo['videoDecoderName']) ?? _mpvDecoder(mpv) ?? ''),
        ('Source profile', profile == null ? '' : 'Dolby Vision $profile'),
        ('This video', path == null ? '' : _dvPath(path)),
        // (why, where it is not played as it is: the plugin's own words)
        ('Why', path == null || path.startsWith('Native DV') || path == 'DV P8 passthrough' ? '' : _str(exo['dvPlaybackReason']) ?? ''),
        // (what this TV does with profile 7, whatever is playing: the rule other apps call the DV mode)
        ('Profile 7 videos', asked == null ? '' : (asked.toUpperCase() == 'AUTO' ? 'Auto: ${_dvMode(inEffect)}' : '${_dvMode(asked)}, set by hand')),
        ('Conversion bridge', bridge == null ? '' : (converting ? 'In use' : (bridge ? 'Ready, not in use' : 'Not there'))),
        // (how long Media3 asks a link that sends nothing before it gives the video up)
        ('A quiet link', switch ((exo['networkPatienceMs'] as num?)?.toInt()) {
          null => '',
          0 => "Media3's own four tries, about 40 s",
          final ms => 'Asked again for ${(ms / 1000).round()} s, as mpv is',
        }),
      ])),
      (title: 'Outcome', facts: _facts([
        ('HDR format', _hdr(exo, mpv)),
        ('On screen', onScreen),
        ('Heard as', heard),
        ('First frame', firstFrameMs == null ? '' : '$firstFrameMs ms'),
        ('Rebuffers', started ? '${(exo['rebuffers'] as num?)?.toInt() ?? (_f['rebuffers'] as num?)?.toInt() ?? 0}' : ''),
        ('Result', result),
        ('Left out', switch (_m('dropped')) {
          {'part': 'audio', 'line': final String line} => 'The sound · $line',
          {'part': 'video', 'line': final String line} => 'The picture · $line',
          _ => '',
        }),
        ('What Media3 said', _str(_m('handOver')['detail']) ?? _str(_m('handOver')['reason']) ?? ''),
        ('Relay on this device', _s('relay')),
      ])),
    ];
  }

  // ── What reaches the screen and the speakers ──

  /// The picture as it is shown, where that can be told (an Android device says what its
  /// screen takes): "Dolby Vision", "HDR10, its HDR10 layer", "SDR, mapped by the TV". Empty
  /// until the player has the video, and on devices that do not say what their screen takes.
  String get onScreen => _picture().$1;

  /// The sound as it leaves: "Passed through as Dolby Digital Plus, Atmos inside", "Decoded
  /// here to 5.1". Empty until the player has opened its sound output.
  String get heard => _sound().$1;

  /// A short line for each way the video plays in a lesser form than the stream carries (Dolby
  /// Vision as HDR10, HDR on a screen without it, Atmos decoded), with why: the picture's, then
  /// the sound's. Null when it plays as it is, or when that cannot be told.
  String? get lesser {
    final lines = [?_picture().$2, ?_sound().$2];
    return lines.isEmpty ? null : lines.join('\n');
  }

  (String, String?) _picture() {
    // (after a hand-over the video is mpv's to describe, once it has it open)
    final exo = handedOver && _mpvKnows ? const <String, Object?>{} : _m('exo'), mpv = _mpvFacts, caps = _m('caps');
    final format = _hdr(exo, mpv);
    // (an LG TV's player says what it is showing the picture as; nothing here maps or converts it)
    if (onTv) return (format, null);
    if (format.isEmpty || caps.isEmpty) return ('', null);
    final display = _list(caps['displayHdr']);
    final dvScreen = display.contains('Dolby Vision');
    final noHdr = display.isEmpty;
    if (!format.startsWith('Dolby Vision')) {
      if (format == 'SDR') return ('SDR', null);
      return noHdr ? ('SDR, mapped by the TV', '$format shown as SDR · this screen has no HDR') : (format, null);
    }
    final under = noHdr ? 'SDR, mapped by the TV from its HDR10 layer' : 'HDR10, its HDR10 layer';
    final whyNot = dvScreen ? 'no Dolby Vision decoder here plays it' : 'this screen has no Dolby Vision';
    // mpv says which way it took the video; Media3 which path its decoder choice came to
    if (exo.isEmpty) {
      final gamma = _str(mpv['video-params/gamma']);
      switch (_str(mpv['dvRoute'])) {
        case 'dv-decoder':
          return dvScreen ? ('Dolby Vision', null) : ("Converted by the TV's Dolby Vision decoder", null);
        case 'dv-decoder-p81':
          return ('Dolby Vision, profile 7 converted to 8.1', null);
        case 'reshaped':
          return ('Dolby Vision colours, decoded in software by mpv', 'Dolby Vision is decoded in software here · it may stutter');
        case 'base-layer':
          return gamma == 'pq' || gamma == 'hlg'
              ? (under, 'Dolby Vision shown as ${noHdr ? 'SDR' : 'HDR10'} · $whyNot')
              : ('Its base layer, without Dolby Vision', 'Dolby Vision is not shown · $whyNot');
      }
      return ('', null);
    }
    final path = _str(exo['dvPlaybackPath']);
    if (path == null) return ('', null);
    if (path == 'HDR fallback' || path == 'P7 -> HEVC') return (under, 'Dolby Vision shown as ${noHdr ? 'SDR' : 'HDR10'} · $whyNot');
    if (path == 'P7 -> P8.1') return ('Dolby Vision, profile 7 converted to 8.1', null);
    return dvScreen ? ('Dolby Vision', null) : ("Converted by the TV's Dolby Vision decoder", null);
  }

  // Android's numbers for what a sound output is given (AudioFormat.ENCODING_*).
  static const _pcmOut = {2, 3, 4, 21, 22, 0x10000000, 0x50000000, 0x60000000};
  static const _encodedOut = {
    5: 'Dolby Digital',
    6: 'Dolby Digital Plus',
    18: 'Dolby Digital Plus with Atmos',
    7: 'DTS',
    8: 'DTS-HD',
    14: 'TrueHD',
    17: 'AC-4',
    30: 'DTS:X',
  };

  static String _layout(int? channels) => switch (channels) {
    null || 0 => 'PCM',
    1 => 'mono',
    2 => 'stereo',
    6 => '5.1',
    8 => '7.1',
    final n => '$n channels',
  };

  (String, String?) _sound() {
    final exo = handedOver && _mpvKnows ? const <String, Object?>{} : _m('exo'), mpv = _mpvFacts;
    if (onTv) {
      // The TV decodes the sound or sends it on as its own sound settings say, and does not say
      // which. What it does say is whether the track is an immersive one (Atmos).
      if (mpv.isEmpty) return ('', null);
      final immersive = _str(mpv['tvImmersive']);
      final atmos = immersive != null && !const {'none', 'off', 'false', '0'}.contains(immersive.toLowerCase());
      return ("As the TV's sound settings send it${atmos ? ' · immersive ($immersive)' : ''}", null);
    }
    final settings = _m('sound');
    // (why a Dolby track is decoded here: the setting first, then the TV's own answer)
    final whyDecoded = settings['passthrough'] == false
        ? 'Passthrough is off'
        : (settings['forced'] == true ? 'levelling or Stereo is on' : "the TV's sound output does not take it");
    final atmos = exo['audioMimeType'] == 'audio/eac3-joc' || (_str(mpv['current-tracks/audio/codec-profile'])?.contains('Atmos') ?? false);
    final out = (exo['audioOutputEncoding'] as num?)?.toInt();
    if (out != null) {
      if (_pcmOut.contains(out)) {
        final to = _layout((exo['audioOutputChannels'] as num?)?.toInt());
        return ('Decoded here to $to', atmos ? 'Atmos decoded to $to · $whyDecoded' : null);
      }
      // (a TrueHD or DTS-HD stream in its carrier is still that stream)
      final name = out == 13 ? _audioCodec(exo, mpv) : (out == 6 && atmos ? 'Dolby Digital Plus, Atmos inside' : _encodedOut[out]);
      return (name == null || name.isEmpty ? 'Passed through to the TV or receiver' : 'Passed through as $name', null);
    }
    final format = _str(mpv['audio-params/format']);
    if (format == null) return ('', null);
    if (format.startsWith('spdif-')) {
      final codec = format.substring(6);
      final name = {'eac3': atmos ? 'Dolby Digital Plus, Atmos inside' : 'Dolby Digital Plus', 'ac3': 'Dolby Digital', 'dts-hd': 'DTS-HD'}[codec] ?? _audioNames[codec] ?? codec.toUpperCase();
      return ('Passed through as $name', null);
    }
    final to = _str(mpv['audio-out-params/hr-channels']) ?? _str(mpv['audio-params/hr-channels']) ?? 'PCM';
    return ('Decoded here to $to', atmos ? 'Atmos decoded to $to · $whyDecoded' : null);
  }

  /// How it went, in a line: played and on what, handed to mpv and what for, or why not.
  String get result {
    final over = _m('handOver');
    final after = (over['afterMs'] as num?)?.toInt();
    final handed = over.isEmpty
        ? ''
        : 'Media3 ${_handOverWords(over['kind'] as String? ?? '')}${after == null ? '' : ' after ${_seconds(after)}'} and handed it to mpv';
    // (an error after the picture has shown ended it; one before means it never played)
    if (failed) return ['${started ? 'Stopped' : 'Did not play'}: ${_s('failure')}', handed].where((x) => x.isNotEmpty).join('. ');
    if (over.isNotEmpty) return _f['mpvFrameMs'] != null ? '$handed, which played it' : '$handed, which has not shown a picture';
    if (started) return 'Played on $_engineName';
    final closed = (_f['closedAfterMs'] as num?)?.toInt();
    return closed == null ? 'Has not shown a picture yet' : 'Closed after ${_seconds(closed)} with no picture';
  }

  /// The whole report as text, to paste into a message.
  String get text => [
    'VyseTV playback report',
    if (title.isNotEmpty) title,
    for (final s in [...stream, ...card]) ...['', s.title.toUpperCase(), for (final f in s.facts) '${f.label}: ${f.value}'],
  ].join('\n');

  // ── Plain words for what the engines say ──

  static List<ReportFact> _facts(List<(String, String)> all) => [
    for (final (label, value) in all)
      if (value.trim().isNotEmpty) (label: label, value: value.trim()),
  ];

  static String? _str(Object? v) => switch (v) {
    final String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };

  static List<String> _list(Object? v) => v is List ? [for (final x in v) '$x'] : const [];

  static double? _num(Object? v) => switch (v) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };

  String get _when {
    final t = when;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _seconds(int ms) => ms < 10000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '${(ms / 1000).round()} s';

  static String _dvMode(String mode) => switch (mode.toUpperCase()) {
    'AUTO' => 'Auto',
    'DISABLED' => 'played as they are',
    'DV81' => 'converted to profile 8.1',
    'HEVC_STRIP' => 'played as HDR10',
    '' => 'not known',
    _ => mode,
  };

  /// The plugin's name for how this video's Dolby Vision is played, in plain words.
  static String _dvPath(String path) => switch (path) {
    'P7 -> P8.1' => 'Converted to profile 8.1',
    'P7 -> HEVC' => 'Dolby Vision taken out, played as HDR10',
    'HDR fallback' => 'Played as HDR10, by the HEVC decoder',
    'DV P8 passthrough' => 'Played as it is, by the Dolby Vision decoder',
    _ when path.startsWith('Native DV') => 'Played as it is, by the Dolby Vision decoder',
    _ => path,
  };

  static int? _dvProfile(String? codecs) {
    final m = RegExp(r'dv(?:he|h1|av|a1)\.(\d{2})').firstMatch(codecs?.toLowerCase() ?? '');
    return m == null ? null : int.tryParse(m[1]!);
  }

  static const _videoMimes = {
    'video/hevc': 'HEVC',
    'video/avc': 'H.264',
    'video/av01': 'AV1',
    'video/x-vnd.on2.vp9': 'VP9',
    'video/x-vnd.on2.vp8': 'VP8',
    'video/mpeg2': 'MPEG-2',
    'video/mp4v-es': 'MPEG-4',
    'video/wvc1': 'VC-1',
  };

  static String _mpvVideoCodec(String name) {
    final n = name.toLowerCase();
    // (mpv's names, and an LG TV's: "H265", "H264")
    for (final (has, label) in const [('hevc', 'HEVC'), ('h.265', 'HEVC'), ('h265', 'HEVC'), ('h264', 'H.264'), ('h.264', 'H.264'), ('av1', 'AV1'), ('vp9', 'VP9'), ('vp8', 'VP8'), ('mpeg2', 'MPEG-2'), ('mpeg-2', 'MPEG-2'), ('vc1', 'VC-1'), ('vc-1', 'VC-1'), ('mpeg4', 'MPEG-4')]) {
      if (n.contains(has)) return label;
    }
    return name.split(RegExp(r' [(/]')).first;
  }

  /// HDR as the stream carries it: Dolby Vision with its profile, HDR10, HLG, or SDR.
  String _hdr(Map<String, Object?> exo, Map<String, Object?> mpv) {
    // An LG TV's player names it itself. Seen in others' logs: "HDR10", "hdr10", "hlg", "none";
    // its name for Dolby Vision is not written down anywhere, so a name not known is shown as it is.
    final tv = _str(mpv['tvHdr']);
    if (tv != null) {
      final t = tv.toLowerCase().replaceAll(RegExp('[^a-z0-9+]'), '');
      if (t.contains('dolby') || t == 'dv') return 'Dolby Vision';
      if (t.contains('hdr10+') || t.contains('hdr10plus')) return 'HDR10+';
      if (t.contains('hdr10') || t == 'hdr') return 'HDR10';
      if (t.contains('hlg')) return 'HLG';
      if (t.isEmpty || t == 'none' || t == 'sdr') return 'SDR';
      return tv;
    }
    // (a TV that has said neither that nor the stream's transfer function has not said: no guess)
    if (onTv && mpv['video-params/gamma'] == null) return '';
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    if (exo['videoMimeType'] == 'video/dolby-vision' || profile != null) {
      // (profile 8 through the HEVC decoder: its HDR10 layer is what shows)
      final asHdr10 = _str(exo['dvPlaybackPath']) == 'HDR fallback' || _str(exo['dvConversionMode']) == 'HEVC_STRIP' && exo['dvConversionActive'] == true;
      return asHdr10 ? 'Dolby Vision, shown as HDR10' : 'Dolby Vision';
    }
    final transfer = (exo['colorTransfer'] as num?)?.toInt();
    final gamma = _str(mpv['video-params/gamma']);
    if (transfer == 6 || gamma == 'pq') return 'HDR10';
    if (transfer == 7 || gamma == 'hlg') return 'HLG';
    return exo.isEmpty && mpv.isEmpty ? '' : 'SDR';
  }

  String _videoCodec(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final mime = _str(exo['videoMimeType']), name = _str(mpv['video-codec']);
    if (mime == null && name == null) return '';
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    final base = mime == 'video/dolby-vision' ? '' : (mime != null ? (_videoMimes[mime] ?? mime.replaceFirst('video/', '')) : _mpvVideoCodec(name!));
    final hdr = _hdr(exo, mpv);
    if (hdr.startsWith('Dolby Vision')) return [if (profile == null) 'Dolby Vision' else 'Dolby Vision, profile $profile', if (base.isNotEmpty) base].join(' · ');
    return [base, hdr].where((x) => x.isNotEmpty).join(' · ');
  }

  String _resolution(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final w = _num(exo['videoWidth'] ?? mpv['video-params/w'] ?? mpv['videoWidth'])?.round() ?? 0;
    final h = _num(exo['videoHeight'] ?? mpv['video-params/h'] ?? mpv['videoHeight'])?.round() ?? 0;
    if (w <= 0 || h <= 0) return '';
    final name = w >= 3000 ? '4K' : (w >= 1800 ? '1080p' : (w >= 1200 ? '720p' : (w >= 800 ? '480p' : '')));
    return '$w × $h${name.isEmpty ? '' : ' ($name)'}';
  }

  static String _bitrate(Object? bps) {
    final b = _num(bps) ?? 0;
    if (b <= 0) return '';
    return b >= 1e6 ? '${(b / 1e6).toStringAsFixed(1)} Mbps' : '${(b / 1e3).round()} kbps';
  }

  static String _fps(Object? fps) {
    final f = _num(fps) ?? 0;
    if (f <= 1) return '';
    return '${f == f.roundToDouble() ? f.round() : f.toStringAsFixed(3)} fps';
  }

  static const _audioNames = {
    'audio/eac3': 'E-AC-3',
    'audio/eac3-joc': 'E-AC-3, Atmos',
    'audio/ac3': 'AC-3',
    'audio/ac4': 'AC-4',
    'audio/true-hd': 'TrueHD',
    'audio/vnd.dts': 'DTS',
    'audio/vnd.dts.hd': 'DTS-HD',
    'audio/vnd.dts.hd;profile=lbr': 'DTS Express',
    'audio/vnd.dts.uhd;profile=p2': 'DTS:X',
    'audio/mp4a-latm': 'AAC',
    'audio/mpeg': 'MP3',
    'audio/mpeg-l2': 'MP2',
    'audio/flac': 'FLAC',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Vorbis',
    'audio/alac': 'ALAC',
    'audio/raw': 'PCM',
    // mpv's names for the same
    'eac3': 'E-AC-3',
    'ac3': 'AC-3',
    'ac4': 'AC-4',
    'truehd': 'TrueHD',
    'dts': 'DTS',
    'aac': 'AAC',
    'mp3': 'MP3',
    'mp2': 'MP2',
    'flac': 'FLAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'alac': 'ALAC',
  };

  String _audioCodec(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final said = _str(exo['audioMimeType']) ?? _str(mpv['audio-codec-name']) ?? _str(_m('audio')['codec']);
    if (said == null) return '';
    final key = said.toLowerCase();
    return _audioNames[key] ?? (key.startsWith('pcm') ? 'PCM' : said.replaceFirst('audio/', '').toUpperCase());
  }

  String _channels(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final n = _num(exo['audioChannels'] ?? mpv['current-tracks/audio/demux-channel-count'] ?? _m('audio')['channels'])?.round();
    return switch (n) {
      null || 0 => _str(mpv['audio-params/hr-channels']) ?? '',
      1 => 'Mono',
      2 => 'Stereo',
      6 => '5.1',
      8 => '7.1',
      _ => '$n channels',
    };
  }

  static String _sampleRate(Object? hz) {
    final r = _num(hz) ?? 0;
    if (r <= 0) return '';
    final k = r / 1000;
    return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)} kHz';
  }

  static String? _mpvDecoder(Map<String, Object?> mpv) => switch (_str(mpv['hwdec-current'])) {
    null => null,
    'no' => 'Software',
    final String d => d,
  };

  // ── Keeping addresses out ──

  static final _address = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s,;)\]}"']+''');

  /// The host of [url] alone ("files.example.com"), or '' when it has none (a file on this
  /// device, a torrent).
  static String hostOf(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || u.scheme == 'file' || u.scheme == 'content' || u.scheme == 'magnet') return '';
    return u.host;
  }

  /// [text] with every address in it cut down to its host.
  static String scrub(String text) => text.replaceAllMapped(_address, (m) {
    final host = hostOf(m[0]!);
    return host.isEmpty ? '(address)' : host;
  });

  /// Only what JSON can hold, and no addresses in any text.
  static Map<String, Object?> _clean(Map<Object?, Object?> raw) => {
    for (final e in raw.entries)
      if (e.key is String)
        e.key as String: switch (e.value) {
          final String s => scrub(s),
          final num n => n,
          final bool b => b,
          final List<Object?> l => [for (final x in l) x is String ? scrub(x) : (x is num || x is bool ? x : '$x')],
          final Map<Object?, Object?> m => _clean(m),
          _ => null,
        },
  }..removeWhere((_, v) => v == null);

  // ── The newest one, kept ──

  static const _key = 'device.lastPlayback';

  /// The newest report, also after the player has closed and the app has been started again.
  /// Null until [load] has read it, or when nothing has been played yet.
  static final last = ValueNotifier<PlaybackReport?>(null);
  static bool _loaded = false;

  /// Reads the kept report (once).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null && last.value == null) last.value = PlaybackReport.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      // nothing kept, or kept by a build that wrote it differently
    }
  }

  /// Makes [report] the newest one and keeps it.
  static Future<void> keep(PlaybackReport report) async {
    _loaded = true;
    last.value = report;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(report.toJson()));
    } catch (_) {
      // (a report that can't be written is still shown while the app runs)
    }
  }

  /// What this device can do with HDR and Dolby Vision, asked of Android once and remembered.
  /// Empty anywhere else.
  static Future<Map<String, Object?>> device() => _device ??= () async {
    if (WebOS.isTv) return _tvDevice();
    if (TizenTv.isTv) return _samsungDevice();
    try {
      final caps = await deviceChannel.invokeMethod<Map<Object?, Object?>>('getPlaybackCapabilities');
      return caps?.cast<String, Object?>() ?? const <String, Object?>{};
    } catch (_) {
      return const <String, Object?>{};
    }
  }();
  static Future<Map<String, Object?>>? _device;

  /// The same of an LG TV, asked of LG's embedder: its model, its webOS, and what its panel
  /// and sound take.
  static Future<Map<String, Object?>> _tvDevice() async {
    try {
      final info = await const MethodChannel('webos_plugin').invokeMapMethod<String, Object?>('device_info/getDeviceInfo') ?? const {};
      if (info.isEmpty) return const {};
      final model = info['modelName'];
      final version = info['version'] ?? info['sdkVersion'];
      return {
        'device': ['LG', if (model is String && model.isNotEmpty) model, if (info['oled'] == true) 'OLED'].join(' '),
        if (version is String && version.isNotEmpty) 'webos': version,
        'displayHdr': [if (info['hdr10'] == true) 'HDR10', if (info['dolbyVision'] == true) 'Dolby Vision'],
        if (info['dolbyAtmos'] is bool) 'atmos': info['dolbyAtmos'],
      };
    } catch (_) {
      return const {};
    }
  }

  /// The same of a Samsung TV, as far as an app is told: that it is one, and its Tizen.
  static Map<String, Object?> _samsungDevice() {
    final version = Platform.environment['TIZEN_API_VERSION'];
    return {'device': 'Samsung TV', if (version != null && version.isNotEmpty) 'tizen': version};
  }

  @visibleForTesting
  static void debugReset() {
    _device = null;
    _loaded = false;
    last.value = null;
  }
}
