// FebBox, a film source that plays from your own FebBox account (febbox.js ported 2026-11-26).
// Here a made-up Showbox and FebBox answer: how the title is looked up, which file is taken for
// a film and for an episode, the sizes that come back, what the token does once FebBox takes it
// (the source on, and first), and the token's row in Settings > Sources with a remote.
// Against the real sites, outside the tests: the signing equals the original's byte for byte,
// Showbox finds a film with it, FebBox lists its folder and refuses a wrong token. With a real
// account (a token, the sizes of a file, the film playing): not run, there was none here.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/febbox.dart';
import 'package:vyse_tv/data/sources/film_sources/febbox_account.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';

import 'bed/phase8_pages.dart';
import 'harness.dart';

/// What `node` prints for febbox.js's own signing of [_payload] (encryptTripleDES, then the
/// form showboxRequest posts, before its random token).
const _payload = {'CHILD_MODE': '0', 'APP_VERSION': '11.5', 'expired_date': 1795000000, 'module': 'Search5', 'keyword': 'Dune: Part Two', 'type': 'movie', 'page': 1, 'pagelimit': 10};
const _sealed =
    'mdePKv/DGhMyVBz9HUJpKFWf5eGtTBtc+SksiNFGAk3DvCeke7oYvv7cpVNxzg1EJ0/GO0Jz4X9wpTgMpIG38LJHFNy4ZW1RcXmBdAf87Zv5CK3H0JBEoXSUvjSS8FJvRG9M65WR/xj783lfGyo8Wm3ePufqxCM2Eata65BIzacNfnIIlBT1U3w2/e5IaaTi+D3n4xOUYxc=';
const _form =
    'data=eyJhcHBfa2V5IjoiNjQwNWMyZTYwNDVmNjU5YjdmZGNkOTU3ZmU1MmZlOWEiLCJ2ZXJpZnkiOiIwODVjODNhODBjYjhhZGY1M2ZkYTA1NWQwMmQ0NzNjZSIsImVuY3J5cHRfZGF0YSI6Im1kZVBLdi9ER2hNeVZCejlIVUpwS0ZXZjVlR3RUQnRjK1Nrc2lORkdBazNEdkNla2U3b1l2djdjcFZOeHpnMUVKMC9HTzBKejRYOXdwVGdNcElHMzhMSkhGTnk0WlcxUmNYbUJkQWY4N1p2NUNLM0gwSkJFb1hTVXZqU1M4Rkp2Ukc5TTY1V1IveGo3ODNsZkd5bzhXbTNlUHVmcXhDTTJFYXRhNjVCSXphY05mbklJbEJUMVUzdzIvZTVJYWFUaStEM240eE9VWXhjPSJ9&appid=27&platform=android&version=129&medium=Website';

const _good = 'good-token'; // the one token the made-up FebBox takes

