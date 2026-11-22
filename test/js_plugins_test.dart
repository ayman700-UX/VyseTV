import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';

JsPlugin _p(String id, String version, {String url = 'https://x.test/a.js'}) => JsPlugin(id: id, name: id, url: url, code: 'code-$id', version: version);

void main() {
  test('GitHub links become raw links', () {
    expect(normalizeRepoUrl('https://github.com/me/repo/blob/main/repo.json'), 'https://raw.githubusercontent.com/me/repo/main/repo.json');
    expect(normalizeRepoUrl('https://github.com/me/repo'), 'https://raw.githubusercontent.com/me/repo/HEAD/repo.json');
    expect(normalizeRepoUrl('https://github.com/me/repo.git/'), 'https://raw.githubusercontent.com/me/repo/HEAD/repo.json');
    expect(normalizeRepoUrl(' https://example.com/x/repo.json '), 'https://example.com/x/repo.json');
  });

  test('repo file: relative urls, ids, types, bad entries', () {
    final r = parseRepoFile(
      '{"name":"R","plugins":[{"id":"a","name":"A","url":"a.js","types":["tv"]},{"name":"B","url":"https://x.test/b.js"},'
          '{"id":"a","url":"dup.js"},{"id":"bad id!","url":"c.js"},{"id":"f","url":"file:///etc/passwd"},{"id":"n"}]}',
      'https://host.test/dir/repo.json',
    );
    expect(r.name, 'R');
    expect(r.plugins.map((p) => p.id), ['a', 'b']);
    expect(r.plugins[0].url, 'https://host.test/dir/a.js');
    expect(r.plugins[0].types, ['tv']);
    expect(r.plugins[1].types, ['movie', 'tv']);
    expect(() => parseRepoFile('nope', 'https://h.test/r.json'), throwsFormatException);
    expect(() => parseRepoFile('{"x":1}', 'https://h.test/r.json'), throwsFormatException);
  });

  test('streams: only http(s) links, fields tidied', () {
    final s = parseStreams([
      {
        'url': 'https://a.test/x.m3u8',
        'quality': 1080,
        'headers': {'Referer': 'https://a.test'},
        'audio': 'Hindi',
      },
      {'url': 'javascript:alert(1)'},
      {'url': 'file:///etc/passwd'},
      {'nourl': 1},
      'junk',
    ]);
    expect(s.length, 1);
    expect(s[0].type, 'hls');
    expect(s[0].quality, '1080');
    expect(s[0].headers, {'Referer': 'https://a.test'});
    expect(s[0].audio, 'Hindi');
    expect(parseStreams('x'), isEmpty);
  });

  test('a script cannot reach this device or its network', () {
    for (final a in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.1',
      '192.168.1.37',
      '169.254.1.1',
      '100.64.0.1',
      '0.0.0.0',
      '::1',
      'fd00::1',
      'fe80::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(isPrivateAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '1.1.1.1', '2606:4700::1111']) {
      expect(isPrivateAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('update plan: same version kept, new or changed downloaded, removed dropped', () {
    final installed = [_p('a', '1'), _p('b', '2'), _p('c', '1'), _p('d', ''), _p('e', '1', url: 'https://x.test/old.js')];
    final plan = JsPlugins.planUpdate(installed, [
      (id: 'a', version: '1', url: 'https://x.test/a.js'), // unchanged
      (id: 'b', version: '3', url: 'https://x.test/a.js'), // version up
      (id: 'd', version: '', url: 'https://x.test/a.js'), // no version: always downloaded
      (id: 'e', version: '1', url: 'https://x.test/new.js'), // moved
      (id: 'f', version: '1', url: 'https://x.test/a.js'), // new
    ]);
    expect(plan.keep, ['a']);
    expect(plan.fetch, ['b', 'd', 'e', 'f']);
    expect(plan.drop, ['c']);
  });

  test('plugin log: stamped and tagged lines, capped, cleared', () {
    PluginLog.clear();
    PluginLog.add('MoviesMod', ['searching', 'found 3']);
    PluginLog.add('', ['no tag']);
    final l = PluginLog.lines.value;
    expect(l.length, 3);
    expect(l[0], matches(r'^\d\d:\d\d:\d\d \[MoviesMod\] searching$'));
    expect(l[2], matches(r'^\d\d:\d\d:\d\d no tag$'));
    PluginLog.add('X', [for (var i = 0; i < 400; i++) 'line $i']);
    expect(PluginLog.lines.value.length, 300); // the newest 300 are kept
    expect(PluginLog.lines.value.last, endsWith('line 399'));
    PluginLog.clear();
    expect(PluginLog.lines.value, isEmpty);
  });
}
