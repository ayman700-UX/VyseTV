// The Usenet engine itself, end to end on this computer: a real video split into yEnc articles
// and served by a small NNTP server here, an NZB naming them served over HTTP, and the real
// engine program (packages/vyse_usenet) opening it through UsenetEngine and serving it back
// byte for byte, from the start, from the middle, from the end.
//
// Needs the engine program for this computer and a video file:
//   VYSE_USENET_ENGINE=<path to vyse-usenet(.exe)> VYSE_USENET_VIDEO=<an .mkv>
//     flutter test test/usenet_engine_e2e_test.dart
// Without them the test is skipped.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/usenet_engine.dart';

/// CRC-32 (IEEE), as yEnc's pcrc32 carries it.
int crc32(List<int> data) {
  var table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// One article: the part [begin, end) of [file] (1-based offsets in the header, as yEnc has
/// them), yEnc-encoded in 128-character lines and dot-stuffed for NNTP.
List<int> yencArticle(Uint8List file, String name, int part, int total, int begin, int end) {
  final out = BytesBuilder(copy: false);
  void line(String s) => out.add(utf8.encode('$s\r\n'));
  line('=ybegin part=$part total=$total line=128 size=${file.length} name=$name');
  line('=ypart begin=${begin + 1} end=$end');
  final data = file.sublist(begin, end);
  var row = <int>[];
  void flush() {
    if (row.isEmpty) return;
    if (row.first == 0x2E) row.insert(0, 0x2E); // dot-stuffing
    out.add(row);
    out.add(const [13, 10]);
    row = <int>[];
  }

  for (var i = 0; i < data.length; i++) {
    final c = (data[i] + 42) & 0xFF;
    final atEdge = row.isEmpty || i == data.length - 1;
    if (c == 0 || c == 10 || c == 13 || c == 0x3D || (atEdge && (c == 9 || c == 32 || c == 0x2E))) {
      row
        ..add(0x3D)
        ..add((c + 64) & 0xFF);
    } else {
      row.add(c);
    }
    if (row.length >= 128) flush();
  }
  flush();
  line('=yend size=${end - begin} part=$part pcrc32=${crc32(data).toRadixString(16).padLeft(8, '0')}');
  return out.takeBytes();
}

/// A tiny NNTP server: greeting, sign-in, MODE READER, DATE, STAT, BODY and QUIT, answered in
/// order on each connection (the engine pipelines its BODY commands).
class FakeNntp {
  FakeNntp(this.articles);
  final Map<String, List<int>> articles;
  late final ServerSocket server;
  int bodies = 0;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((sock) async {
      sock.add(utf8.encode('200 fake news ready\r\n'));
      var buf = <int>[];
      await for (final chunk in sock) {
        buf.addAll(chunk);
        while (true) {
          final nl = buf.indexOf(10);
          if (nl < 0) break;
          final cmd = utf8.decode(buf.sublist(0, nl)).trim();
          buf = buf.sublist(nl + 1);
          final up = cmd.toUpperCase();
          if (up.startsWith('AUTHINFO USER')) {
            sock.add(utf8.encode('381 password please\r\n'));
          } else if (up.startsWith('AUTHINFO PASS')) {
            sock.add(utf8.encode('281 welcome\r\n'));
          } else if (up == 'MODE READER') {
            sock.add(utf8.encode('200 reader\r\n'));
          } else if (up == 'DATE') {
            sock.add(utf8.encode('111 20261128000000\r\n'));
          } else if (up == 'QUIT') {
            sock.add(utf8.encode('205 bye\r\n'));
            await sock.flush();
            await sock.close();
            return;
          } else if (up.startsWith('STAT ') || up.startsWith('BODY ')) {
            final id = cmd.substring(5).trim().replaceAll(RegExp(r'^<|>$'), '');
            final a = articles[id];
            if (a == null) {
              sock.add(utf8.encode('430 no such article\r\n'));
            } else if (up.startsWith('STAT ')) {
              sock.add(utf8.encode('223 0 <$id>\r\n'));
            } else {
              bodies++;
              sock.add(utf8.encode('222 0 <$id>\r\n'));
              sock.add(a);
              sock.add(utf8.encode('.\r\n'));
            }
          } else {
            sock.add(utf8.encode('500 unknown command\r\n'));
          }
        }
      }
    }, onError: (Object _) {});
  }
}

