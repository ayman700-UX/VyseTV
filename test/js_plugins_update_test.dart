import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';

/// A repository served from this machine: install it, change one plugin's version, update, and see which
/// scripts were downloaded again.
void main() {
  test('auto-update downloads only the plugins whose version changed', () async {
    final hits = <String, int>{};
    var repoJson = {
      'name': 'T',
      'plugins': [
        {'id': 'a', 'name': 'A', 'version': '1', 'url': 'a.js'},
        {'id': 'b', 'name': 'B', 'version': '1', 'url': 'b.js'},
        {'id': 'c', 'name': 'C', 'version': '1', 'url': 'c.js'},
      ],
    };
    var code = {'a': 'function getStreams(){return[]} // a1', 'b': '// b1', 'c': '// c1'};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final id = path.replaceAll(RegExp(r'^/|\.js$'), '');
      if (path == '/repo.json') {
        req.response.write(jsonEncode(repoJson));
      } else if (code.containsKey(id)) {
        req.response.write(code[id]);
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/repo.json';

    // install: everything is downloaded
    final repo = await JsPlugins.add(url);
    expect(repo.plugins.map((p) => p.id), ['a', 'b', 'c']);
    expect(hits['/a.js'], 1);

    // nothing changed: only the repository file is read
    AppSettings.pluginAutoUpdate.value = true;
    hits.clear();
    await JsPlugins.autoUpdateIfDue(force: true);
    expect(hits, {'/repo.json': 1});
    expect(JsPlugins.status.value, 'Plugins are up to date');

    // b goes to version 2 (new code), c is dropped, d is new
    repoJson = {
      'name': 'T',
      'plugins': [
        {'id': 'a', 'name': 'A', 'version': '1', 'url': 'a.js'},
        {'id': 'b', 'name': 'B', 'version': '2', 'url': 'b.js'},
        {'id': 'd', 'name': 'D', 'version': '1', 'url': 'd.js'},
      ],
    };
    code = {'a': 'SHOULD NOT BE READ', 'b': '// b2', 'd': '// d1'};
    hits.clear();
    await JsPlugins.autoUpdateIfDue(force: true);
    expect(hits['/a.js'], isNull); // unchanged: not downloaded again
    expect(hits['/b.js'], 1);
    expect(hits['/d.js'], 1);
    final now = JsPlugins.repos.value.single.plugins;
    expect(now.map((p) => p.id), ['a', 'b', 'd']);
    expect(now.firstWhere((p) => p.id == 'a').code, contains('a1')); // kept its saved script
    expect(now.firstWhere((p) => p.id == 'b').code, '// b2');
    expect(JsPlugins.status.value, 'Updated 2 plugins: B, D');

    // the repository goes away: the installed plugins stay
    await server.close(force: true);
    await JsPlugins.autoUpdateIfDue(force: true);
    expect(JsPlugins.repos.value.single.plugins.length, 3);
    expect(JsPlugins.status.value, contains('could not reach 1 repository'));
  });

  test('the daily check waits, and does nothing when it is switched off', () async {
    AppSettings.pluginAutoUpdate.value = false;
    JsPlugins.status.value = null;
    await JsPlugins.autoUpdateIfDue();
    expect(JsPlugins.status.value, isNull); // off: nothing happened
    AppSettings.pluginAutoUpdate.value = true;
    AppSettings.pluginsChecked.value = DateTime.now().millisecondsSinceEpoch; // checked just now
    await JsPlugins.autoUpdateIfDue();
    expect(JsPlugins.status.value, isNull); // less than a day: skipped
  });

  test('a repository whose repo.json is deleted (404) is dropped with its plugins; one that is only unreachable stays', () async {
    var gone = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      if (gone) {
        req.response.statusCode = 404;
      } else if (req.uri.path == '/repo.json') {
        req.response.write(jsonEncode({'name': 'Gone soon', 'plugins': [{'id': 'zed', 'name': 'ZedGone', 'version': '1', 'url': 'zed.js'}]}));
      } else {
        req.response.write('// zed');
      }
      req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/repo.json';
    await JsPlugins.add(url);
    expect(JsPlugins.repos.value.any((r) => r.url == url), isTrue);
    expect(pluginSources.any((s) => s.name == 'ZedGone'), isTrue);
    AppSettings.pluginAutoUpdate.value = true;

    gone = true; // the file is deleted on the server
    await JsPlugins.autoUpdateIfDue(force: true);
    expect(JsPlugins.repos.value.any((r) => r.url == url), isFalse); // the repository and its sources are gone
    expect(pluginSources.any((s) => s.name == 'ZedGone'), isFalse);
    expect(JsPlugins.status.value, contains('Removed Gone soon'));

    // a manual refresh of a link that is gone says so
    await expectLater(JsPlugins.add(url), throwsA(isA<RepoGone>()));
  });
}
