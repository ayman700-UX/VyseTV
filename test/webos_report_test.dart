// The playback report (Stream info, and the card a tester photographs) for a video played by
// an LG TV's own player: what the TV said, in the report's plain words, and nothing it did not
// say. It says nothing about a TV: the facts here are made up in the shape the TV sends them.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/webos.dart';
import 'package:vyse_tv/data/playback/playback_report.dart';

String? fact(List<ReportSection> sections, String section, String label) {
  for (final s in sections.where((s) => s.title == section)) {
    for (final f in s.facts.where((f) => f.label == label)) {
      return f.value;
    }
  }
  return null;
}

PlaybackReport begun() => PlaybackReport.begin(title: 'Far Country', source: 'Movy', link: '4K', url: 'https://files.example/film.mkv?token=abc', engine: 'webos');

const _hdrFilm = {
  'engine': 'webos',
  'videoWidth': 3840,
  'videoHeight': 2160,
  'videoCodec': 'H265',
  'videoFps': 23.976,
  'hdrType': 'HDR10',
  'transfer': 16,
  'audioChannels': 6,
  'audioSampleRate': 48000,
  'audioCodec': 'eac3',
  'audioImmersive': 'atmos',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the engine is named as the TV's own player, from start to result", () {
    var r = begun();
    expect(r.onTv, isTrue);
    expect(r.engineLine, "The TV's own player");
    expect(r.result, 'Has not shown a picture yet');
    r = r.withFirstFrame(1800);
    expect(r.result, "Played on the TV's player");
    expect(r.summary, "Far Country · played on the TV's player");
    expect(r.withFailure("The TV can't play this picture (201)").result, "Stopped: The TV can't play this picture (201)");
  });

  test('what the TV said of the picture and the sound is on Stream info', () {
    final r = begun().withTv(_hdrFilm).withAudio(language: 'English', codec: 'eac3', channels: 6, sampleRate: 48000);
    final s = r.stream;
    expect(fact(s, 'Player engine', 'Engine'), "The TV's own player");
    expect(fact(s, 'Player engine', 'Video decoder'), "The TV's own");
    expect(fact(s, 'Video', 'Codec'), 'HEVC · HDR10');
    expect(fact(s, 'Video', 'Resolution'), '3840 × 2160 (4K)');
    expect(fact(s, 'Video', 'Frame rate'), '23.976 fps');
    expect(fact(s, 'Video', 'On screen'), 'HDR10');
    expect(fact(s, 'Audio', 'Codec'), 'E-AC-3');
    expect(fact(s, 'Audio', 'Channels'), '5.1');
    expect(fact(s, 'Audio', 'Sample rate'), '48 kHz');
    expect(fact(s, 'Audio', 'Heard as'), "As the TV's sound settings send it · immersive (atmos)");
    expect(r.lesser, isNull, reason: 'nothing here maps or converts the picture: there is no lesser form to warn of');
    expect(fact(r.card, 'Outcome', 'HDR format'), 'HDR10');
  });

  test('HDR is named as the TV names it; a name not known is shown as it is, and silence is not SDR', () {
    String hdr(Map<String, Object?> facts) => begun().withTv({'videoWidth': 1920, 'videoHeight': 1080, ...facts}).onScreen;
    expect(hdr({'hdrType': 'hdr10'}), 'HDR10');
    expect(hdr({'hdrType': 'HLG'}), 'HLG');
    expect(hdr({'hdrType': 'none'}), 'SDR');
    expect(hdr({'hdrType': 'DolbyVision'}), 'Dolby Vision');
    expect(hdr({'hdrType': 'dolby_vision'}), 'Dolby Vision');
    expect(hdr({'hdrType': 'HDR10+'}), 'HDR10+');
    expect(hdr({'hdrType': 'TechniColor'}), 'TechniColor');
    // the type not said, but the stream's own transfer function is
    expect(hdr({'transfer': 16}), 'HDR10');
    expect(hdr({'transfer': 18}), 'HLG');
    expect(hdr({'transfer': 1}), 'SDR');
    // neither said: no line at all
    expect(hdr({}), '');
    expect(fact(begun().withTv({'videoWidth': 1920, 'videoHeight': 1080}).stream, 'Video', 'On screen'), isNull);
  });

  test('before the TV has said anything the report has no picture or sound lines', () {
    final s = begun().stream;
    expect(fact(s, 'Video', 'Resolution'), isNull);
    expect(fact(s, 'Audio', 'Heard as'), isNull);
    expect(fact(s, 'Player engine', 'Video decoder'), isNull);
  });

  test("the card's device line is the TV's model and webOS, asked of LG's embedder", () async {
    PlaybackReport.debugReset();
    WebOS.debugIs = true;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('webos_plugin'), (call) async {
      expect(call.method, 'device_info/getDeviceInfo');
      return {'modelName': 'OLED55C4', 'version': '26.0.0', 'oled': true, 'uhd': true, 'hdr10': true, 'dolbyVision': true, 'dolbyAtmos': true};
    });
    addTearDown(() {
      WebOS.debugIs = null;
      messenger.setMockMethodCallHandler(const MethodChannel('webos_plugin'), null);
      PlaybackReport.debugReset();
    });
    final caps = await PlaybackReport.device();
    final card = begun().withDevice(caps).card;
    expect(fact(card, 'Source and hardware', 'Device'), 'LG OLED55C4 OLED · webOS 26.0.0');
    expect(fact(card, 'Source and hardware', 'Display'), 'HDR10, Dolby Vision');
    expect(fact(card, 'Source and hardware', 'Server'), 'files.example', reason: 'never the address');
  });
}
