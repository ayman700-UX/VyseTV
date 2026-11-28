// The last startup report: the four cards' rows, with the spec's examples, and how the report
// is kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/usenet/usenet_stats.dart';

Map<String, String> rows(DiagCard c) => {for (final r in c.rows) r.label: r.value};

UsenetStartupReport report({Map<String, double> marks = const {}, Map<String, Object?> engine = const {}, bool fastMkv = true}) =>
    UsenetStartupReport(fastMkv: fastMkv, fastNzb: true, recordedAt: DateTime(2026, 11, 28, 16, 5, 9), marks: marks, engine: engine);

void main() {
  test('no report: the summary alone, saying how to get one', () {
    final cards = UsenetDiagnostics.cards(null);
    expect(cards, hasLength(1));
    expect(cards.single.rows, isEmpty);
    expect(cards.single.note, contains('Play a Usenet stream'));
  });

  test('the summary: totals and spans from the app marks', () {
    final c = UsenetDiagnostics.cards(report(marks: const {
      'resolve_lock_acquired': 2,
      'engine_reused': 3,
      'engine_ready': 12.4,
      'session_request': 13,
      'session_response': 402.6,
      'resolved': 405,
      'prepare': 410,
      'decoder_init_duration': 33.2,
      'first_frame': 940,
    }));
    expect(c.map((x) => x.title), ['Last Usenet startup', 'Usenet startup · Engine', 'Usenet startup · NZB stages', 'Usenet startup · Cache']);
    final s = rows(c[0]);
    expect(s['Resolve to first frame'], '940 ms');
    expect(c[0].rows.firstWhere((r) => r.label == 'Resolve to first frame').highlight, isTrue);
    expect(s['Engine startup / reuse'], '10 ms');
    expect(s['Engine already running'], 'On');
    expect(s['Open Usenet session'], '390 ms');
    expect(s['Player handoff'], '5 ms');
    expect(s['Prepare to first frame'], '530 ms');
    expect(s['Video decoder setup'], '33 ms');
    expect(s['Fast MKV startup'], 'On');
    expect(s['Fast NZB fetch'], 'On');
    expect(s['When'], contains('2026'));
  });

  test('a mark missing, or a span that runs backwards, is a dash', () {
    final s = rows(UsenetDiagnostics.cards(report(marks: const {'session_request': 50, 'session_response': 20, 'prepare': 3}))[0]);
    expect(s['Open Usenet session'], '—');
    expect(s['Resolve to first frame'], '—');
    expect(s['Prepare to first frame'], '—');
    expect(s['Engine already running'], 'Off');
  });

  test('NZB stages: parse 321, index 400 to 454, filesystem 6', () {
    final c = UsenetDiagnostics.cards(report(engine: const {
      'marksMs': {'nzb_index_started': 400, 'nzb_index_finished': 454, 'nzb_cache_bound': 460, 'provider_setup_started': 1, 'pool_created': 9},
      'durationsMs': {'nzb_parse_work': 321, 'nzb_cache_io': 6, 'nzb_body_read': 77.5},
    }));
    final n = rows(c[2]);
    expect(n['NZB parse / decompress work'], '321 ms');
    expect(n['NZB index and write'], '54 ms');
    expect(n['Cache filesystem work'], '6 ms');
    expect(n['NZB body read time'], '78 ms');
    expect(n['Cache reopen'], '6 ms');
    expect(n['Provider pool setup'], '8 ms');
    expect(n['NZB cache lookup'], '—');
    expect(c[2].note, isNotNull);
  });

  test('the engine: prefetch, archive discovery and the longest request wait', () {
    final e = rows(UsenetDiagnostics.cards(report(engine: const {
      'marksMs': {'pool_created': 10, 'nzb_loaded': 60, 'content_selected': 95, 'warmup_started': 100, 'head_article_ready': 180, 'tail_article_ready': 230, 'first_media_bytes': 300},
      'archiveDiscoveryMs': 120,
      'ranges': [
        {'startMs': 10, 'firstByteMs': 50},
        {'startMs': 20, 'firstByteMs': -1},
        {'startMs': 5, 'firstByteMs': 125},
      ],
    }))[1]);
    expect(e['Startup prefetch'], 'Head and tail ready');
    expect(e['NZB loading (including cache)'], '50 ms');
    expect(e['Select and probe video'], '35 ms');
    expect(e['RAR continuation discovery'], '120 ms');
    expect(e['Longest request wait'], '120 ms');
    expect(e['Head article ready'], '80 ms');
    expect(e['Tail article ready'], '130 ms');
    expect(e['Session open to media bytes'], '300 ms');
  });

  test('prefetch: skipped, started, off, not applicable', () {
    String prefetch(Map<String, Object?> marks, {bool fastMkv = true}) => rows(UsenetDiagnostics.cards(report(engine: {'marksMs': marks}, fastMkv: fastMkv))[1])['Startup prefetch']!;
    expect(prefetch({'warmup_skipped_connection_limit': 1, 'head_article_ready': 2, 'tail_article_ready': 3}), 'Skipped: fewer than 3 connections');
    expect(prefetch({'warmup_started': 1, 'head_article_ready': 2}), 'Started; partly ready or budget limited');
    expect(prefetch({}, fastMkv: false), 'Off');
    expect(prefetch({}), 'Not applicable');
  });

  test('the cache: a hit of 41 943 040 bytes with no article hits', () {
    final k = rows(UsenetDiagnostics.cards(report(engine: const {
      'nzbCache': {'lookup': 'hit', 'bytes': 41943040},
      'store': {'cacheHits': 0, 'sharedJoins': 2, 'downloads': 40, 'cancellations': 1},
      'articleSlabsBytes': 12582912,
    }))[3]);
    expect(k['NZB disk cache'], 'Hit — reused from disk');
    expect(k['Cached NZB size'], '40.0 MiB');
    expect(k['Article cache hits'], '0');
    expect(k['Downloads shared'], '2');
    expect(k['Article downloads started'], '40');
    expect(k['Downloads cancelled'], '1');
    expect(k['Article buffers allocated'], '12.0 MiB');
    expect(k['NZB cache write'], '—');
  });

  test('the cache: a miss that was saved, the reasons and the write outcomes', () {
    Map<String, String> cache(Map<String, Object?> c) => rows(UsenetDiagnostics.cards(report(engine: {'nzbCache': c}))[3]);
    final saved = cache({'lookup': 'miss', 'write': 'saved', 'bytes': 18874368});
    expect(saved['NZB disk cache'], 'Miss — not cached');
    expect(saved['NZB cache write'], 'Saved');
    expect(saved['Cached NZB size'], '18.0 MiB');
    expect(saved['Article cache hits'], '—');
    expect(saved['Article buffers allocated'], '—');
    expect(cache({'lookup': 'miss', 'reason': 'expired'})['NZB disk cache'], 'Miss — expired');
    expect(cache({'lookup': 'miss', 'reason': 'invalid'})['NZB disk cache'], 'Miss — invalid cached file');
    expect(cache({'lookup': 'miss', 'reason': 'disk_error'})['NZB disk cache'], 'Disk access failed');
    expect(cache({'lookup': 'disabled'})['NZB disk cache'], 'Off');
    expect(cache({'lookup': 'miss', 'write': 'oversized', 'bytes': 99})['Cached NZB size'], '—');
    expect(cache({'write': 'oversized'})['NZB cache write'], 'Skipped — exceeds 64 MiB');
    expect(cache({'write': 'cancelled'})['NZB cache write'], 'Not saved — cancelled');
    expect(cache({'write': 'invalid'})['NZB cache write'], 'Not saved — invalid NZB');
    expect(cache({'write': 'disk_error'})['NZB cache write'], 'Disk access failed');
    expect(cache({'write': 'busy'})['NZB cache write'], 'Skipped — cache busy');
    expect(cache({})['NZB disk cache'], '—');
  });

  test('the trace marks each step once', () {
    final t = UsenetStartupTrace()..mark('prepare');
    final first = t.marks['prepare'];
    t.mark('prepare');
    t.duration('decoder_init_duration', const Duration(milliseconds: 12));
    expect(t.marks['prepare'], first);
    expect(t.marks['decoder_init_duration'], 12);
  });

  test('the last report is kept on this device and read back', () async {
    SharedPreferences.setMockInitialValues({});
    final d = UsenetDiagnostics.instance..debugRestart();
    await d.keep(report(marks: const {'first_frame': 940}, engine: const {
      'nzbCache': {'lookup': 'hit', 'bytes': 41943040},
    }));
    d.debugRestart();
    expect(d.last.value, isNull);
    await d.ensureLoaded();
    final back = d.last.value!;
    expect(back.marks['first_frame'], 940);
    expect(back.fastMkv, isTrue);
    expect(rows(UsenetDiagnostics.cards(back)[3])['Cached NZB size'], '40.0 MiB');
    await d.clear();
    d.debugRestart();
    await d.ensureLoaded();
    expect(d.last.value, isNull);
  });
}
