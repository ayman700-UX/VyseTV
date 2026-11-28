// The Tune connections dialog: what each state says, its buttons, Stop and Back, Apply saving
// only the port, TLS and allowance, and the summary of a result in Settings' words. The runs
// are scripted (the tuner itself is tuner_run_test.dart's), except the one that never leaves
// this computer.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/usenet/nntp.dart';
import 'package:vyse_tv/data/usenet/nntp_tuner.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';
import 'package:vyse_tv/screens/profile/usenet_tuner_dialog.dart';

final provider = UsenetProvider(id: 'p1', name: 'Main news', host: 'news.example.com', port: 563, tls: true, username: 'me', password: 'pw', connections: 100);

/// A run that goes the way the test says.
class ScriptedTuner extends NntpTuner {
  final _outcome = Completer<TuneOutcome>();
  void Function(TuneProgress)? progress;
  UsenetProvider? measured;
  int? depth;

  void finish(TuneOutcome o) {
    if (!_outcome.isCompleted) _outcome.complete(o);
  }

  @override
  Future<TuneOutcome> run(UsenetProvider provider, {required bool allowPrivate, required int depth, void Function(TuneProgress progress)? onProgress, TuneCancel? cancel}) {
    measured = provider;
    this.depth = depth;
    progress = onProgress;
    cancel?.whenCancelled.then((_) => finish(const TuneStopped([TuneReading(port: 563, tls: true, connections: 8, mbps: 300)])));
    return _outcome.future;
  }
}

TuneSucceeded result({int? limit = 53, int tried = 54, int port = 563, bool tls = true, int connections = 48, int fastest = 16}) => TuneSucceeded(
  limit: limit,
  tried: tried,
  port: port,
  tls: tls,
  connections: connections,
  fastestConnections: fastest,
  mbps: 400,
  downloadedBytes: 1234000000,
  readings: [
    TuneReading(port: port, tls: tls, connections: 16, mbps: 410.4),
    TuneReading(port: port, tls: tls, connections: 16, mbps: 399.6),
    const TuneReading(port: 443, tls: true, connections: 8, mbps: 200),
  ],
);

