// Settings > Usenet: your own sorting profile's rules, what Edit on your phone may change and
// what it never sends back, and the tab's first-use notice, Test provider and Delete source.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/usenet_profile_json.dart';
import 'package:vyse_tv/data/usenet/usenet_ranking.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';

UsenetProvider _main() => UsenetProvider(id: 'p1', name: 'Main', host: 'news.example.com', username: 'me', password: 'secret-pw', connections: 30);
UsenetProvider _backup() => UsenetProvider(id: 'p2', name: 'Backup', host: 'backup.example.com', password: 'other-pw', priority: 2, enabled: false);
UsenetIndexer _geek() => UsenetIndexer(id: 'i1', name: 'Geek', apiUrl: 'https://idx.example/?custom=abc', apiPath: '/api', apiKey: 'key-123');

List<PhoneItem> _phone() => phoneSections(fonts: const []).firstWhere((s) => s.id == 'usenet').items;
PhoneItem _item(String id) => _phone().firstWhere((i) => i.id == id);
Future<PhoneTook?> _send(String id, Object? v) => _item(id).take({'id': id, 'v': v});
String _state() => jsonEncode([for (final i in _phone()) i.toJson()]);

/// The real fonts, so text is as wide as in the app (the test font draws every letter as a box).
Future<void> _fonts() async {
  const dir = 'C:/tools/flutter/bin/cache/artifacts/material_fonts';
  if (!Directory(dir).existsSync()) return;
  ByteData bytes(File f) => ByteData.view(Uint8List.fromList(f.readAsBytesSync()).buffer);
  final roboto = FontLoader('Roboto');
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final n = f.path.toLowerCase();
    if (n.contains('roboto-') && n.endsWith('.ttf')) roboto.addFont(Future.value(bytes(f)));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(Future.value(bytes(File('$dir/materialicons-regular.otf'))))).load();
}