void main() {
  final engine = Platform.environment['VYSE_USENET_ENGINE'];
  final video = Platform.environment['VYSE_USENET_VIDEO'];
  final skip = engine == null || video == null ? 'set VYSE_USENET_ENGINE and VYSE_USENET_VIDEO' : null;

  test('a release from Usenet plays back byte for byte, with seeking', () async {
    final file = await File(video!).readAsBytes();
    const name = 'Test.Movie.2026.720p.WEB-DL.x264-VYSE.mkv';
    const partSize = 384000;
    final total = (file.length + partSize - 1) ~/ partSize;
    final articles = <String, List<int>>{};
    final segs = StringBuffer();
    for (var p = 0; p < total; p++) {
      final begin = p * partSize, end = (begin + partSize).clamp(0, file.length);
      final id = 'part${p + 1}of$total.vyse@test';
      final a = yencArticle(file, name, p + 1, total, begin, end);
      articles[id] = a;
      segs.writeln('<segment bytes="${a.length}" number="${p + 1}">$id</segment>');
    }
    final nntp = FakeNntp(articles);
    await nntp.start();
    final nzb = '''<?xml version="1.0" encoding="UTF-8"?>
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
<file poster="vyse@test" date="1764288000" subject="Test.Movie.2026.720p.WEB-DL.x264-VYSE [1/1] - &quot;$name&quot; yEnc (1/$total)">
<groups><group>alt.binaries.test</group></groups>
<segments>
$segs</segments>
</file>
</nzb>''';
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((r) {
      r.response.headers.contentType = ContentType('application', 'x-nzb');
      r.response.write(nzb);
      r.response.close();
    });

    UsenetEngine.debugProgram = engine;
    UsenetEngine.debugSupportDir = await Directory.systemTemp.createTemp('vyse-usenet-e2e-');
    final e = UsenetEngine.instance;
    List<Map<String, Object?>>? report;
    e.onProviderReport = (servers, r, {required refused, kind}) => report = r;
    final sw = Stopwatch()..start();
    final s = await e.open({
      'nzbUrl': 'http://127.0.0.1:${http.port}/release.nzb',
      'servers': ['nntp://user:pass@127.0.0.1:${nntp.server.port}/4'],
      'headers': {'User-Agent': 'VyseTV/test'},
      'cacheScope': 'unscoped',
      'config': {
        'profile': 'balanced',
        'readAhead': 0,
        'maxConnections': 0,
        'fastMkvStartup': true,
        'fastNzbFetch': true,
        'cacheNzb': false,
        'allowPrivateNetwork': true,
        'holeFilling': false,
        'maxMissingArticles': 5,
        'maxConsecutiveMissing': 2,
      },
    });
    // ignore: avoid_print
    print('opened in ${sw.elapsedMilliseconds} ms: ${s.filename} (${s.size} bytes) at ${s.url}; ${nntp.bodies} articles read');
    expect(s.filename, name);
    expect(s.size, file.length);

    final client = HttpClient();
    Future<List<int>> get({int? from, int? to}) async {
      final req = await client.getUrl(Uri.parse(s.url));
      if (from != null) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-${to ?? ''}');
      final res = await req.close();
      expect(res.statusCode, from == null ? 200 : 206);
      return [for (final c in await res.toList()) ...c];
    }

    // the whole file, then three seeks: the middle, across an article boundary, the end
    expect(await get(), file);
    final mid = file.length ~/ 2;
    expect(await get(from: mid, to: mid + 99999), file.sublist(mid, mid + 100000));
    expect(await get(from: partSize - 10, to: partSize + 9), file.sublist(partSize - 10, partSize + 10));
    expect(await get(from: file.length - 5000), file.sublist(file.length - 5000));

    expect(e.isEngineUrl(s.url), isTrue);
    expect(e.sessionOf(s.url), s.id);
    await e.release(s.id);
    // ignore: avoid_print
    print('closed; providers: $report; stderr: ${e.lastErrors}');
    await e.stop();
    client.close(force: true);
    await http.close(force: true);
    await nntp.server.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
