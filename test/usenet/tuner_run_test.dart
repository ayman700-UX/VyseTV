// The connection tuner end to end against a small NNTP server on this computer (shortened
// steps): the limit found without ever going over it, every connection signed out with QUIT,
// Stop that leaves nothing open, and the failures.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/nntp.dart';
import 'package:vyse_tv/data/usenet/nntp_tuner.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';

import 'tuner_fake_server.dart';

const fast = TuneTiming(
  step: Duration(milliseconds: 400),
  warmup: Duration(milliseconds: 100),
  settle: Duration(milliseconds: 50),
  minStep: Duration(milliseconds: 200),
  poll: Duration(milliseconds: 20),
  readTimeout: Duration(seconds: 3),
  signOutWait: Duration(milliseconds: 500),
  signIn: Duration(milliseconds: 800),
);

UsenetProvider provider(FakeProvider p, {int connections = 20}) =>
    UsenetProvider(name: 'Fake', host: '127.0.0.1', port: p.port, tls: false, username: 'me', password: 'secret', connections: connections);

/// Waits until [check] holds (the server sees a close a moment after the client makes it).
Future<void> eventually(bool Function() check, {Duration within = const Duration(seconds: 2)}) async {
  final clock = Stopwatch()..start();
  while (!check() && clock.elapsed < within) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeNzbServer nzb;

  setUp(() async {
    nzb = FakeNzbServer();
    await nzb.start();
  });
  tearDown(() => nzb.close());

  NntpTuner tuner() => NntpTuner(timing: fast, testNzbUrl: nzb.url, userAgent: 'VyseTV/test');

  test('a provider that accepts 13: limit 13, never more than 13 open, all signed out', () async {
    final server = FakeProvider(limit: 13);
    await server.start();
    addTearDown(server.close);
    final phases = <TunePhase?>[];
    final out = await tuner().run(provider(server), allowPrivate: true, depth: 4, onProgress: (p) => phases.add(p.phase));
    expect(out, isA<TuneSucceeded>());
    final ok = out as TuneSucceeded;
    expect(ok.limit, 13);
    expect(ok.tried, 14);
    expect(server.refused, 4, reason: 'three in the second batch and the one more try');
    expect(server.peakSignedIn, 13, reason: 'never more than the limit signed in at once');
    // usable 12: the allowance of 20 is above the limit, so it comes down to 12
    expect(ok.connections, 12);
    expect(ok.port, server.port);
    expect(ok.tls, isFalse);
    expect(ok.readings.where((x) => x.port == server.port).map((x) => x.connections).toSet(), containsAll(<int>[4, 8, 12]));
    expect(ok.readings.every((x) => x.connections <= 12), isTrue);
    expect(ok.downloadedBytes, greaterThan(0));
    expect(ok.differsFrom(provider(server)), isTrue);
    expect(phases.first, isNull);
    expect(phases, containsAllInOrder([TunePhase.limit, TunePhase.port, TunePhase.connections]));
    expect(nzb.userAgent, 'VyseTV/test');
    await eventually(() => server.open == 0);
    expect(server.open, 0);
    expect(server.abandoned, 0, reason: 'every connection said QUIT before it closed');
  });

  test('lost greetings leave the limit unknown, and the allowance is not lowered', () async {
    final server = FakeProvider(limit: 40, silentAt: {8, 9});
    await server.start();
    addTearDown(server.close);
    final out = await tuner().run(provider(server, connections: 40), allowPrivate: true, depth: 4);
    expect(out, isA<TuneSucceeded>());
    final ok = out as TuneSucceeded;
    expect(ok.limit, isNull);
    expect(ok.tried, 7);
    expect(ok.connections, 40);
    expect(ok.readings.every((x) => x.connections <= 7), isTrue);
    await eventually(() => server.open == 0);
    expect(server.abandoned, 0);
  });

  test('Stop while measuring: back in under 5 s, nothing left open, nothing abandoned', () async {
    final server = FakeProvider(bodyDelay: const Duration(milliseconds: 30));
    await server.start();
    addTearDown(server.close);
    final cancel = TuneCancel();
    final measuring = Completer<void>();
    final slow = NntpTuner(
      timing: const TuneTiming(step: Duration(seconds: 8), warmup: Duration(milliseconds: 300), settle: Duration(milliseconds: 50), poll: Duration(milliseconds: 20), signIn: Duration(seconds: 2)),
      testNzbUrl: nzb.url,
    );
    final run = slow.run(provider(server), allowPrivate: true, depth: 4, cancel: cancel, onProgress: (p) {
      if (p.phase == TunePhase.port && !measuring.isCompleted) measuring.complete();
    });
    await measuring.future;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final clock = Stopwatch()..start();
    cancel.cancel();
    final out = await run;
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    expect(out, isA<TuneStopped>());
    await eventually(() => server.open == 0);
    expect(server.open, 0);
    expect(server.abandoned, 0);
  });

  test('a run after one stopped on stuck greetings finds those connections closed', () async {
    final server = FakeProvider()..silent = true;
    await server.start();
    addTearDown(server.close);
    final cancel = TuneCancel();
    final slow = NntpTuner(timing: const TuneTiming(signIn: Duration(seconds: 10), settle: Duration(milliseconds: 50)), testNzbUrl: nzb.url);
    final first = slow.run(provider(server), allowPrivate: true, depth: 4, cancel: cancel);
    await eventually(() => server.silentOpen.length == 8);
    expect(server.silentOpen.length, 8);
    cancel.cancel();
    server.silent = false;
    var closedAtFirst = -1;
    final second = TuneCancel();
    final again = tuner().run(provider(server), allowPrivate: true, depth: 4, cancel: second, onProgress: (p) {
      if (closedAtFirst < 0) {
        closedAtFirst = 0;
        // the old sockets were closed before this run began: the server hears of it at once
        Future<void>.delayed(const Duration(milliseconds: 150), () => closedAtFirst = server.silentClosed.length);
      }
    });
    expect(await first, isA<TuneStopped>());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    second.cancel();
    await again;
    expect(closedAtFirst, 8);
  });

  test('missing test articles end the run in the port step', () async {
    final server = FakeProvider(missing: true);
    await server.start();
    addTearDown(server.close);
    final out = await tuner().run(provider(server), allowPrivate: true, depth: 4);
    expect(out, isA<TuneFailed>());
    expect((out as TuneFailed).failure, TuneFailure.missingArticles);
    await eventually(() => server.open == 0);
    expect(server.abandoned, 0);
  });

  test('test data that cannot be downloaded', () async {
    final server = FakeProvider();
    await server.start();
    addTearDown(server.close);
    final missingNzb = FakeNzbServer(status: 404);
    await missingNzb.start();
    addTearDown(missingNzb.close);
    final out = await NntpTuner(timing: fast, testNzbUrl: missingNzb.url).run(provider(server), allowPrivate: true, depth: 4);
    expect((out as TuneFailed).failure, TuneFailure.testData);
  });

  test('too few articles in the test post is a test data failure', () async {
    final server = FakeProvider();
    await server.start();
    addTearDown(server.close);
    final small = FakeNzbServer(count: 49);
    await small.start();
    addTearDown(small.close);
    final out = await NntpTuner(timing: fast, testNzbUrl: small.url).run(provider(server), allowPrivate: true, depth: 4);
    expect((out as TuneFailed).failure, TuneFailure.testData);
  });

  test('a provider that refuses everyone is a connection failure, said as Test provider says it', () async {
    final server = FakeProvider(greeting: '502 go away');
    await server.start();
    addTearDown(server.close);
    final out = await tuner().run(provider(server), allowPrivate: true, depth: 4);
    expect((out as TuneFailed).failure, TuneFailure.connect);
    expect(out.result, NntpResult.refused);
  });

  test('a wrong password is a connection failure (sign-in)', () async {
    final server = FakeProvider(passReply: '481 bad password');
    await server.start();
    addTearDown(server.close);
    final out = await tuner().run(provider(server), allowPrivate: true, depth: 4);
    expect((out as TuneFailed).result, NntpResult.auth);
  });

  test('TLS turned on for a plain port is a secure-connection failure', () async {
    final server = FakeProvider();
    await server.start();
    addTearDown(server.close);
    final p = provider(server);
    final out = await tuner().run(p.copyWith(tls: true), allowPrivate: true, depth: 4);
    expect((out as TuneFailed).failure, TuneFailure.connect);
    expect(out.result, NntpResult.tls);
  });

  test('a local address needs Allow self-hosted servers', () async {
    final server = FakeProvider();
    await server.start();
    addTearDown(server.close);
    final out = await tuner().run(provider(server), allowPrivate: false, depth: 4);
    expect((out as TuneFailed).result, NntpResult.privateNetwork);
    expect(server.connections, 0);
  });
}