ThemeData _theme() {
  final t = ThemeData.dark();
  return t.copyWith(textTheme: t.textTheme.apply(fontFamily: 'Roboto'));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    await _fonts();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    UsenetSourcesStore.debugSet(UsenetSources(firstUseAccepted: true, providers: [_main(), _backup()], indexers: [_geek()]));
  });

  group('your own sorting profile', () {
    test('Balanced and a new profile are profiles the ranking reads', () {
      for (final p in [UsenetProfileJson.balanced(), UsenetProfileJson.empty()]) {
        expect(UsenetProfileJson.problem(p), isNull);
        expect(RankingProfile.fromJson(p), isNotNull);
      }
      expect((UsenetProfileJson.balanced()['rules'] as List).length, 14);
      expect((UsenetProfileJson.balanced()['tiers'] as List).length, 10);
    });

    test('copied and pasted, a profile comes back the same', () {
      final p = UsenetProfileJson.balanced();
      final back = UsenetProfileJson.parse(UsenetProfileJson.export(p));
      expect(back.problem, isNull);
      expect(jsonEncode(back.profile), jsonEncode(p));
    });

    test('what the ranking cannot use is refused, saying where', () {
      Map<String, Object?> withRule(String field, String op, String value) =>
          {...UsenetProfileJson.empty(), 'rules': [{...UsenetProfileJson.newRule(), 'name': 'R', 'conditions': [{'field': field, 'operator': op, 'value': value}]}]};
      expect(UsenetProfileJson.problem(withRule('TITLE', 'MATCHES', '(?=x)y')), contains('Rule 1 (R)'));
      expect(UsenetProfileJson.problem(withRule('TITLE', 'MATCHES', r'(x)\1')), contains('refer back'));
      expect(UsenetProfileJson.problem(withRule('TITLE', 'MATCHES', '[')), isNotNull);
      expect(UsenetProfileJson.problem(withRule('SIZE_GB', 'AT_MOST', 'big')), contains('number'));
      expect(UsenetProfileJson.problem(withRule('GROUP', 'AT_LEAST', '3')), isNotNull);
      expect(UsenetProfileJson.problem(withRule('GROUP', 'IS', ' ')), contains('value'));
      expect(UsenetProfileJson.problem(withRule('RESOLUTION', 'AT_LEAST', '720')), isNull);
      expect(UsenetProfileJson.parse('{"format":"vysetv.sorting-profile","version":2,"profile":{}}').problem, contains('version'));
      expect(UsenetProfileJson.parse('not json').profile, isNull);
      final many = {...UsenetProfileJson.empty(), 'tiers': [for (var i = 0; i < 25; i++) UsenetProfileJson.newTier()]};
      expect(UsenetProfileJson.problem(many), contains('24'));
    });
  });

  group('Edit on your phone', () {
    test('a new provider is filled in box by box and saved, its password never sent back', () async {
      await _send('usenet.provider', '');
      await _send('usenet.provider.name', ' Phone provider ');
      await _send('usenet.provider.host', 'phone.example.com');
      await _send('usenet.provider.port', '443');
      await _send('usenet.provider.password', 'typed-pw');
      expect((await _send('usenet.provider.connections', '5000'))!.note!.bad, isTrue);
      await _send('usenet.provider.connections', '12');
      final took = await _send('usenet.provider.save', null);
      expect(took!.note!.text, 'Saved on the TV.');
      final p = UsenetSourcesStore.current.value.providers.firstWhere((p) => p.name == 'Phone provider');
      expect([p.host, p.port, p.password, p.connections, p.enabled], ['phone.example.com', 443, 'typed-pw', 12, true]);
      expect(_state(), isNot(contains('typed-pw')));
      expect(_state(), isNot(contains('secret-pw')));
    });

    test('a saved password is kept for the same server only, and on or off stays as the TV has it', () async {
      await _send('usenet.provider', 'p2');
      await _send('usenet.provider.name', 'Backup renamed');
      expect((await _send('usenet.provider.save', null))!.note!.bad, isFalse);
      final kept = UsenetSourcesStore.current.value.providers.firstWhere((p) => p.id == 'p2');
      expect([kept.name, kept.password, kept.enabled], ['Backup renamed', 'other-pw', false]);

      await _send('usenet.provider.host', 'elsewhere.example.com');
      final refused = await _send('usenet.provider.save', null);
      expect(refused!.note!.bad, isTrue);
      expect(refused.note!.text, contains('Enter the password or API key again'));
      expect((await _send('usenet.provider.test', null))!.note!.text, contains('Enter the password or API key again'));
      expect(UsenetSourcesStore.current.value.providers.firstWhere((p) => p.id == 'p2').host, 'backup.example.com');
    });

    test('Use TLS takes the usual port with it', () async {
      await _send('usenet.provider', '');
      await _send('usenet.provider.tls', false);
      expect(jsonDecode(jsonEncode(_item('usenet.provider.port').toJson()))['value'], '119');
      await _send('usenet.provider.port', '8443');
      await _send('usenet.provider.tls', true);
      expect(jsonDecode(jsonEncode(_item('usenet.provider.port').toJson()))['value'], '8443');
    });

    test("an indexer's query and key never reach the phone, and stay through an edit", () async {
      await _send('usenet.indexer', 'i1');
      expect(_state(), isNot(contains('custom=abc')));
      expect(_state(), isNot(contains('key-123')));
      final url = jsonDecode(jsonEncode(_item('usenet.indexer.url').toJson()))['value'];
      expect(url, 'https://idx.example/');
      await _send('usenet.indexer.url', url);
      await _send('usenet.indexer.fetch', 0);
      expect((await _send('usenet.indexer.save', null))!.note!.bad, isFalse);
      var saved = UsenetSourcesStore.current.value.indexers.single;
      expect([saved.apiUrl, saved.apiKey, saved.fetchLimit], ['https://idx.example/?custom=abc', 'key-123', 0]);
      await _send('usenet.indexer.fetch', -1);
      await _send('usenet.indexer.save', null);
      saved = UsenetSourcesStore.current.value.indexers.single;
      expect(saved.fetchLimit, isNull);
      expect(UsenetSourcesStore.current.value.maxResults, 50);

      await _send('usenet.indexer.path', '/v2/api');
      expect((await _send('usenet.indexer.save', null))!.note!.text, contains('Enter the password or API key again'));
    });

    test('a pasted profile becomes the sorting profile; a bad one is refused', () async {
      expect((await _send('usenet.profile', 'nonsense'))!.note!.bad, isTrue);
      expect(UsenetSourcesStore.current.value.customProfile, isNull);
      final took = await _send('usenet.profile', UsenetProfileJson.export(UsenetProfileJson.balanced()));
      expect(took!.note!.bad, isFalse);
      expect(UsenetSourcesStore.current.value.preset, UsenetPreset.custom);
      expect(UsenetSourcesStore.current.value.customProfile, isNotNull);
      expect(UsenetSourcesStore.current.value.providers.length, 2);
    });
  });

  group('the tab', () {
    // (set here, inside the test's clock: the tab waits for the sources to be read)
    Future<void> openTab(WidgetTester t, [UsenetSources? sources]) async {
      UsenetSourcesStore.debugSet(sources ?? UsenetSources(firstUseAccepted: true, providers: [_main(), _backup()], indexers: [_geek()]));
      t.view.physicalSize = const Size(1280, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: _theme(), home: const Scaffold(body: ProfilePage())));
      await t.pump();
      final tab = find.text('Usenet');
      if (find.text('Search built-in indexers').evaluate().isEmpty) {
        await t.tap(tab.first);
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }
    }

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    bool usenetOn() => Addons.list.value.firstWhere((a) => a.manifestUrl == Addon.usenet.manifestUrl).enabled;

    testWidgets('turning it on asks first, until the notice is accepted', (t) async {
      await openTab(t, UsenetSources(providers: [_main()], indexers: [_geek()]));
      expect(usenetOn(), isFalse);
      final row = find.ancestor(of: find.text('Search built-in indexers'), matching: find.byType(Row)).first;
      Future<void> flip() async {
        await t.tap(find.descendant(of: row, matching: find.byType(AnimatedContainer)).last);
        await settle(t);
      }

      await flip();
      expect(find.text('Turn on'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(usenetOn(), isFalse);
      expect(UsenetSourcesStore.current.value.firstUseAccepted, isFalse);

      await flip();
      await t.tap(find.text('Turn on'));
      await settle(t);
      expect(usenetOn(), isTrue);
      expect(UsenetSourcesStore.current.value.firstUseAccepted, isTrue);

      await flip();
      expect(find.text('Turn on'), findsNothing);
      expect(usenetOn(), isFalse);
      await flip();
      expect(find.text('Turn on'), findsNothing);
      expect(usenetOn(), isTrue);
    });

    testWidgets("a provider test's answer goes once a field changes", (t) async {
      AppSettings.usenetAllowPrivate.set(false);
      await openTab(t);
      if (find.text('Add NNTP provider').evaluate().isEmpty) {
        await t.tap(find.text('NNTP providers'));
        await settle(t);
      }
      await t.tap(find.text('Add NNTP provider'));
      await settle(t);
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'Local');
      await t.enterText(fields.at(1), '127.0.0.1');
      await t.tap(find.text('Test provider'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await settle(t);
      expect(find.textContaining('local network'), findsOneWidget);
      await t.enterText(fields.at(0), 'Local box');
      await settle(t);
      expect(find.textContaining('local network'), findsNothing);
      await t.tap(find.text('Cancel').last);
      await settle(t);
    });

    testWidgets('Delete source asks, and takes only that one', (t) async {
      await openTab(t);
      if (find.text('Main').evaluate().isEmpty) {
        await t.tap(find.text('NNTP providers'));
        await settle(t);
      }
      await t.tap(find.text('Main'));
      await settle(t);
      await t.tap(find.text('Delete source'));
      await settle(t);
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(UsenetSourcesStore.current.value.providers.length, 2);

      await t.tap(find.text('Main'));
      await settle(t);
      await t.tap(find.text('Delete source'));
      await settle(t);
      await t.tap(find.text('Delete source').last);
      await settle(t);
      expect([for (final p in UsenetSourcesStore.current.value.providers) p.id], ['p2']);
      expect(UsenetSourcesStore.current.value.indexers.length, 1);
    });
  });
}
