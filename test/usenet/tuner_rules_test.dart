// The connection tuner's rules by themselves, with the spec's examples.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/nntp.dart';
import 'package:vyse_tv/data/usenet/nntp_tuner.dart';

TuneReading r(int n, double mbps, {int port = 563, bool tls = true}) => TuneReading(port: port, tls: tls, connections: n, mbps: mbps);

void main() {
  test('the limit check goes from 100 to 200 connections', () {
    expect(NntpTuner.probeCapFor(20), 100);
    expect(NntpTuner.probeCapFor(150), 150);
    expect(NntpTuner.probeCapFor(4096), 200);
  });

  test('usable connections: the limit less a tenth, or as many as were held', () {
    expect(NntpTuner.usableFor(53, 54), 48);
    expect(NntpTuner.usableFor(100, 101), 90);
    expect(NntpTuner.usableFor(5, 6), 4);
    expect(NntpTuner.usableFor(1, 2), 1);
    expect(NntpTuner.usableFor(null, 100), 100);
  });

  test('ports: the saved one first, TLS never to a plain port', () {
    expect(NntpTuner.portsFor(563, true), [(563, true), (443, true)]);
    expect(NntpTuner.portsFor(5563, true), [(5563, true), (563, true), (443, true)]);
    expect(NntpTuner.portsFor(119, false), [(119, false)]);
    expect(NntpTuner.portsFor(443, true), [(443, true), (563, true)]);
  });

  test('the ladder climbs to the usable count', () {
    expect(NntpTuner.ladderFor(48), [4, 8, 12, 16, 24, 32, 48]);
    expect(NntpTuner.ladderFor(10), [4, 8, 10]);
    expect(NntpTuner.ladderFor(3), [3]);
    expect(NntpTuner.ladderFor(100), [4, 8, 12, 16, 24, 32, 48, 64, 80, 100]);
  });

  test('the ladder stops when two steps in a row add under 3%', () {
    expect(NntpTuner.stopsRising([50, 100]), isFalse);
    expect(NntpTuner.stopsRising([50, 100, 150, 151]), isFalse);
    expect(NntpTuner.stopsRising([50, 100, 150, 151, 149]), isTrue);
    expect(NntpTuner.stopsRising([100, 0, 0]), isTrue);
  });

  test('fastest: the fewest connections within 95% of the best mean', () {
    expect(NntpTuner.fastest([r(4, 100), r(8, 190), r(16, 200), r(24, 198), r(16, 204)]), 16);
    expect(NntpTuner.fastest([r(8, 195), r(16, 202)]), 8);
    expect(NntpTuner.fastest([r(8, 150), r(16, 200), r(24, 205)]), 16);
    expect(NntpTuner.fastest(const []), isNull);
  });

  test('the recommendation: raised only when clearly faster twice, kept under the limit', () {
    const i = {10: 100.0, 32: 130.0};
    const rep = {10: 101.0, 32: 125.0};
    expect(NntpTuner.recommend(allowance: 100, fastest: 16, limit: 53, tried: 54, initial: const {}, repeats: const {}), 48);
    expect(NntpTuner.recommend(allowance: 30, fastest: 16, limit: 53, tried: 54, initial: i, repeats: rep), 30);
    expect(NntpTuner.recommend(allowance: 300, fastest: 16, limit: null, tried: 200, initial: i, repeats: rep), 300);
    expect(NntpTuner.recommend(allowance: 10, fastest: 32, limit: 53, tried: 54, initial: i, repeats: rep), 32);
    expect(NntpTuner.recommend(allowance: 10, fastest: 32, limit: 53, tried: 54, initial: i, repeats: const {10: 120, 32: 125}), 10);
    expect(NntpTuner.recommend(allowance: 10, fastest: 32, limit: 53, tried: 54, initial: i, repeats: const {}), 10);
    expect(NntpTuner.recommend(allowance: 10, fastest: 32, limit: 53, tried: 54, initial: const {32: 130}, repeats: rep), 10);
  });

  test('the drain budget: twice what is in flight, 3 to 15 s', () {
    expect(NntpTuner.drainBudgetMs(16, 4, 700000, 20e6), 4480);
    expect(NntpTuner.drainBudgetMs(4, 4, 700000, 20e6), 3000);
    expect(NntpTuner.drainBudgetMs(48, 4, 700000, 1e6), 15000);
    expect(NntpTuner.drainBudgetMs(16, 4, 0, 20e6), 3000);
    expect(NntpTuner.drainBudgetMs(16, 4, 700000, 0), 3000);
  });

  test("the test post's article ids, in order, without their < >", () {
    const nzb = '<nzb><file><segments>'
        '<segment bytes="1" number="1">abc-1@nyuu</segment>\n'
        '<segment> <def@host> </segment>'
        '<segment number="3">a&amp;b@x</segment>'
        '</segments></file></nzb>';
    expect(NntpTuner.messageIds(nzb), ['abc-1@nyuu', 'def@host', 'a&b@x']);
  });

  test('a body is read to its own end, never into the next reply', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) {
      s.add(utf8.encode('200 hello\r\n'));
      // in small pieces, so the ends fall across reads
      final bytes = utf8.encode('222 one\r\nline one\r\n..dot stuffed\r\n.\r\n222 next\r\nx\r\n.\r\n223 last\r\n');
      () async {
        for (var i = 0; i < bytes.length; i += 3) {
          s.add(bytes.sublist(i, i + 3 > bytes.length ? bytes.length : i + 3));
          await s.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }();
    });
    final session = await NntpSession.open(const NntpTarget(host: '127.0.0.1', port: 0, tls: false).copyPort(server.port), [InternetAddress.loopbackIPv4]);
    expect(await session.line(), '222 one');
    var heard = 0;
    expect(await session.drainBody(onBytes: (n) => heard += n), 28);
    expect(heard, 28);
    expect(await session.line(), '222 next');
    expect(await session.drainBody(), 6);
    expect(await session.line(), '223 last');
    session.close();
  });

  test('a body cut off by the connection closing is an error', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) async {
      s.add(utf8.encode('200 hello\r\n222 one\r\nhalf a bo'));
      await s.flush();
      await s.close();
    });
    final session = await NntpSession.open(const NntpTarget(host: '127.0.0.1', port: 0, tls: false).copyPort(server.port), [InternetAddress.loopbackIPv4]);
    expect(await session.line(), '222 one');
    await expectLater(session.drainBody(), throwsA(isA<NntpFailure>()));
    session.close();
  });
}

extension on NntpTarget {
  NntpTarget copyPort(int port) => NntpTarget(host: host, port: port, tls: tls, username: username, password: password);
}
