// The built-in Usenet source on the sources screen (streaming mode off), on a TV and a phone:
// your indexer's releases listed as the Usenet addon's, each led by what it is ("4K Remux • DV
// HDR10 • HEVC"), its release name and details under it, and how it went before as a badge:
// AVAILABLE once it played, UNAVAILABLE (and last) once it was found gone from your providers.
// Pictured in docs/dpad/pictures/usenet; nothing may overflow, and the remote reaches the rows.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/usenet/usenet_play.dart';
import 'package:vyse_tv/data/usenet/usenet_release.dart';
import 'package:vyse_tv/data/usenet/usenet_sources.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';

import 'harness.dart';

void main() {
  late FakeRoute route;
  late Media film;
  var found = <AddonStream>[];

  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    film = Bed.freshTitle();
    final name = film.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '.').replaceAll(RegExp(r'^\.|\.$'), '');
    final year = film.year ?? '2020';
    const gb = 1000000000;
    final releases = [
      ('$name.$year.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.Atmos.7.1-FRAMESTOR', 61 * gb),
      ('$name.$year.1080p.WEB-DL.DDP5.1.H.264-FLUX', 6 * gb),
      ('$name.$year.1080p.BluRay.x264-SPARKS', 11 * gb),
      ('$name.$year.720p.WEB-DL.AAC2.0.H.264-NTb', 3 * gb),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'indexer.test') return route(method, uri);
      final q = uri.queryParameters;
      if (q['t'] == 'caps') {
        return FakeReply(
          200,
          utf8.encode(
            '<caps><limits max="100"/><searching><search available="yes" supportedParams="q"/>'
            '<movie-search available="yes" supportedParams="q,year"/><tv-search available="yes" supportedParams="q,season,ep"/></searching></caps>',
          ),
          type: 'application/xml',
        );
      }
      final items = [
        for (final (i, (title, size)) in releases.indexed)
          '<item><title>$title</title><guid>$i</guid><enclosure url="https://indexer.test/get/$i?apikey=k" length="$size" type="application/x-nzb"/>'
              '<pubDate>Mon, 23 Nov 2026 12:00:00 +0000</pubDate><newznab:attr name="size" value="$size"/></item>',
      ].join();
      return FakeReply(
        200,
        utf8.encode(
          '<rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/"><channel>'
          '<newznab:response offset="0" total="${releases.length}"/>$items</channel></rss>',
        ),
        type: 'application/rss+xml',
      );
    };
    UsenetSourcesStore.debugSet(
      UsenetSources(
        firstUseAccepted: true,
        providers: [UsenetProvider(name: 'Main', host: 'news.provider.test', username: 'u', password: 'p', connections: 30)],
        indexers: [UsenetIndexer(name: 'Geek', apiUrl: 'https://indexer.test', apiPath: '/api', apiKey: 'k')],
      ),
    );
    Addons.list.value = Addons.withBuiltIns(const []);
    Addons.setEnabled(Addon.knaben, false);
    Addons.setEnabled(Addon.usenet, true);
    await UsenetReleases.load();
    // searched once here, outside any test's clock: the sources screen finds it kept
    final target = await Addons.target(film);
    found = (await Addons.streams(Addon.usenet, target))?.streams ?? const [];
    // one played before, one found gone from the providers
    UsenetPlay.played(found.firstWhere((s) => s.description.contains('FLUX')));
    UsenetPlay.unplayable(found.firstWhere((s) => s.description.contains('SPARKS')), 'missing-article');
  });
  tearDownAll(() {
    Bed.http.route = route;
    Addons.list.value = const [];
    UsenetSourcesStore.debugSet(const UsenetSources());
  });

  testWidgets('the Usenet results: what each is, its details, AVAILABLE and UNAVAILABLE, the gone one last', (t) async {
    expect(found, hasLength(4), reason: 'every release on the indexer is this film');
    final problems = await Bed.overflows(() async {
      await Bed.pumpShell(t);
      await Bed.push(t, SourcesPage(media: film));
      for (var i = 0; i < 6; i++) {
        await Bed.settle(t, rounds: 1);
      }
      expect(find.textContaining('FRAMESTOR'), findsWidgets);
      expect(find.text('AVAILABLE'), findsOneWidget);
      await Bed.picture(t, 'usenet/sources');
      if (OnScreens.current == Screens.tv) {
        // the remote goes down into the list, row by row
        await Bed.down(t, times: 4);
        await Bed.picture(t, 'usenet/sources_ring');
      }
      // further down: the one gone from the providers, last
      await t.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await Bed.settle(t, rounds: 2);
      expect(find.text('UNAVAILABLE'), findsOneWidget);
      await Bed.picture(t, 'usenet/sources_end');
      final y = {for (final g in ['NTb', 'SPARKS']) g: t.getTopLeft(find.textContaining(g).first).dy};
      expect(y['SPARKS']!, greaterThan(y['NTb']!));
    });
    expect(problems, isEmpty);
    await Bed.back(t);
  }, variant: OnScreens(Screens.android));
}