String _sizes(int fid) => '''
<div class="quality_list">
  <div class="file_quality" data-url="https://cdn.febbox.test/$fid/org.mkv?k=1&amp;sign=abc" data-quality="ORG"><p class="name">ORIGINAL</p></div>
  <div class="file_quality" data-url="https://cdn.febbox.test/$fid/2160.mp4" data-quality="4K"><p class="name">4K</p></div>
  <div class="file_quality" data-url="https://cdn.febbox.test/$fid/1080.mp4" data-quality="1080P"><p class="name">1080P</p></div>
  <div class="file_quality" data-url="https://cdn.febbox.test/$fid/360.mp4" data-quality="360P"><p class="name">360P</p></div>
</div>''';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  late FakeRoute route;
  var down = false; // FebBox is not answering
  setUp(() {
    down = false;
    Bed.http.seen.clear();
    Bed.http.sent.clear();
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      final q = uri.queryParameters;
      final signedIn = Bed.http.sent['$method $uri']?['cookie'] == 'ui=$_good';
      final login = FakeReply.json({'code': -1, 'msg': 'Please login', 'login_required': 1});
      return switch ((method, uri.host, uri.path)) {
        ('GET', 'api.themoviedb.org', '/3/movie/693134') => FakeReply.json({'title': 'Dune: Part Two', 'release_date': '2024-02-27'}),
        ('GET', 'api.themoviedb.org', '/3/tv/1396') => FakeReply.json({'name': 'Breaking Bad', 'first_air_date': '2008-01-20'}),
        ('GET', 'api.themoviedb.org', '/3/movie/5') => FakeReply.json({'title': 'A Film Showbox Has Never Heard Of', 'release_date': '1999-01-01'}),
        // (the route sees no request body: it answers every search with all it has, and the
        // title, the kind and the year pick among them, as they do for real)
        ('POST', 'mbpapi.shegu.net', '/api/api_client/index/') => FakeReply.json({
          'code': 1,
          'data': [
            {'id': 11, 'box_type': 1, 'title': 'Dune', 'year': 2021},
            {'id': 49959, 'box_type': 1, 'title': 'Dune: Part Two', 'year': 2024},
            {'id': 78, 'box_type': 1, 'title': 'El Camino: A Breaking Bad Movie', 'year': 2019},
            {'id': 77, 'box_type': 2, 'title': 'Breaking Bad', 'year': 2008},
          ],
        }),
        ('GET', 'www.showbox.media', '/index/share_link') => switch ((q['id'], q['type'])) {
          ('49959', '1') => FakeReply.json({'code': 1, 'msg': 'success', 'data': {'link': 'https://www.febbox.com/share/qnn024wq'}}),
          ('77', '2') => FakeReply.json({'code': 1, 'msg': 'success', 'data': {'link': 'https://www.febbox.com/share/bbad0001'}}),
          _ => null,
        },
        ('GET', 'www.febbox.com', '/file/file_share_list') => switch ((q['share_key'], q['parent_id'])) {
          ('qnn024wq', '0') => FakeReply.json({
            'code': 1,
            'data': {
              'file_list': [
                {'fid': 9, 'file_name': 'Extras', 'is_dir': 1},
                {'fid': 501, 'file_name': 'Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265.mkv', 'is_dir': 0},
                {'fid': 502, 'file_name': 'Dune.Part.Two.2024.1080p.BluRay.x264.mp4', 'is_dir': 0},
              ],
            },
          }),
          ('bbad0001', '0') => FakeReply.json({
            'code': 1,
            'data': {
              'file_list': [
                {'fid': 630, 'file_name': 'Season 30', 'is_dir': 1},
                {'fid': 601, 'file_name': 'season 1', 'is_dir': 1},
                {'fid': 603, 'file_name': 'Season 3', 'is_dir': 1},
              ],
            },
          }),
          ('bbad0001', '603') => FakeReply.json({
            'code': 1,
            'data': {
              'file_list': [
                {'fid': 7370, 'file_name': 'Breaking.Bad.S03E070.Special.mkv', 'is_dir': 0},
                {'fid': 7301, 'file_name': 'Breaking.Bad.S03E01.1080p.mkv', 'is_dir': 0},
                {'fid': 7307, 'file_name': 'Breaking.Bad.S03E07.1080p.mkv', 'is_dir': 0},
              ],
            },
          }),
          _ => null,
        },
        ('GET', 'www.febbox.com', '/console/video_quality_list') => !signedIn
            ? login
            : q['fid'] == '502'
            ? FakeReply.json({'code': 1, 'html': '<div class="file_quality" data-url="https://cdn.febbox.test/502/1080.mp4" data-quality="1080P"></div>'})
            : FakeReply.json({'code': 1, 'html': _sizes(int.parse(q['fid']!))}),
        ('GET', 'www.febbox.com', '/console/user_cards') => down
            ? const FakeReply(503, <int>[])
            : !signedIn
            ? login
            : FakeReply.json({
                'code': 1,
                'data': {
                  'user': {'username': 'ayla', 'is_vip': 1},
                  'flow': {'traffic_limit_mb': 102400, 'traffic_usage_mb': 20480},
                },
              }),
        _ => route(method, uri),
      };
    };
  });
  tearDown(() async {
    Bed.http.route = route;
    await FebBox.signOut();
    AppSettings.sourceOrder.set('');
    AppSettings.sourcesOff.set('');
  });

  Iterable<String> asked(String host) => Bed.http.seen.where((s) => s.contains('//$host/'));

  test("Showbox's request is sealed and signed as febbox.js does it (3DES, then the form it posts)", () {
    expect(showboxEncrypt(json.encode(_payload)), _sealed);
    expect(showboxForm(_payload), _form);
  });

  test('a film: found on Showbox by its title and year, its FebBox folder listed with your token, and each file a link with the sizes FebBox has of it', () async {
    febboxToken = _good;
    final found = await febbox(const FilmQuery(tmdbId: 693134, isTv: false));
    expect(found.length, 2, reason: 'the two video files; the folder beside them is not one: $found');

    final big = found.first;
    expect(big.url, 'https://cdn.febbox.test/501/1080.mp4', reason: 'it starts on 1080p, as febbox.js puts 1080p first');
    expect(big.quality, '1080p');
    expect(big.type, 'mp4');
    expect([for (final s in big.qualities) s.label], ['Original', '4K', '1080p', '360p'], reason: "the rest are the Quality menu's, in FebBox's own order");
    expect(big.qualities.first.url, 'https://cdn.febbox.test/501/org.mkv?k=1&sign=abc', reason: 'as a link, not as the page wrote it (&amp;)');
    expect(found.last.url, 'https://cdn.febbox.test/502/1080.mp4');
    expect(found.last.qualities, isEmpty, reason: 'a file in one size has nothing to choose');

    expect(asked('www.showbox.media').single, contains('share_link?id=49959&type=1'), reason: '"Dune: Part Two" of 2024, not "Dune"');
    final list = Bed.http.sent[asked('www.febbox.com').firstWhere((s) => s.contains('file_share_list'))]!;
    expect((list['cookie'], list['referer']), ('ui=$_good', 'https://www.febbox.com/share/qnn024wq'));
    final post = Bed.http.sent['POST https://mbpapi.shegu.net/api/api_client/index/']!;
    expect((post['user-agent'], post['platform'], post['content-type']), ('okhttp/3.2.0', 'android', 'application/x-www-form-urlencoded'));
  });

  test('an episode: its season folder (Season 3, not Season 30), then the file named for it (E07, not E070)', () async {
    febboxToken = _good;
    final found = await febbox(const FilmQuery(tmdbId: 1396, isTv: true, season: 3, episode: 7));
    expect(asked('www.showbox.media').single, contains('share_link?id=77&type=2'), reason: 'the show, not the film with its name in it');
    expect(asked('www.febbox.com').where((s) => s.contains('file_share_list')).last, contains('parent_id=603'));
    expect(found.single.url, 'https://cdn.febbox.test/7307/1080.mp4');

    Map<String, Object> f(int fid, String name, {bool dir = false}) => {'fid': fid, 'file_name': name, 'is_dir': dir ? 1 : 0};
    expect(febboxSeason([f(1, 'Season 10', dir: true), f(2, 'Season 1', dir: true)], 1)['fid'], 2);
    expect(febboxSeason([f(1, 'S02', dir: true), f(2, 'Show Season 02 1080p', dir: true)], 2)['fid'], 1);
    expect(febboxSeason([f(1, 'Whatever', dir: true)], 4)['fid'], 1, reason: 'no folder named for it: the first one, as febbox.js takes');
    expect(febboxEpisode([f(1, 'Show.1x010.mkv'), f(2, 'Show.1x01.mkv')], 1, 1)['fid'], 2);
    expect(febboxEpisode([f(1, 'Episode 12.mkv'), f(2, 'Episode 1.mkv')], 1, 1)['fid'], 2);
    expect(febboxEpisode([f(3, 'c.mkv'), f(1, 'a.mkv'), f(2, 'b.mkv')], 1, 2)['fid'], 2, reason: 'no name says: by its place in the folder');
    expect(febboxEpisode([f(1, 'a.mkv')], 1, 5), isNull);
  });

  test('nothing found, or a token FebBox does not take: no links, and no error', () async {
    febboxToken = _good;
    expect(await febbox(const FilmQuery(tmdbId: 5, isTv: false)), isEmpty, reason: 'no title on Showbox is close enough');
    expect(asked('www.febbox.com'), isEmpty);
    febboxToken = 'stale';
    expect(await febbox(const FilmQuery(tmdbId: 693134, isTv: false)), isEmpty, reason: 'FebBox says "Please login" for the sizes');
  });

  test('without a token FebBox is not asked at all, and is not among the sources a play goes through', () async {
    expect(febboxReady(), isFalse);
    expect(await febbox(const FilmQuery(tmdbId: 693134, isTv: false)), isEmpty);
    expect(Bed.http.seen.where((s) => s.contains('shegu') || s.contains('febbox')), isEmpty);
    expect(filmSources.last.id, 'febbox', reason: 'last in the default order: Movy stays first for everyone without an account');
    expect((filmSourceReady(FebBox.source), filmSourceOn(FebBox.source)), (false, false), reason: 'off, though nobody switched it off');
    expect(activeFilmSources().any((s) => s.id == 'febbox'), isFalse);
    expect(activeFilmSources().first.id, 'movy');
  });

  test('the token: one FebBox takes is kept, and FebBox is switched on and put first; one it does not take changes nothing', () async {
    // someone with an order of their own, who had switched FebBox and VidUp off
    AppSettings.sourceOrder.set(['cno', 'movy', for (final s in filmSources) if (s.id != 'cno' && s.id != 'movy') s.id].join(','));
    AppSettings.sourcesOff.set('febbox,vidup');
    final before = [for (final s in orderedFilmSources()) s.id];

    expect(await FebBox.signIn('not-a-token'), isNull);
    expect((febboxToken, FebBox.signedIn.value, FebBox.user.value), (null, false, null));
    expect([for (final s in orderedFilmSources()) s.id], before);
    expect(AppSettings.sourcesOff.value, 'febbox,vidup');

    down = true;
    await expectLater(FebBox.signIn(_good), throwsA(anything), reason: 'FebBox not answering is not "a wrong token"');
    expect(FebBox.signedIn.value, isFalse);
    down = false;

    final user = await FebBox.signIn('  ui=$_good;  '); // (pasted as the browser shows the cookie)
    expect(user?.describe, 'ayla · VIP · 80 GB of 100 GB left');
    expect((febboxToken, FebBox.signedIn.value, FebBox.user.value?.name), (_good, true, 'ayla'));
    expect([for (final s in orderedFilmSources()) s.id], ['febbox', ...before.where((id) => id != 'febbox')], reason: 'pulled to the top; the rest as they were');
    expect(AppSettings.sourcesOff.value, 'vidup', reason: 'FebBox on; what else was off stays off');
    expect([for (final s in activeFilmSources().take(3)) s.id], ['febbox', 'cno', 'movy']);

    await FebBox.signOut();
    expect((febboxToken, FebBox.signedIn.value), (null, false));
    expect(orderedFilmSources().first.id, 'febbox', reason: 'it stays where it is in the list');
    expect(activeFilmSources().first.id, 'cno', reason: 'and is skipped');
  });

  test('a token as people paste it', () {
    expect(febboxTidy('  abc.DEF-123  '), 'abc.DEF-123');
    expect(febboxTidy('ui=abc.DEF-123;'), 'abc.DEF-123');
    expect(febboxTidy('"abc.DEF-123"'), 'abc.DEF-123');
    expect(febboxTidy('PHPSESSID=x; ui=abc.DEF-123; other=1'), 'abc.DEF-123');
  });

  testWidgets('Settings > Sources: the FebBox token is asked for above the list. With a remote: Add token, a wrong one stays in the box with the reason, the right one switches FebBox on and puts it first', (t) async {
    await openSettings(t, 'Sources');
    Rect at(String text) => t.getRect(find.text(text).first);
    expect(at('FebBox UI token').top < at('Film and TV sources').top, isTrue, reason: 'above the list of sources');
    expect(find.text('Needs its token'), findsOneWidget, reason: "FebBox's own row in the list, until its token is there");

    await Bed.right(t);
    for (var i = 0; i < 4 && !Bed.focused().contains('Add token'); i++) {
      await Bed.up(t);
    }
    expect(Bed.focused(), contains('Add token'), reason: 'the first thing in the tab');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Paste your FebBox UI token'), findsOneWidget, reason: 'the box is open');

    await t.enterText(find.byType(TextField).last, 'not-a-token');
    await t.pump();
    await t.tap(find.text('Check and save'));
    await Bed.settle(t, rounds: 4);
    expect(find.textContaining("FebBox didn't accept that token"), findsOneWidget);
    expect(FebBox.signedIn.value, isFalse);

    await t.enterText(find.byType(TextField).last, _good);
    await t.testTextInput.receiveAction(TextInputAction.done); // (Enter, or the keyboard's Done)
    await Bed.settle(t, rounds: 6);
    expect(find.text('Paste your FebBox UI token'), findsNothing, reason: 'the box closed');
    expect(find.text('FebBox is on and asked first'), findsOneWidget);
    expect(find.text('ayla · VIP · 80 GB of 100 GB left'), findsOneWidget, reason: 'whose account it is, where the Add button was');
    expect(find.text('Needs its token'), findsNothing);
    expect(orderedFilmSources().first.id, 'febbox');
    expect(at('Asked first').center.dy, closeTo(at('Films and shows from your own FebBox account, up to 4K').top - 16, 24), reason: "on FebBox's row, now the first of the list");
    expect(at('Films and shows from your own FebBox account, up to 4K').top < at('Movy').top, isTrue);
    await t.pump(const Duration(seconds: 10)); // (the note goes)

    // Remove: the token is forgotten, and the row asks for one again
    await t.ensureVisible(find.text('Remove'));
    await t.tap(find.text('Remove'));
    await Bed.settle(t, rounds: 4);
    expect(FebBox.signedIn.value, isFalse);
    expect(find.text('Add token'), findsOneWidget);
    expect(find.text('Needs its token'), findsOneWidget);
  }, variant: OnScreens([Screens.laptop, Screens.tv]));
}