void main() {
  // made when the dialog asks for it, inside the test's clock
  ScriptedTuner? made;
  int? answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    UsenetSourcesStore.debugSet(UsenetSources(providers: [provider]));
    made = null;
    debugMakeTuner = () => made = ScriptedTuner();
    answer = -1;
  });
  tearDown(() => debugMakeTuner = null);

  Future<void> open(WidgetTester t, {double width = 900}) async {
    t.view.physicalSize = Size(width, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(child: TextButton(onPressed: () async => answer = await showConnectionTuner(context, provider), child: const Text('open'))),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('before it starts: what it does, Cancel and Start; Cancel changes nothing', (t) async {
    await open(t);
    expect(find.text('Tune Main news'), findsOneWidget);
    expect(find.textContaining('Nothing is saved until you apply the result.'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Tune Main news'), findsNothing);
    expect(answer, isNull);
  });

  testWidgets('running: the progress line and the readings so far, Stop alone', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    expect(made!.measured!.id, 'p1');
    expect(made!.depth, 4);
    expect(find.text('Connecting to the provider…'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    made!.progress!(const TuneProgress(phase: TunePhase.limit, count: 16));
    await t.pump();
    expect(find.text('Checking the connection limit: 16 accepted so far…'), findsOneWidget);
    made!.progress!(const TuneProgress(phase: TunePhase.port, count: 8, port: 443, tls: true, readings: [TuneReading(port: 563, tls: true, connections: 8, mbps: 312.4)]));
    await t.pump();
    expect(find.text('Measuring port 443 with 8 connections…'), findsOneWidget);
    expect(find.text('Port 563, 8 connections: 312 Mbps'), findsOneWidget);
    made!.finish(result());
    await t.pumpAndSettle();
  });

  testWidgets('Stop: stopped, nothing changed, the readings, Run again and Close', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(find.text('Stopped. Nothing was changed.'), findsOneWidget);
    expect(find.text('Port 563, 8 connections: 300 Mbps'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(answer, isNull);
    expect(UsenetSourcesStore.current.value.providers.single.connections, 100);
  });

  testWidgets('Back while measuring is Stop, not a close', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    await t.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await t.pumpAndSettle();
    expect(find.text('Tune Main news'), findsOneWidget);
    expect(find.text('Stopped. Nothing was changed.'), findsOneWidget);
    await t.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await t.pumpAndSettle();
    expect(find.text('Tune Main news'), findsNothing);
  });

  testWidgets('a result to apply: the summary, Cancel and Apply; Apply saves port, TLS and allowance only', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    made!.finish(result(port: 443, connections: 48));
    await t.pumpAndSettle();
    expect(find.text('Connection limit: 53. The next connection was refused.'), findsOneWidget);
    expect(find.textContaining('The current allowance of 100 is above the limit'), findsOneWidget);
    expect(find.text('16 connections already reach 405 Mbps.'), findsOneWidget);
    expect(find.textContaining('Recommended: port 443 with a connection allowance of 48 (now port 563 with 100).'), findsOneWidget);
    expect(find.text('Test data downloaded: 1.2 GB'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await t.tap(find.text('Apply'));
    await t.pumpAndSettle();
    expect(find.text('Tune Main news'), findsNothing);
    expect(answer, 48);
    final saved = UsenetSourcesStore.current.value.providers.single;
    expect((saved.port, saved.tls, saved.connections), (443, true, 48));
    expect((saved.name, saved.host, saved.username, saved.password, saved.priority), (provider.name, provider.host, provider.username, provider.password, provider.priority));
  });

  testWidgets('nothing to change: Run again and Close', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    made!.finish(result(limit: null, tried: 200, connections: 100));
    await t.pumpAndSettle();
    expect(find.text('Connection limit: none found up to 200 connections.'), findsOneWidget);
    expect(find.text('Nothing to apply: the current port and connection allowance are already the best choice.'), findsOneWidget);
    expect(find.text('Apply'), findsNothing);
    expect(find.text('Run again'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(answer, isNull);
  });

  testWidgets('a failure: its message, Run again starts over', (t) async {
    await open(t);
    await t.tap(find.text('Start'));
    await t.pump();
    made!.finish(const TuneFailed(TuneFailure.connect, result: NntpResult.auth));
    await t.pumpAndSettle();
    expect(find.text(nntpResultText(NntpResult.auth)), findsOneWidget);
    final next = ScriptedTuner();
    debugMakeTuner = () => next;
    await t.tap(find.text('Run again'));
    await t.pump();
    expect(next.measured, isNotNull);
    expect(find.text('Stop'), findsOneWidget);
    next.finish(const TuneFailed(TuneFailure.missingArticles));
    await t.pumpAndSettle();
    expect(find.text('This provider does not have the test articles, so its speed could not be measured.'), findsOneWidget);
  });

  testWidgets('a provider deleted meanwhile: Start closes the dialog', (t) async {
    await open(t);
    UsenetSourcesStore.debugSet(const UsenetSources());
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();
    expect(find.text('Tune Main news'), findsNothing);
    expect(made, isNull);
  });

  testWidgets('a narrow phone: nothing overflows', (t) async {
    await open(t, width: 340);
    await t.tap(find.text('Start'));
    await t.pump();
    made!.finish(result(port: 443));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('a local address without Allow self-hosted servers (the real tuner): said at once', (t) async {
    debugMakeTuner = null;
    UsenetSourcesStore.debugSet(UsenetSources(providers: [provider.copyWith(host: '127.0.0.1')]));
    await open(t);
    await t.tap(find.text('Start'));
    for (var i = 0; i < 20 && find.text('Close').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(nntpResultText(NntpResult.privateNetwork)), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
  });

  test('progress lines', () {
    expect(tuneProgressText(null), 'Connecting to the provider…');
    expect(tuneProgressText(const TuneProgress(phase: TunePhase.connections, count: 48)), 'Measuring 48 connections…');
    expect('${const TuneReading(port: 563, tls: true, connections: 8, mbps: 412.5)}', 'Port 563, 8 connections: 413 Mbps');
  });

  test('failures, said as Test provider says them where they are connection failures', () {
    expect(tuneFailureText(const TuneFailed(TuneFailure.connect)), nntpResultText(NntpResult.unreachable));
    expect(tuneFailureText(const TuneFailed(TuneFailure.testData)), 'Could not download the test data. Check the internet connection and try again.');
    expect(tuneFailureText(const TuneFailed(TuneFailure.tooSlow)), 'Too little arrived to measure a speed. Try again later.');
  });

  test('the summary without a limit has no over-the-limit line', () {
    final lines = tuneSummary(result(limit: null, tried: 100, connections: 100), provider);
    expect(lines, hasLength(4));
    expect(result(connections: 100).differsFrom(provider), isFalse);
    expect(result(port: 443).differsFrom(provider), isTrue);
  });

  test('sizes in decimal units', () {
    expect(shortSize(999), '999 B');
    expect(shortSize(1234000000), '1.2 GB');
    expect(shortSize(840000000), '840 MB');
    expect(shortSize(4100000000), '4.1 GB');
  });
}
