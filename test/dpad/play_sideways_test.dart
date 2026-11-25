// Play videos sideways (2026-11-23). The user: "add an option in the settings appearance for
// mobiles only: auto play horizontally, and when the user goes into player, automatically make
// it horizontal; if he turns it off, then just play it based on the phone's orientation".
//
// Booted as Android on a phone; the player's and Live TV's requests to turn the screen are what
// the page asks of the phone (SystemChrome), heard here. A TV and a computer don't offer it.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/live_tv/live_tv.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_player_page.dart';

import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  late FakeRoute route;
  setUp(() {
    AppSettings.playSideways.set(true);
    // a made-up film source with one link that answers, so the player gets past "No sources"
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    AppSettings.playSideways.set(true);
    debugFilmSources = null;
    Bed.http.route = route;
  });
  final phone = OnScreens([Screens.phone]);
  const landscape = ['landscapeLeft', 'landscapeRight'];

  /// What the pages asked of the phone's orientation, oldest first.
  final turns = <List<String>>[];
  void listenForTurns(WidgetTester t) {
    turns.clear();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        turns.add([for (final o in call.arguments as List) '$o'.replaceFirst('DeviceOrientation.', '')]);
      }
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Finder sidewaysRow() => find.text('Play videos sideways');

  /// The switch on the row of [title].
  Finder switchOf(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Row')).first,
    matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Switch'),
  );

  testWidgets('a phone: Settings > Appearance has Play videos sideways, on to start with; OK on its switch turns it off and on', (t) async {
    await openSettings(t, 'Appearance');
    expect(sidewaysRow(), findsOneWidget, reason: 'under Player, on a phone');
    expect(AppSettings.playSideways.value, isTrue, reason: 'on to start with');
    await Bed.dpadMode(t);
    await Bed.focus(t, switchOf('Play videos sideways'));
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    expect(AppSettings.playSideways.value, isFalse, reason: 'OK turns it off');
    await Bed.ok(t);
    expect(AppSettings.playSideways.value, isTrue, reason: 'and on again');
    await Bed.picture(t, 'sideways/settings_phone');
  }, variant: phone);

  testWidgets('on: the player opens sideways, the rotate button still turns it upright, and leaving lets go', (t) async {
    listenForTurns(t);
    await Bed.openPlayer(t);
    expect(turns.first, landscape, reason: 'sideways as it opens, whatever the rotation lock says');
    t.view.physicalSize = const Size(568, 320); // the phone turns
    await Bed.settle(t, rounds: 3);
    await t.tap(find.byTooltip('Turn upright'));
    await Bed.settle(t, rounds: 2);
    expect(turns.last, ['portraitUp'], reason: 'the rotate button still turns it the other way');
    t.view.physicalSize = const Size(390, 844);
    await Bed.settle(t, rounds: 3);
    await Bed.closePlayer(t);
    expect(turns.last, isEmpty, reason: 'out of the player the phone follows its own rotation setting again');
  }, variant: phone);

  testWidgets('off: the player goes the way the phone is held, and asks nothing of it', (t) async {
    AppSettings.playSideways.set(false);
    listenForTurns(t);
    await Bed.openPlayer(t);
    expect(turns, isEmpty, reason: 'nothing turned: it follows the phone');
    expect(find.byTooltip('Turn sideways'), findsOneWidget, reason: 'the rotate button is still there');
    await Bed.closePlayer(t);
    expect(turns, isEmpty);
  }, variant: phone);

  testWidgets('a live channel opens sideways too, and is let go on leaving; off, it follows the phone', (t) async {
    listenForTurns(t);
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: false));
    addTearDown(TvDetectionService.debugReset);
    await Bed.pumpShell(t);
    const channel = LiveItem(title: 'Harbour News', subtitle: 'Buddy  ·  News', url: 'http://list.test/news.m3u8');
    Future<void> watch() async {
      unawaited(Bed.sectionNavigator(t).push(MaterialPageRoute<void>(builder: (_) => const LiveTvPlayerPage(items: [channel], index: 0))));
      await Bed.settle(t, rounds: 4);
      expect(find.byType(LiveTvPlayerPage), findsOneWidget);
    }

    Future<void> leave() async {
      await Bed.dpadMode(t);
      for (var i = 0; i < 4 && find.byType(LiveTvPlayerPage).evaluate().isNotEmpty; i++) {
        await Bed.back(t);
      }
      expect(find.byType(LiveTvPlayerPage), findsNothing);
    }

    await watch();
    expect(turns.first, landscape);
    await leave();
    expect(turns.last, isEmpty, reason: 'the phone follows its own setting again');

    AppSettings.playSideways.set(false);
    turns.clear();
    await watch();
    await leave();
    expect(turns, isEmpty, reason: 'off: nothing turned');
  }, variant: phone);

  testWidgets('a TV and a computer have no such switch', (t) async {
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: true));
    addTearDown(TvDetectionService.debugReset);
    await openSettings(t, 'Appearance');
    expect(sidewaysRow(), findsNothing, reason: 'a TV');
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: false));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await openSettings(t, 'Appearance');
      expect(sidewaysRow(), findsNothing, reason: 'a computer');
    } finally {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    }
  }, variant: phone);
}
