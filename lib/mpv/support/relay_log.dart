// VyseTV addition (not in upstream).
//
// What a player asked of the app's relays on this device (data/playback/stream_proxy.dart for
// streams, header_relay.dart for links that need their headers), since the last video was
// opened through one, and what went wrong there. The report card says it when a video does not
// play: whether the TV's player asked at all, for what, and what the real address answered.
// (A Samsung tester's film sources failed with a line of the TV's media framework, 2026-11-27,
// and nothing said whether the TV had even reached the relay.)
//
// It holds no addresses: hosts only.

class RelayLog {
  RelayLog._();
  static final instance = RelayLog._();

  int playlists = 0;
  int pieces = 0;
  int files = 0;
  final _trouble = <String>[];

  /// Anything asked since the last [start].
  bool get used => playlists + pieces + files > 0 || _trouble.isNotEmpty;

  /// A new video is opened through a relay.
  void start() {
    playlists = 0;
    pieces = 0;
    files = 0;
    _trouble.clear();
  }

  /// Something that went wrong: [what] was asked for and [why] (an HTTP status, an error), from
  /// [host]. The last three are kept.
  void trouble(String what, String why, {String host = ''}) {
    _trouble.add('$what: $why${host.isEmpty ? '' : ' from $host'}');
    if (_trouble.length > 3) _trouble.removeAt(0);
  }

  /// One line for the report card: "asked 1 playlist, 0 pieces · piece: HTTP 403 from cdn.x".
  String get line {
    final asked = [
      if (playlists > 0) '$playlists playlist${playlists == 1 ? '' : 's'}',
      if (pieces > 0) '$pieces piece${pieces == 1 ? '' : 's'}',
      if (files > 0) '$files file request${files == 1 ? '' : 's'}',
    ];
    return [asked.isEmpty ? 'the player asked nothing of it' : 'asked ${asked.join(', ')}', ..._trouble].join(' · ');
  }
}
