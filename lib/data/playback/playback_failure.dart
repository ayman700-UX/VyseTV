import 'playback_report.dart';
import 'player_engine.dart';

/// Why a video did not play, in plain words for the middle of the screen.
///
/// The player used to say nothing: when Media3 or mpv gave a video up, the spinner went and the
/// screen stayed black and silent (testers, 2026-11-25: "a black screen, no audio" on Dolby
/// Vision and HDR films). Whatever the cause, it is now said, with what to do about it.
///
/// The engines' own words are kept for the report card; here they are turned into something a
/// person can act on. An engine message this does not know is shown as it is, cut of addresses.
abstract final class PlaybackFailure {
  /// [message] and [cause] are the player's (PlayerError); [started]: the picture had shown
  /// before it stopped; [handOverOff]: Media3 is the engine and is not allowed to hand a video
  /// to mpv; [otherSources]: there is something else to pick.
  static ({String title, String why, String hint}) words(
    String message, {
    String? cause,
    bool started = false,
    bool handOverOff = false,
    bool otherSources = true,
  }) {
    final why = _why(message, cause);
    final decoder = _decoderTrouble(message);
    return (
      title: started ? 'Playback stopped' : "This link didn't play",
      why: why,
      hint: decoder && handOverOff
          ? "Turn on Switch to mpv when Media3 can't play, in Settings > Playback${otherSources ? ', or pick another source' : ''}"
          : (otherSources ? 'Pick another source' : ''),
    );
  }

  /// The three as one line, for places with room for one ("This link didn't play: … Pick
  /// another source").
  static String line(({String title, String why, String hint}) w) =>
      ['${w.title}${w.why.isEmpty ? '' : ': ${w.why}'}', if (w.hint.isNotEmpty) w.hint].join('. ');

  // mpv's own lines, word for word, for giving up one half of a video while it opens (its
  // player/audio.c, player/video.c, filters/f_output_chain.c and f_decoder_wrapper.c). Each is
  // the last thing it logs before it deselects that track.
  static const _soundLines = {
    'Could not open/initialize audio device -> no sound.',
    'Audio filter initialized failed!',
    'Error reinitializing audio.',
  };
  static const _pictureLines = {
    'Could not initialize video chain.',
    'Error opening/initializing the selected video_out (--vo) device.',
  };
  static const _noConversion = 'Cannot convert decoder/filter output to any format supported by the output.';
  static const _noDecoder = 'Failed to initialize a decoder for codec';
  static const _soundCodecs = {'truehd', 'mlp', 'eac3', 'ac3', 'ac4', 'dts', 'dca', 'aac', 'flac', 'opus', 'vorbis', 'mp3', 'mp2', 'alac', 'pcm'};

  /// The half of a video mpv has just given up, by the one line it logs as it does: 'audio' or
  /// 'video'. Null for every other line.
  ///
  /// mpv only ends a file when both halves are gone. With one left it plays on, a picture with
  /// no sound or sound over a black screen, and says so nowhere but its log: these lines are
  /// the only sign. Matched whole, so an error mpv recovers from is never taken for one.
  /// [error]: the line is at mpv's error or fatal level; [prefix] is the log's own.
  static String? droppedPart({required bool error, required String prefix, required String text}) {
    if (!error) return null;
    final line = text.trim();
    // A TV's own player (a Samsung's) playing on without one half, in the app's words for its
    // fault (PlayerTizen.errorNote), under a prefix of its own.
    if (prefix == 'tv-part') {
      if (line.startsWith("The TV can't play this sound")) return 'audio';
      if (line.startsWith("The TV can't play this picture")) return 'video';
      return null;
    }
    if (_soundLines.contains(line)) return 'audio';
    if (_pictureLines.contains(line)) return 'video';
    // (on the picture's chain mpv tries software decoding next, and says so itself if that fails)
    if (line == _noConversion) return prefix == 'af' ? 'audio' : null;
    if (line.startsWith(_noDecoder)) {
      if (prefix.endsWith('ad')) return 'audio';
      if (prefix.endsWith('vd')) return 'video';
      final codec = RegExp("'([^']+)'").firstMatch(line)?[1]?.toLowerCase() ?? '';
      return _soundCodecs.any(codec.startsWith) ? 'audio' : 'video';
    }
    return null;
  }

  static bool _decoderTrouble(String message) {
    final m = message.toLowerCase();
    return m.contains('no decoder available') || m.contains('decoder hang') || m.contains('black screen detected') || m.contains('mediacodec') || m.contains('decoder init failed');
  }

  static String _why(String message, String? cause) {
    final m = message.toLowerCase();
    final codecs = PlayerEngine.codecsIn(message);
    final named = codecs.isEmpty ? '' : ' (${codecs.join(', ')})';
    final status = RegExp(r'(?:http(?: error)?|response code:?)\s*(\d{3})').firstMatch(m)?[1];
    if (cause == 'server-http-404' || status == '404' || status == '410') return 'the server no longer has this file';
    if (status == '401' || status == '403') return 'the server refused it ($status)';
    if (cause == 'server-http-500' || cause == 'server-http-503' || (status != null && status.startsWith('5'))) return 'the server is not answering${status == null ? '' : ' ($status)'}';
    if (status == '429') return 'the server says too many requests (429)';
    if (cause == 'player-init-failed') return 'the player could not start on this device';
    if (cause == 'audio-output-failed' || m.contains('audio output initialization failed')) return 'this device would not take the sound';
    if (m.contains('video track present but no decoder available')) {
      // (profile 5 has no HDR10 layer under it: with no Dolby Vision decoder there is nothing to show)
      return codecs.contains('Dolby Vision') ? 'this device has no Dolby Vision decoder, and this video has no HDR10 picture to fall back on' : 'this device has no decoder for this picture$named';
    }
    if (m.contains('audio track present but no decoder available')) return 'this device has no decoder for this sound$named';
    if (m.contains('decoder hang') || m.contains('black screen detected')) return "this device's decoder took the video and showed nothing";
    if (m.contains('video output initialization failed')) return 'the picture could not be shown on this screen';
    if (m.contains('unrecognized file format')) return 'it is not a video file the player can read';
    if (m.contains('no audio or video data played')) return 'nothing in the file could be played';
    if (m.contains('loading failed') || m.contains('source error') || m.contains('timeout') || m.contains('timed out') || m.contains('connection')) return 'the link did not answer';
    if (m.contains('stalled while buffering')) return 'the link stopped sending';
    if (m.contains('mediacodec') || m.contains('decoder init failed') || m.contains('codec')) return 'this device could not decode it$named';
    final own = PlaybackReport.scrub(message).trim();
    // (an engine's sentence nobody has met yet: shown as it is, shortened)
    return own.isEmpty || own == 'Playback error' || own == 'Unknown error' ? '' : (own.length > 110 ? '${own.substring(0, 110)}…' : own);
  }
}
