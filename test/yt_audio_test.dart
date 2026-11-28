// VyseTV's own lookup of a song's sound (lib/data/music/yt_audio.dart), with YouTube's answers
// made up here: nothing is asked of the network.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/music/yt_audio.dart';

const _id = 'dQw4w9WgXcQ';

Map<String, dynamic> _format(int itag, String mime, {int bitrate = 128000, String host = 'rr1---sn-abc.googlevideo.com', String extra = '', int? channels = 2, bool video = false}) => {
  'itag': itag,
  'url': 'https://$host/videoplayback?expire=1900000000&id=x&itag=$itag$extra',
  'mimeType': mime,
  'bitrate': bitrate,
  if (video) 'width': 640,
  if (video) 'height': 360,
  'audioSampleRate': '48000',
  'audioChannels': ?channels,
};

String _answer({String status = 'OK', String reason = '', List<Map<String, dynamic>>? adaptive, List<Map<String, dynamic>>? progressive, String videoId = _id, int expiresIn = 21540}) => jsonEncode({
  'playabilityStatus': {'status': status, if (reason.isNotEmpty) 'reason': reason},
  'videoDetails': {'videoId': videoId},
  if (adaptive != null || progressive != null)
    'streamingData': {'expiresInSeconds': '$expiresIn', 'adaptiveFormats': ?adaptive, 'formats': ?progressive},
});

final _opus = _format(251, 'audio/webm; codecs="opus"', bitrate: 140000);
final _aac = _format(140, 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000);
final _video = _format(137, 'video/mp4; codecs="avc1.640028"', video: true);

