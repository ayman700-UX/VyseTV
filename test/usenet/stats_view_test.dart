// Settings' statistics and startup cards as built, at a phone's, a TV's and a desktop's widths:
// what shows, what doesn't, nothing overflowing, the choices and Reset statistics working.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';
import 'package:vyse_tv/data/usenet/usenet_stats.dart';
import 'package:vyse_tv/screens/profile/usenet_stats_view.dart';

const widths = [340.0, 620.0, 1000.0];

Future<void> pumpAt(WidgetTester t, double width, Widget child) async {
  t.view.physicalSize = Size(width, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  final stats = UsenetStats.instance;
  final p1 = UsenetProvider(id: 'p1', name: 'A provider with a rather long name for a narrow phone', host: 'news.one.example', username: 'me', password: 'pw');
  final p2 = UsenetProvider(id: 'p2', name: 'Backup', host: 'news.two.example', priority: 2);
  final i1 = UsenetIndexer(id: 'i1', name: 'First indexer', apiUrl: 'https://one.example', apiPath: '/api', apiKey: 'k');
  final i2 = UsenetIndexer(id: 'i2', name: 'Second', apiUrl: 'https://two.example', apiPath: '/api', apiKey: 'k');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stats.debugRestart();
    UsenetDiagnostics.instance.debugRestart();
    await stats.load();
  });

  void seed() {
    UsenetSourcesStore.debugSet(UsenetSources(providers: [p1, p2], indexers: [i1, i2]));
    stats.knownProviders([p1, p2]);
    stats.indexerSearch('i1', 'movie', 'answered', 12, const ['u1', 'u2']);
    stats.indexerSearch('i1', 'movie', 'failed', 0, const []);
    stats.indexerRequest('i1', 'movie', 'answered', 640);
    stats.grab('u1');
    stats.played('u1');
    stats.indexerSearch('i2', 'show', 'answered', 3, const ['u3']);
    stats.played('u3');
    stats.played('u3x');
    stats.providerReport([p1.serverUrl, p2.serverUrl], [
      {'server': 0, 'articles': 992, 'bytes': 734003200, 'missing': 8, 'errors': 50, 'ttfbMs': 35},
      {'server': 1, 'articles': 120, 'bytes': 9000000},
    ], refused: false, contentKind: 'movie');
  }

  for (final w in widths) {
    testWidgets('statistics at $w wide: the choices, the comparisons, a card per source, Reset', (t) async {
      seed();
      await pumpAt(t, w, const UsenetStatisticsSection());
      expect(t.takeException(), isNull);
      expect(find.text('Statistics period'), findsOneWidget);
      expect(find.text('Statistics content'), findsOneWidget);
      expect(find.text('Last 30 days'), findsOneWidget);
      expect(find.text('RELEASES PLAYED'), findsOneWidget);
      expect(find.text('NZB DOWNLOADS'), findsOneWidget);
      expect(find.text('ARTICLES SERVED'), findsOneWidget);
      expect(find.text('FIRST INDEXER'), findsOneWidget);
      expect(find.text('BACKUP'), findsOneWidget);
      expect(find.text('2 (1 failed)'), findsOneWidget);
      expect(find.text('99.2% (8 missing)'), findsOneWidget);
      expect(find.text('Reset statistics'), findsOneWidget);
    });
  }

  testWidgets('no sources set up: nothing at all', (t) async {
    UsenetSourcesStore.debugSet(const UsenetSources());
    await pumpAt(t, 620, const UsenetStatisticsSection());
    expect(find.text('Statistics period'), findsNothing);
  });

  testWidgets('one of each and nothing counted: no comparisons, "No data yet"', (t) async {
    UsenetSourcesStore.debugSet(UsenetSources(providers: [p2], indexers: [i2]));
    await pumpAt(t, 620, const UsenetStatisticsSection());
    expect(find.text('RELEASES PLAYED'), findsNothing);
    expect(find.text('ARTICLES SERVED'), findsNothing);
    expect(find.text('No data yet'), findsNWidgets(2));
  });

  testWidgets('All time adds Since; Shows leaves the films out; the choices are kept', (t) async {
    seed();
    await pumpAt(t, 1000, const UsenetStatisticsSection());
    expect(find.text('Since'), findsNothing);
    await t.tap(find.text('All time'));
    await t.pumpAndSettle();
    expect(find.text('Since'), findsNWidgets(4));
    await t.tap(find.text('Shows'));
    await t.pumpAndSettle();
    expect(find.text('FIRST INDEXER'), findsOneWidget);
    expect(find.text('No data yet'), findsNWidgets(3), reason: 'only the second indexer searched for a show');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('device.usenet.statsPeriod'), 'ALL_TIME');
    expect(prefs.getString('device.usenet.statsContent'), 'SHOWS');
  });

  testWidgets('Reset statistics asks, then clears every count', (t) async {
    seed();
    await pumpAt(t, 620, const UsenetStatisticsSection());
    await t.tap(find.text('Reset'));
    await t.pumpAndSettle();
    expect(find.text('Clear all provider and indexer statistics? This cannot be undone.'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(stats.indexer('i1').isEmpty, isFalse);
    await t.tap(find.text('Reset'));
    await t.pumpAndSettle();
    await t.tap(find.text('Clear'));
    await t.pumpAndSettle();
    // (the store was read outside this test's clock: its futures answer on the real one)
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(stats.indexer('i1').isEmpty, isTrue);
    expect(find.text('No data yet'), findsNWidgets(4));
  });

  for (final w in widths) {
    testWidgets('startup cards at $w wide', (t) async {
      await pumpAt(t, w, const UsenetDiagnosticsCard());
      expect(find.text('LAST USENET STARTUP'), findsOneWidget);
      expect(find.text('Play a Usenet stream to see its startup timings here.'), findsOneWidget);
      await UsenetDiagnostics.instance.keep(UsenetStartupReport(
        fastMkv: true,
        fastNzb: false,
        recordedAt: DateTime(2026, 11, 28, 16, 5),
        marks: const {'first_frame': 940, 'prepare': 400},
        engine: const {
          'nzbCache': {'lookup': 'hit', 'bytes': 41943040},
          'store': {'cacheHits': 0},
          'durationsMs': {'nzb_parse_work': 321},
        },
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('940 ms'), findsOneWidget);
      expect(find.text('540 ms'), findsOneWidget);
      expect(find.text('321 ms'), findsOneWidget);
      expect(find.text('40.0 MiB'), findsOneWidget);
      expect(find.text('USENET STARTUP · CACHE'), findsOneWidget);
    });
  }
}
