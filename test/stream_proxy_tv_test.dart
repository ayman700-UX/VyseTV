// The app's stream relay (lib/data/playback/stream_proxy.dart) as a TV's own player meets it
// (an LG's or a Samsung's): each piece of a playlist named by what it is (.ts, .m4s, the init
// section .mp4, a subtitle rendition's pieces .vtt) and sent with that type, whatever its host
// calls it. mpv and Media3 look at what a piece holds; a TV's player may go by the name and the
// type, and hosts dress pieces up as pictures and pages. And what the player asked of it, for
// the report card. A made-up video host stands in for the real one, on this machine.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/tizen_tv.dart';
import 'package:vyse_tv/data/playback/stream_proxy.dart';
import 'package:vyse_tv/mpv/support/relay_log.dart';

void main() {
  late HttpServer host;
  late String base;

  setUp(() async {
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${host.port}';
    host.listen((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/master.m3u8':
          res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          res.write('#EXTM3U\n'
              '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",URI="subs.m3u8"\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,SUBTITLES="s"\n'
              'video.m3u8\n');
        case '/video.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI="init.png"\n#EXTINF:4.0,\npart1.jpg\n#EXTINF:4.0,\npart2\n#EXT-X-ENDLIST\n');
        case '/plain.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\na.html\n#EXTINF:4.0,\nb.ts\n#EXT-X-ENDLIST\n');
        case '/subs.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nline1.txt\n#EXT-X-ENDLIST\n');
        case '/gone.jpg':
          res.statusCode = HttpStatus.forbidden;
        default:
          res.headers.contentType = ContentType('image', 'jpeg');
          res.add(List<int>.filled(400, 0x47));
      }
      await res.close();
    });
  });

  tearDown(() async {
    TizenTv.debugIs = null;
    await host.close(force: true);
    await StreamProxy.instance.close();
  });

  Future<({int status, String type, String text})> get(String url) async {
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      final bytes = await res.fold<List<int>>([], (all, c) => all..addAll(c));
      return (status: res.statusCode, type: res.headers.contentType?.mimeType ?? '', text: latin1.decode(bytes));
    } finally {
      client.close(force: true);
    }
  }

  List<String> addresses(String playlist) => [
    for (final l in const LineSplitter().convert(playlist))
      if (l.startsWith('http')) l else ...RegExp(r'URI="([^"]+)"').allMatches(l).map((m) => m[1]!),
  ];

  test('the ending a piece gets on a TV', () {
    expect(StreamProxy.pieceEnding('https://x/p/part1.jpg', fmp4: false), '.ts');
    expect(StreamProxy.pieceEnding('https://x/p/part1.jpg', fmp4: true), '.m4s');
    expect(StreamProxy.pieceEnding('https://x/p/a.aac?t=1', fmp4: false), '.aac', reason: 'a real ending is kept');
    expect(StreamProxy.pieceEnding('https://x/init.png', fmp4: true, init: true), '.mp4');
    expect(StreamProxy.pieceEnding('https://x/k', fmp4: false, key: true), '.key');
    expect(StreamProxy.pieceEnding('https://x/line1.txt', fmp4: false, subtitles: true), '.vtt');
  });

  test('on a TV: every piece named and typed by what it is, and the subtitle rendition as subtitles', () async {
    TizenTv.debugIs = true;
    final master = await get(await StreamProxy.instance.wrap('$base/master.m3u8'));
    expect(master.status, 200);
    final subs = addresses(master.text).firstWhere((a) => a.contains('sub=1'));
    final video = addresses(master.text).firstWhere((a) => !a.contains('sub=1'));

    final media = await get(video);
    final parts = addresses(media.text);
    expect(parts[0], endsWith('.mp4'), reason: 'the init section, called init.png');
    expect(parts[1], endsWith('.m4s'));
    expect(parts[2], endsWith('.m4s'), reason: 'a piece with no ending at all');
    final init = await get(parts[0]);
    expect(init.type, 'video/mp4', reason: 'not the picture its host says it is');
    expect((await get(parts[1])).type, 'video/mp4');

    final lines = addresses((await get(subs)).text);
    expect(lines.single, endsWith('.vtt'));
    expect((await get(lines.single)).type, 'text/vtt');

    final plain = addresses((await get(await StreamProxy.instance.wrap('$base/plain.m3u8'))).text);
    expect(plain.first, endsWith('.ts'));
    expect((await get(plain.first)).type, 'video/mp2t', reason: 'a page by its name, MPEG-TS by its playlist');
  });

  test('on a PC nothing about the addresses changes (mpv reads what a piece holds)', () async {
    final media = addresses((await get(await StreamProxy.instance.wrap('$base/video.m3u8'))).text);
    for (final a in media) {
      expect(Uri.parse(a).pathSegments.last.contains('.'), isFalse, reason: a);
    }
  });

  test('what the player asked, and what failed, for the report card', () async {
    TizenTv.debugIs = true;
    final url = await StreamProxy.instance.wrap('$base/plain.m3u8');
    expect(RelayLog.instance.line, 'the player asked nothing of it');
    final plain = addresses((await get(url)).text);
    await get(plain.first);
    await get(url.replaceFirst(RegExp(r'/hls/[^.]+'), '/seg/${base64Url.encode(utf8.encode('$base/gone.jpg')).replaceAll('=', '')}'));
    expect(RelayLog.instance.line, startsWith('asked 1 playlist, 2 pieces'));
    expect(RelayLog.instance.line, contains('piece: HTTP 403 from 127.0.0.1'));
  });
}