void main() {
  final visionOs01 = YtAudio.clients.first;

  setUp(() {
    YtAudio.debugHttp = null;
    YtAudio.debugVisitor = null;
    YtAudio.debugWantsAac = null;
    YtAudio.instance.forget(_id);
  });

  group('the format', () {
    test('Opus in WebM by default, AAC in MP4 where the player wants it; never a video', () {
      final formats = [_video, _aac, _opus];
      expect(YtAudio.pickAudio(formats, aac: false)?['itag'], 251);
      expect(YtAudio.pickAudio(formats, aac: true)?['itag'], 140);
      expect(YtAudio.pickAudio([_opus], aac: true)?['itag'], 251, reason: 'no AAC: the best there is');
      expect(YtAudio.pickAudio([_video], aac: false), isNull);
    });

    test("an address with an n still to transform, or not on YouTube's servers, is not played", () {
      expect(YtAudio.pickAudio([_format(251, 'audio/webm', extra: '&n=abcDEF')], aac: false), isNull);
      expect(YtAudio.pickAudio([_format(251, 'audio/webm', host: 'example.com')], aac: false), isNull);
      expect(YtAudio.playableAddress('http://rr1.googlevideo.com/videoplayback?x=1'), isFalse, reason: 'https only');
      expect(YtAudio.playableAddress('https://rr1.googlevideo.com/videoplayback?x=1&sn=2'), isTrue, reason: '"sn=" is not "n="');
    });

    test("the file's own language track, when it says which", () {
      final dub = {..._format(251, 'audio/webm', bitrate: 160000), 'audioTrack': {'audioIsDefault': false}};
      final original = {..._format(250, 'audio/webm', bitrate: 70000), 'audioTrack': {'audioIsDefault': true}};
      expect(YtAudio.pickAudio([dub, original], aac: false)?['itag'], 250);
    });

    test('two channels over others at the same bitrate, and the container before both', () {
      expect(YtAudio.score(_format(1, 'audio/webm', channels: 2)) > YtAudio.score(_format(2, 'audio/webm', channels: 6)), isTrue);
      expect(YtAudio.score(_format(1, 'audio/webm', bitrate: 50000)) > YtAudio.score(_format(2, 'audio/mp4', bitrate: 256000)), isTrue);
      expect(YtAudio.score(_format(1, 'audio/webm', bitrate: 160000)) > YtAudio.score(_format(2, 'audio/webm', bitrate: 70000)), isTrue);
    });
  });

  group('the answer', () {
    test('a sound with a playback nonce, the time it stops being served, and no user agent for VISIONOS', () {
      final now = DateTime(2026, 11, 28, 12);
      final r = YtAudio.readAnswer(visionOs01, _id, _answer(adaptive: [_aac, _opus]), aac: false, now: now)!;
      expect(r.itag, 251);
      expect(RegExp(r'&cpn=[A-Za-z0-9_-]{16}$').hasMatch(r.url), isTrue);
      expect(r.userAgent, isNull, reason: 'its addresses are fetched with no headers: a TV player takes them as they are');
      expect(r.expires, now.add(const Duration(seconds: 21540)), reason: 'the earliest of the times YouTube gives');
      expect(r.client, 'VISIONOS_0_1');
    });

    test("YouTube's bot check ends the lookup", () {
      expect(
        () => YtAudio.readAnswer(visionOs01, _id, _answer(status: 'LOGIN_REQUIRED', reason: "Sign in to confirm you're not a bot"), aac: false),
        throwsA(isA<YtBotCheck>()),
      );
      expect(YtAudio.isBotCheck('LOGIN_REQUIRED', 'Sign in to confirm you’re not a bot'), isTrue);
      expect(YtAudio.isBotCheck('LOGIN_REQUIRED', 'Sign in to confirm your age'), isFalse, reason: 'an age gate is not a bot check');
    });

    test("another song's answer, one under DRM, or an unplayable one from a client that is judged by its status: nothing", () {
      final visionOs = YtAudio.clients[1];
      expect(YtAudio.readAnswer(visionOs01, _id, _answer(adaptive: [_opus], videoId: 'otherSong00'), aac: false), isNull);
      expect(YtAudio.readAnswer(visionOs01, _id, _answer(adaptive: [_opus]).replaceFirst('"videoDetails"', '"drmFamilies":[],"videoDetails"'), aac: false), isNull);
      expect(YtAudio.readAnswer(visionOs, _id, _answer(status: 'UNPLAYABLE', adaptive: [_opus]), aac: false), isNull);
      expect(YtAudio.readAnswer(visionOs01, _id, _answer(status: 'UNPLAYABLE', adaptive: [_opus]), aac: false), isNotNull,
          reason: 'VISIONOS 0.1 is judged by its formats, as Metrolist does');
    });

    test('a video with its sound only when that is all there is', () {
      final producer = YtAudio.clients.last;
      final muxed = _format(18, 'video/mp4; codecs="avc1.42001E, mp4a.40.2"', video: true);
      final r = YtAudio.readAnswer(producer, _id, _answer(progressive: [muxed]), aac: true)!;
      expect(r.itag, 18);
      expect(r.userAgent, producer.userAgent, reason: 'fetched with its own user agent');
    });

    test('when an address stops: the earliest of its three times', () {
      final now = DateTime(2026, 11, 28);
      expect(YtAudio.expiryOf('https://r.googlevideo.com/videoplayback?expire=1800000000', 999999999, now: now), DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000));
      expect(YtAudio.expiryOf('https://r.googlevideo.com/videoplayback/expire/1700000000/id/x', null, now: now), DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      expect(YtAudio.expiryOf('https://r.googlevideo.com/videoplayback', '60', now: now), now.add(const Duration(minutes: 1)));
      expect(YtAudio.expiryOf('https://r.googlevideo.com/videoplayback', null), isNull);
    });
  });

  test('the visitor id from sw.js_data, and from a page', () {
    final sw = ")]}'\n${jsonEncode([
      [null, null, [[[for (var i = 0; i < 13; i++) null, 'CgtWaXNpdG9ySWQ%3D']]]],
    ])}";
    expect(YtAudio.visitorFromSwData(sw), 'CgtWaXNpdG9ySWQ%3D');
    expect(YtAudio.visitorFromSwData('no line'), isNull);
    expect(YtAudio.visitorFromPage('ytcfg.set({"VISITOR_DATA":"Cgt123"})'), 'Cgt123');
  });

  test("VISIONOS 0.1's request, as Metrolist sends it", () {
    expect(jsonEncode(visionOs01.body(_id, visitor: 'v')),
        '{"context":{"client":{"clientName":"VISIONOS","clientVersion":"0.1","osName":"VISION_OS","osVersion":"1.3","deviceMake":"Apple","deviceModel":"RealityDevice14,1","platform":"MOBILE","gl":"US","hl":"en","visitorData":"v"}},"videoId":"$_id","contentCheckOk":true,"racyCheckOk":true}');
    final h = visionOs01.headers(visitor: 'v');
    expect(h['X-YouTube-Client-Name'], '101');
    expect(h['Origin'], 'https://music.youtube.com');
    expect(h['X-Goog-Visitor-Id'], 'v');
    expect(h.containsKey('Cookie'), isFalse);
  });

  group('the lookup', () {
    late List<String> asked;
    setUp(() => asked = []);

    void answerWith(String Function(String client) answer, {int status = 200}) => YtAudio.debugHttp = (method, url, headers, body) async {
      final client = body == null ? '' : ((jsonDecode(body) as Map)['context'] as Map)['client']['clientVersion'] as String;
      asked.add('$method ${url.host} $client');
      return (status, answer(client));
    };

    test('VISIONOS 0.1 first, with the visitor id; what it found is kept, and forgotten when the song broke', () async {
      YtAudio.debugVisitor = () => 'visitor';
      answerWith((_) => _answer(adaptive: [_opus]));
      final r = await YtAudio.instance.find(_id, aac: false);
      expect(r?.client, 'VISIONOS_0_1');
      expect(asked, ['POST music.youtube.com 0.1']);
      await YtAudio.instance.find(_id, aac: false);
      expect(asked, hasLength(1), reason: 'from what was kept');
      YtAudio.instance.forget(_id);
      await YtAudio.instance.find(_id, aac: false);
      expect(asked, hasLength(2));
      await YtAudio.instance.find(_id, aac: false, fresh: true);
      expect(asked, hasLength(3));
    });

    test('no visitor id: VISIONOS 0.1 is not asked; nothing found: the next client', () async {
      YtAudio.debugVisitor = () => null;
      answerWith((v) => v == '1.02' ? _answer(status: 'UNPLAYABLE') : _answer(progressive: [_format(18, 'video/mp4', video: true)]));
      final r = await YtAudio.instance.find(_id, aac: true);
      expect(asked, ['POST music.youtube.com 1.02', 'POST www.youtube.com 0.10']);
      expect(r?.itag, 18);
    });

    test('a bot check is not taken to another client', () async {
      YtAudio.debugVisitor = () => 'visitor';
      answerWith((_) => _answer(status: 'LOGIN_REQUIRED', reason: "Sign in to confirm you're not a bot"));
      await expectLater(YtAudio.instance.find(_id, aac: false), throwsA(isA<YtBotCheck>()));
      expect(asked, hasLength(1));
    });

    test("an error answer moves on, and none of them: nothing", () async {
      YtAudio.debugVisitor = () => 'visitor';
      answerWith((_) => 'busy', status: 503);
      expect(await YtAudio.instance.find(_id, aac: false), isNull);
      expect(asked, hasLength(3));
    });
  });
}
