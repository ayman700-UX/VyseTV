import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';

const _manifest = '''[
  {"display_name":"Alpha","value":"alpha","version":"1.5","type":"global","disabled":false},
  {"display_name":"Off","value":"off","version":"1","disabled":true},
  {"display_name":"Torrents","value":"torrentio","version":"1"},
  {"display_name":"Bad name","value":"bad value!","version":"1"},
  {"display_name":"Beta","value":"beta","version":"2","type":"india"},
  {"value":7}
]''';

// A provider that needs no network: it searches a fixed list, reads a page with cheerio, builds links with URL.
const _posts = r'''
exports.getSearchPosts = async function (a) {
  return a.searchQuery.toLowerCase().indexOf('oppenheimer') === 0
    ? [{ title: 'Download Oppenheimer (2023) 1080p', link: '/oppenheimer-2023/', image: '' }, { title: 'Other (2001)', link: '/other/', image: '' }]
    : [];
};
''';
const _meta = r'''
exports.getMeta = async function (a) {
  const { cheerio } = a.providerContext;
  const $ = cheerio.load('<div class="dl"><a href="/go/1">720p</a><a href="/go/2">1080p</a></div>');
  const links = $('.dl a').map((i, e) => ({ title: $(e).text(), quality: $(e).text(), directLinks: [{ title: 'Movie', link: new URL($(e).attr('href'), 'https://site.test/').href, type: 'movie' }] })).get();
  return { title: 'Oppenheimer', image: '', synopsis: '', type: 'movie', linkList: links, imdbId: 'tt15398776' };
};
''';
const _stream = r'''
exports.getStream = async function (a) {
  const u = new URL(a.link);
  const sp = new URLSearchParams({ id: u.pathname.split('/').pop() });
  return [{ server: 'Alpha', link: 'https://cdn.test/v' + sp.get('id') + '.m3u8?x=' + sp.toString(), type: 'm3u8', quality: '1080' }, { server: 'DRM', link: 'https://cdn.test/d.mpd', type: 'mpd', drm: { type: 'widevine' } }];
};
''';

String _module(String name, String body) => '__vega.module("$name", function (exports, module, require, __awaiter, providerGlobal) {\n$body\n});\n';

void main() {
  test('a Vega manifest: disabled, non-film and badly named providers are left out', () {
    final r = parseRepoFile(_manifest, 'https://raw.example.com/me/vega/main/manifest.json');
    expect(r.plugins.map((p) => p.id), ['vega-alpha', 'vega-beta']);
    expect(r.plugins[0].url, 'https://raw.example.com/me/vega/main/dist/alpha');
    expect(r.plugins[0].version, '1.5');
    expect(r.plugins.every((p) => p.vega), isTrue);
    expect(r.plugins[1].note, contains('india'));
  });

  test('composing a Vega plugin: modules wrapped, episodes optional', () async {
    final asked = <String>[];
    final code = await composeVegaPlugin('https://h.test/r/dist/alpha', '1.5', (u) async {
      asked.add(u);
      if (u.endsWith('episodes.js')) throw HttpError(404, u);
      return '/*${u.split('/').last}*/';
    });
    expect(
      code,
      startsWith(
        '$vegaMarker'
        'alpha\n',
      ),
    );
    expect(code, contains('__vega.source("https://h.test/r", "alpha");'));
    expect(code, contains('__vega.module("posts"'));
    expect(code, contains('__vega.module("stream"'));
    expect(code, isNot(contains('"episodes"')));
    expect(asked.length, 4);
    await expectLater(composeVegaPlugin('https://h.test/r/dist/alpha', '1', (u) async => throw HttpError(500, u)), throwsA(isA<HttpError>()));
  });

  // The real QuickJS engine (libquickjs_c_bridge_plugin.so): run with LD_LIBRARY_PATH=build/linux/x64/release/bundle/lib
  final lib = File('build/linux/x64/release/bundle/lib/libquickjs_c_bridge_plugin.so');
  test('a Vega provider answers getStreams through the adapter, in the real engine', () async {
    final helpers = File('assets/plugins/helpers.js').readAsStringSync();
    final runtime = File('assets/plugins/vega_runtime.js').readAsStringSync();
    final code =
        '$runtime\n$vegaMarker'
        'alpha\n__vega.source("https://repo.test", "alpha");\n${_module('posts', _posts)}${_module('meta', _meta)}${_module('stream', _stream)}';
    final res = await executeScriptForTest(code, {
      'tmdbId': 872585,
      'imdbId': 'tt15398776',
      'type': 'movie',
      'isTv': false,
      'title': 'Oppenheimer',
      'originalTitle': 'Oppenheimer',
      'titles': ['Oppenheimer'],
      'isAnime': false,
      'year': 2023,
      'season': null,
      'episode': null,
    }, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    final streams = parseStreams(res['streams']);
    // 1080p first, then 720p; the DRM stream is dropped; types mapped; query string built by URLSearchParams
    expect(streams.length, 2, reason: '${res['log']}');
    expect(streams[0].url, contains('/v2.m3u8'));
    expect(streams[1].url, contains('/v1.m3u8'));
    expect(streams.every((s) => s.type == 'hls' && s.quality == '1080p'), isTrue);
  }, skip: lib.existsSync() ? false : 'needs a built Linux bundle (flutter build linux)');
}
