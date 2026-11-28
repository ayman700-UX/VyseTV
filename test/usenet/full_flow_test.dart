// The built-in Usenet source from end to end, as the app runs it with streaming mode off: the
// sources list asks the Usenet addon for a film, your indexer (a Newznab server here) is
// searched, the release it lists comes back as a result with its name and badges, and picking
// it opens it in the real Usenet engine from your provider (a small NNTP server here), which
// serves the video byte for byte.
//
// Needs the engine program for this computer and a video file, as usenet_engine_e2e_test.dart:
//   VYSE_USENET_ENGINE=<path to vyse-usenet(.exe)> VYSE_USENET_VIDEO=<an .mkv>
//     flutter test test/usenet/full_flow_test.dart
// Without them the test is skipped.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/usenet_engine.dart';
import 'package:vyse_tv/data/usenet/usenet_play.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_search.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

import '../usenet_engine_e2e_test.dart' show FakeNntp, yencArticle;

void main() {
  final engine = Platform.environment['VYSE_USENET_ENGINE'];
  final video = Platform.environment['VYSE_USENET_VIDEO'];
  final skip = engine == null || video == null ? 'set VYSE_USENET_ENGINE and VYSE_USENET_VIDEO' : null;

  test('a film found on your indexer plays from your provider', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // (real connections: every server here is on this computer)
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    AppSettings.usenetAllowPrivate.set(true); // (everything here is on this computer)
    await UsenetReleases.load();

    // the release on the provider
    final file = await File(video!).readAsBytes();
    const release = 'Test.Movie.2026.1080p.WEB-DL.DDP5.1.H.264-VYSE';
    const name = '$release.mkv';
    const partSize = 384000;
    final total = (file.length + partSize - 1) ~/ partSize;
    final articles = <String, List<int>>{};
    final segs = StringBuffer();
    for (var p = 0; p < total; p++) {
      final begin = p * partSize, end = (begin + partSize).clamp(0, file.length);
      final id = 'flow${p + 1}of$total.vyse@test';
      final a = yencArticle(file, name, p + 1, total, begin, end);
      articles[id] = a;
      segs.writeln('<segment bytes="${a.length}" number="${p + 1}">$id</segment>');
    }
    final nntp = FakeNntp(articles);
    await nntp.start();
    final nzb = '''<?xml version="1.0" encoding="UTF-8"?>
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
<file poster="vyse@test" date="1764288000" subject="$release [1/1] - &quot;$name&quot; yEnc (1/$total)">
<groups><group>alt.binaries.test</group></groups>
<segments>
$segs</segments>
</file>
</nzb>''';

    // the indexer: caps, a text search for the film, and the NZB it links to
    final asked = <Uri>[];
    final indexer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${indexer.port}';
    indexer.listen((r) async {
      asked.add(r.uri);
      final q = r.uri.queryParameters;
      if (r.uri.path == '/get/1') {
        r.response.headers.contentType = ContentType('application', 'x-nzb');
        r.response.write(nzb);
      } else if (q['apikey'] != 'secret-key') {
        r.response.write('<error code="100" description="Incorrect user credentials"/>');
      } else if (q['t'] == 'caps') {
        r.response.write(
          '<caps><limits max="100" default="100"/><searching><search available="yes" supportedParams="q"/>'
          '<movie-search available="yes" supportedParams="q,year"/><tv-search available="yes" supportedParams="q,season,ep"/></searching></caps>',
        );
      } else {
        r.response.headers.contentType = ContentType('application', 'rss+xml');
        r.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
<channel><newznab:response offset="0" total="2"/>
<item><title>$release</title><guid>1</guid>
<enclosure url="$base/get/1?apikey=secret-key" length="${file.length}" type="application/x-nzb"/>
<pubDate>Fri, 27 Nov 2026 12:00:00 +0000</pubDate><newznab:attr name="size" value="${file.length}"/></item>
<item><title>Another.Film.1999.720p.BluRay.x264-OTHER</title><guid>2</guid>
<enclosure url="$base/get/2?apikey=secret-key" length="1000" type="application/x-nzb"/></item>
</channel></rss>''');
      }
      await r.response.close();
    });

    UsenetSourcesStore.debugSet(
      UsenetSources(
        firstUseAccepted: true,
        providers: [UsenetProvider(name: 'Local news', host: '127.0.0.1', port: nntp.server.port, tls: false, username: 'user', password: 'pass', connections: 4)],
        indexers: [UsenetIndexer(name: 'Local indexer', apiUrl: base, apiPath: '/api', apiKey: 'secret-key')],
      ),
    );
    UsenetEngine.debugProgram = engine;
    UsenetEngine.debugSupportDir = await Directory.systemTemp.createTemp('vyse-usenet-flow-');

    // the sources list asks the built-in Usenet addon
    expect(Addons.usenetReady, isTrue);
    final t = const AddonTarget(type: 'movie', title: 'Test Movie', year: 2026);
    final got = await Addons.streams(Addon.usenet, t);
    expect(got, isNotNull);
    final list = got!.streams;
    // ignore: avoid_print
    print('found: ${[for (final s in list) '${s.name} | ${s.description.replaceAll('\n', ' / ')}']}');
    expect(list, hasLength(1), reason: 'the other film on the indexer is not this one');
    final s = list.single;
    expect(s.usenet, isTrue);
    expect(s.nzbUrl, contains('/get/1'));
    expect(s.name, contains('1080p'));
    expect(s.description, contains(release));
    expect(asked.any((u) => u.queryParameters['t'] == 'caps'), isTrue);
    expect(asked.any((u) => u.queryParameters['q'] == 'Test Movie'), isTrue);

    // picked: it opens in the engine from your provider and plays
    final session = await UsenetPlay.open(s);
    expect(session.filename, name);
    expect(session.size, file.length);
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(session.url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=${file.length - 70000}-');
    final res = await req.close();
    expect(res.statusCode, 206);
    expect([for (final c in await res.toList()) ...c], file.sublist(file.length - 70000));

    // its first frame: AVAILABLE from now on, with these providers
    UsenetPlay.played(s);
    expect(UsenetReleases.markOf(s), UsenetMark.available);
    expect([for (final b in UsenetSearch.badgesOf(s)) b.text], contains('AVAILABLE'));

    await UsenetEngine.instance.release(session.id);
    await UsenetEngine.instance.stop();
    client.close(force: true);
    await indexer.close(force: true);
    await nntp.server.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
