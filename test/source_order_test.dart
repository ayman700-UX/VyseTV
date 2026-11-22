import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';

void main() {
  test('every source once, however often its id was saved; removing a repository removes its sources', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      if (req.uri.path == '/repo.json') {
        req.response.write(jsonEncode({'name': 'R', 'plugins': [for (final i in ['p1', 'p2', 'p3']) {'id': i, 'name': i.toUpperCase(), 'version': '1', 'url': '$i.js'}]}));
      } else {
        req.response.write('// x');
      }
      req.response.close();
    });
    final repo = await JsPlugins.add('http://127.0.0.1:${server.port}/repo.json');
    final base = orderedFilmSources().length;
    final ids = orderedFilmSources().map((s) => s.id).toList();
    expect(ids.where((i) => i.startsWith('js:')).length, 3);

    // an older build saved every plugin id again and again: the list still shows each one once
    AppSettings.sourceOrder.value = [...ids, ...ids.where((i) => i.startsWith('js:')), ...ids.where((i) => i.startsWith('js:'))].join(',');
    expect(orderedFilmSources().length, base);
    expect({for (final s in orderedFilmSources()) s.id}.length, base);
    // the order is kept: the saved first ones stay first
    expect(orderedFilmSources().map((s) => s.id).take(3).toList(), ids.take(3).toList());

    // a reorder saves the clean list
    setFilmSourceOrder(orderedFilmSources().reversed.toList());
    expect(AppSettings.sourceOrder.value.split(',').toSet().length, base);

    // removing the repository takes its sources out, though their ids are still in the saved order
    JsPlugins.remove(repo);
    expect(orderedFilmSources().length, base - 3);
    expect(orderedFilmSources().any((s) => s.id.startsWith('js:')), isFalse);
  });
}
