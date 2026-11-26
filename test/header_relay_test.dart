// The relay the LG webOS player opens a link through when the link needs HTTP headers the TV's
// own player cannot send (lib/mpv/support/header_relay.dart). A made-up video host stands in
// for the real one, on this machine.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/mpv/support/header_relay.dart';

void main() {
  late HttpServer host;
  final asked = <({String method, String path, Map<String, String> headers})>[];
  final body = List<int>.generate(1000, (i) => i % 251);

  setUp(() async {
    asked.clear();
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((req) async {
      final h = <String, String>{};
      req.headers.forEach((k, v) => h[k] = v.join(', '));
      asked.add((method: req.method, path: req.uri.toString(), headers: h));
      final res = req.response;
      if (req.uri.path == '/moved.mkv') {
        res.statusCode = HttpStatus.found;
        res.headers.set('location', '/v/film.mkv?t=1');
        return res.close();
      }
      if (h['referer'] != 'https://site.example/') {
        res.statusCode = HttpStatus.forbidden;
        return res.close();
      }
      res.headers.contentType = ContentType('video', 'x-matroska');
      res.headers.set('accept-ranges', 'bytes');
      final range = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(h['range'] ?? '');
      if (range != null) {
        final from = int.parse(range[1]!);
        final to = range[2]!.isEmpty ? body.length - 1 : int.parse(range[2]!);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set('content-range', 'bytes $from-$to/${body.length}');
        res.contentLength = to - from + 1;
        if (req.method != 'HEAD') res.add(body.sublist(from, to + 1));
      } else {
        res.contentLength = body.length;
        if (req.method != 'HEAD') res.add(body);
      }
      return res.close();
    });
  });

  tearDown(() async {
    await host.close(force: true);
    await HeaderRelay.instance.debugReset();
  });

  Future<({int status, HttpHeaders headers, List<int> bytes})> get(String url, {String? range, String method = 'GET'}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      if (range != null) req.headers.set('range', range);
      final res = await req.close();
      final bytes = await res.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      return (status: res.statusCode, headers: res.headers, bytes: bytes);
    } finally {
      client.close(force: true);
    }
  }

  test('the real address is asked with the link\'s headers, and the file comes back whole', () async {
    final real = 'http://127.0.0.1:${host.port}/v/film.mkv?t=1';
    final local = await HeaderRelay.instance.wrap(real, {'Referer': 'https://site.example/', 'X-Token': 'abc'});
    expect(local, matches(RegExp(r'^http://127\.0\.0\.1:\d+/r/\d+/v/film\.mkv$')), reason: "the real path, under a number of the link's own");

    final got = await get(local);
    expect(got.status, 200);
    expect(got.bytes, body);
    expect(got.headers.contentType?.mimeType, 'video/x-matroska');
    expect(got.headers.contentLength, body.length);
    expect(asked.single.path, '/v/film.mkv?t=1');
    expect(asked.single.headers['x-token'], 'abc');
  });

  test('a seek: the TV\'s range is passed on, and the part comes back as a part', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/v/film.mkv', {'Referer': 'https://site.example/'});
    final got = await get(local, range: 'bytes=100-299');
    expect(got.status, 206);
    expect(got.bytes, body.sublist(100, 300));
    expect(got.headers.value('content-range'), 'bytes 100-299/1000');
    expect(got.headers.value('accept-ranges'), 'bytes');
    expect(asked.single.headers['range'], 'bytes=100-299');
  });

  test('asked for its headers only, it sends no body', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/v/film.mkv', {'Referer': 'https://site.example/'});
    final got = await get(local, method: 'HEAD');
    expect(got.status, 200);
    expect(got.bytes, isEmpty);
    expect(got.headers.contentLength, body.length);
  });

  test('a link that moved is followed, with the headers', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/moved.mkv', {'Referer': 'https://site.example/'});
    final got = await get(local);
    expect(got.status, 200);
    expect(got.bytes, body);
    expect(asked.map((a) => a.path), ['/moved.mkv', '/v/film.mkv?t=1']);
  });

  test('the host\'s refusal comes through as it is', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/v/film.mkv', {'Referer': 'https://elsewhere.example/'});
    expect((await get(local)).status, 403);
  });

  test('an address nobody was given answers "not found"; an odd name is kept as it is', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/v/${Uri.encodeComponent('a film (2024).mkv')}', {'Referer': 'https://site.example/'});
    expect(local, endsWith('/v/a%20film%20(2024).mkv'));
    expect((await get(local)).status, 200);
    expect(asked.single.path, '/v/a%20film%20(2024).mkv');
    asked.clear();
    final port = Uri.parse(local).port;
    expect((await get('http://127.0.0.1:$port/r/999/x.mkv')).status, 404);
    expect((await get('http://127.0.0.1:$port/r/999')).status, 404);
    expect((await get('http://127.0.0.1:$port/r')).status, 404);
    expect(asked, isEmpty, reason: 'nothing was asked of the host for any of them');
  });

  test("a playlist's parts, named beside it, are asked of the same place with the same headers", () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/live/ch1/index.m3u8?token=t', {'Referer': 'https://site.example/', 'User-Agent': 'libmpv'});
    expect(local, endsWith('/live/ch1/index.m3u8'));
    expect((await get(local)).status, 200);
    // what the TV asks next, having read "seg/001.ts?x=1", "../key.bin" and "a:b.ts" in the playlist
    final playlist = Uri.parse(local);
    expect((await get('${playlist.resolve('seg/001.ts?x=1')}')).status, 200);
    expect((await get('${playlist.resolve('../key.bin')}')).status, 200);
    expect((await get('${playlist.resolve('./a:b.ts')}')).status, 200);
    // (the colon comes out written as %3A, which is the same name)
    expect(asked.map((a) => a.path), ['/live/ch1/index.m3u8?token=t', '/live/ch1/seg/001.ts?x=1', '/live/key.bin', '/live/ch1/a%3Ab.ts']);
    expect(asked.every((a) => a.headers['referer'] == 'https://site.example/' && a.headers['user-agent'] == 'libmpv'), isTrue);
  });

  test('a part named from the top of the host is asked of the host of the link opened last', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/live/ch1/index.m3u8?token=t', {'Referer': 'https://site.example/'});
    final got = await get('${Uri.parse(local).resolve('/hls/ch1/001.ts?e=5')}');
    expect(got.status, 200);
    expect(asked.single.path, '/hls/ch1/001.ts?e=5', reason: "its own question, not the playlist's");
    expect(asked.single.headers['referer'], 'https://site.example/');
    asked.clear();
    expect((await get('${Uri.parse(local).resolve('/hls/ch1/002.ts')}')).status, 200);
    expect(asked.single.path, '/hls/ch1/002.ts');
  });

  test('a link that moved: its parts are beside where it moved to', () async {
    final local = await HeaderRelay.instance.wrap('http://127.0.0.1:${host.port}/moved.mkv', {'Referer': 'https://site.example/'});
    expect((await get(local)).status, 200);
    expect((await get('${Uri.parse(local).resolve('part2.ts')}')).status, 200);
    expect(asked.last.path, '/v/part2.ts');
  });
}
