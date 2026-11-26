// An LG TV (webOS). The system there says it is Linux, so everything in the app that asks
// "what am I running on" is told apart by one switch (lib/core/platform/webos.dart): a TV, not
// a desktop; the remote in charge; the TV's own player as the video engine, with nothing in
// the menus, Settings or the phone page that the TV's player cannot do.
//
// The tests run on a PC, so "an LG TV" is stood in for (WebOS.debugIs), and the TV's player by
// the bed, like the other engines (Bed.tvCalls). None of this has seen a TV.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/layout.dart' show isDesktopNative;
import 'package:vyse_tv/core/lean.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/core/platform/webos.dart';
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/torrents.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Player;
import 'package:vyse_tv/screens/player/caption_overlay.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;

import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

void main() {
  setUpAll(() async {
    WebOS.debugIs = true;
    PlatformDetector.debugSetIsDesktopOSOverride(false); // (the PC the tests run on is one)
    await Bed.boot(as: TargetPlatform.linux);
    await TvDetectionService.getInstance();
  });
  tearDownAll(() {
    WebOS.debugIs = null;
    PlatformDetector.debugSetIsDesktopOSOverride(null);
  });
  final tv = OnScreens([Screens.tv]);

  /// Opens one of the player's menus the way a TV does: Settings (which holds More) with S, the
  /// others from their own key on the controls.
  Future<void> openMenu(WidgetTester t, String menu) async {
    PlayerPanel panel() => t.widget<PlayerPanel>(find.byType(PlayerPanel));
    if (panel().open) await Bed.back(t);
    if (menu == 'More') {
      await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    } else {
      await Bed.down(t); // the controls
      await Bed.focus(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == menu));
      await Bed.ok(t);
    }
    await Bed.settle(t, rounds: 3);
    expect(panel().open, isTrue);
  }

  test('an LG TV is a TV and no desktop, found out without asking Android', () {
    expect(PlatformDetector.isTV(), isTrue, reason: 'nobody forced it: the switch alone says so');
    expect(PlatformDetector.isDesktopOS(), isFalse);
    expect(isDesktopNative, isFalse, reason: 'no window to move, size or put a title bar on');
    expect(tvMenus, isTrue, reason: "the player's menus are the full-screen ones");
    Lean.decide();
    expect(Lean.on, isTrue, reason: 'drawn the lean way, as on an Android TV');
    expect(PlatformDetector.supportsExternalPlayers(), isFalse);
    expect(PlatformDetector.supportsAudioPassthrough(), isFalse, reason: "the TV's own sound settings decide");
  });

  test("the only engine is the TV's own player: there is no choice to offer", () {
    expect(PlayerEngine.offered, isFalse);
    expect(PlayerEngine.isMedia3, isFalse);
    final player = Player();
    addTearDown(player.dispose);
    expect(player.playerType, 'webos');
    expect(player.mpvCore, isFalse);
  });

  test('torrents play there, on less memory and fewer connections than a PC', () {
    expect(Torrents.supported, isTrue);
    expect(Torrents.memoryChoices, [64, 128, 256, 512]);
    expect(Torrents.memory, 128);
    expect(Torrents.connectionChoices, [50, 100, 150, 200]);
    expect(Torrents.connections, 100);
  });

  testWidgets('the app opens on Home with the remote in charge, and a pointer does not take over', (t) async {
    await Bed.pumpShell(t);
    BuildContext page() => t.element(find.byType(Scaffold).first);
    expect(InputModeTracker.isKeyboardMode(page()), isTrue, reason: 'D-pad mode from the first frame');
    await Bed.down(t);
    final first = Bed.focused();
    expect(first, isNot('nothing'), reason: 'the first press lands on a control');
    // (from here on: while Home was still loading there was nothing to hold focus yet)
    Bed.watchdog.clear();
    await Bed.right(t);
    await Bed.down(t);
    expect(Bed.focused(), isNot('nothing'));
    expect(Bed.focusInView(), isTrue);
    // the Magic Remote's pointer waking up is not a mouse: the ring stays
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(900, 500));
    await mouse.moveTo(const Offset(950, 520));
    await t.pump();
    expect(InputModeTracker.isKeyboardMode(page()), isTrue);
    await mouse.removePointer();
    expect(Bed.watchdog, isEmpty, reason: 'focus was not lost on the way');
  }, variant: tv);

  testWidgets("the player is the TV's own: no mpv, no Media3, and its subtitle lines are drawn by the app", (t) async {
    Bed.videoCalls.clear();
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    expect(Bed.exoCalls, isEmpty, reason: 'Media3 is not there');
    expect(Bed.videoCalls.where((c) => c.startsWith('initialize') || c.startsWith('open')), isEmpty, reason: 'and neither is mpv');
    expect(find.byType(CaptionOverlay), findsOneWidget, reason: 'the page draws a subtitle file itself');
    // it fills the page and is no part of the controls: nothing about them can move it
    expect(t.getSize(find.byType(CaptionOverlay)), t.getSize(find.byType(PlayerPage)));
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets("what the TV's player cannot do is not in the player's menus", (t) async {
    await Bed.openPlayer(t);

    await openMenu(t, 'More');
    expect(find.text('Aspect ratio'), findsOneWidget, reason: 'the shape and zoom are worked out in the app, so they stay');
    expect(find.text('Zoom'), findsOneWidget);
    expect(find.text('Ambient lighting'), findsNothing, reason: 'an mpv shader');
    expect(find.text('UPSCALING'), findsNothing, reason: 'mpv shaders');
    expect(find.text('HDR'), findsNothing, reason: "a desktop's switch: the TV does HDR by itself");
    expect(find.text('Picture-in-picture'), findsNothing);
    expect(find.text('Stream info'), findsOneWidget);
    await Bed.picture(t, 'webos/more');

    await openMenu(t, 'Audio');
    for (final gone in const ['Audio sync', 'Channels', 'Volume levelling', 'Passthrough']) {
      expect(find.text(gone), findsNothing, reason: "$gone is not the TV player's to set");
    }
    await Bed.picture(t, 'webos/audio');
    await Bed.closePlayer(t);
    expect(find.byType(PlayerPage), findsNothing);
  }, variant: tv);

  testWidgets('Settings > Subtitles: the whole look is offered (the app draws it), styled subtitles are not', (t) async {
    await openSettings(t, 'Subtitles');
    await Bed.settle(t);
    final page = find.byType(ProfilePage);
    final list = find.descendant(of: page, matching: find.byType(Scrollable)).last;
    expect(find.text('Font'), findsOneWidget, reason: 'drawn by the app, in the font chosen');
    await t.scrollUntilVisible(find.text('Keep on the picture'), 200, scrollable: list);
    expect(find.text('Keep on the picture'), findsOneWidget);
    await t.drag(list, const Offset(0, -2000));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Styled subtitles'), findsNothing, reason: "an LG TV's player reads them as plain text");
    expect(find.textContaining('libass'), findsNothing);
  }, variant: tv);

  test('the phone page has no sound and picture section, and no styled subtitles', () {
    final sections = phoneSections(fonts: const [SubtitleStyle.defaultFont]);
    expect(sections.map((s) => s.id), isNot(contains('player')));
    expect(sections.map((s) => s.id), containsAll(['playback', 'torrents', 'subtitles', 'appearance']));
    final subtitles = sections.firstWhere((s) => s.id == 'subtitles').items.map((i) => i.toJson()['title']).toList();
    expect(subtitles, contains('Font'));
    expect(subtitles, contains('Shadow'));
    expect(subtitles, isNot(contains('Show them')));
  });
}
