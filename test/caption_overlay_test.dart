// The subtitle lines the app draws itself where the engine draws none (an LG TV's player):
// lib/screens/player/caption_overlay.dart. Where they sit, that they follow Settings, and that
// they never take a press.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/core/lean.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/screens/player/caption_overlay.dart';

const _screen = Size(1920, 1080);

Future<StreamController<String>> show(WidgetTester t, {String initial = '', double? pictureAspect}) async {
  // (sync: a line is with the overlay as it is added, so one pump draws it)
  final lines = StreamController<String>.broadcast(sync: true);
  addTearDown(lines.close);
  t.view.physicalSize = _screen;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(children: [Positioned.fill(child: CaptionOverlay(lines: lines.stream, initial: initial, pictureAspect: pictureAspect))]),
    ),
  );
  return lines;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
  });
  setUp(SubtitleStyle.resetCaption);
  tearDown(() {
    SubtitleStyle.resetCaption();
    Lean.debugOn = null;
  });

  testWidgets('nothing is drawn until there is a line, and a line goes away again', (t) async {
    final lines = await show(t);
    expect(find.byType(Text), findsNothing);
    lines.add('Where were you?');
    await t.pump();
    expect(find.text('Where were you?'), findsWidgets);
    lines.add('');
    await t.pump();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('the line that was up when the page was built is shown at once', (t) async {
    await show(t, initial: 'Already speaking');
    expect(find.text('Already speaking'), findsWidgets);
  });

  testWidgets('two lines are two rows, in the middle, at the bottom, clear of the edge', (t) async {
    final lines = await show(t);
    lines.add('First row\nSecond row');
    await t.pump();
    final first = t.getRect(find.text('First row').last), second = t.getRect(find.text('Second row').last);
    expect(first.bottom, lessThanOrEqualTo(second.top + 1));
    expect(second.center.dx, closeTo(_screen.width / 2, 1));
    // mpv's own margin: 22 lines of a 720-line screen
    expect(_screen.height - second.bottom, closeTo(22 * 1080 / 720, 12));
  });

  testWidgets('they sit where Settings says: lifted from the edge, or at the top', (t) async {
    final lines = await show(t);
    lines.add('A line');
    await t.pump();
    final resting = t.getRect(find.text('A line').last).bottom;
    AppSettings.subtitleLift.set(20);
    await t.pump();
    expect(resting - t.getRect(find.text('A line').last).bottom, closeTo(.2 * 1080, 1), reason: '20% of the height further up');
    AppSettings.subtitleTop.set(true);
    await t.pump();
    expect(t.getRect(find.text('A line').last).top, closeTo(.2 * 1080 + 33, 12));
  });

  testWidgets('"Keep on the picture": a wide film\'s lines stay out of its black bar', (t) async {
    final lines = await show(t, pictureAspect: 2.4); // 1920 by 800 on a 1080 screen: 140 of bar
    lines.add('A line');
    await t.pump();
    AppSettings.subtitleOnPicture.set(false);
    await t.pump();
    final onScreen = t.getRect(find.text('A line').last).bottom;
    AppSettings.subtitleOnPicture.set(true);
    await t.pump();
    expect(onScreen - t.getRect(find.text('A line').last).bottom, closeTo(140, 1));
  });

  testWidgets('the look is the one from Settings: size, colour, bold, a box or an outline', (t) async {
    final lines = await show(t);
    lines.add('A line');
    await t.pump();
    TextStyle fill() => t.widget<Text>(find.text('A line').last).style!;
    // (sized as mpv sizes it: 1.3 times the setting on a 1080-line screen)
    expect(fill().fontSize, closeTo(AppSettings.subtitleSize.value * 1.3, .01));
    expect(fill().color, Color(AppSettings.subtitleColor.value));
    // out of the box, a box: the line once, on a backing three quarters solid
    expect(find.text('A line'), findsOneWidget, reason: 'with a box there is no outline');

    AppSettings.subtitleSize.set(40);
    AppSettings.subtitleColor.set(captionColors[1]);
    AppSettings.subtitleBold.set(false);
    AppSettings.subtitleItalic.set(true);
    await t.pump();
    expect(fill().fontSize, closeTo(52, .01));
    expect(fill().color, Color(captionColors[1]));
    expect(fill().fontWeight, FontWeight.w400);
    expect(fill().fontStyle, FontStyle.italic);

    AppSettings.subtitleBackground.set(0);
    await t.pump();
    expect(find.text('A line'), findsNWidgets(2), reason: 'an outline is the same line drawn under it');
    expect(find.ancestor(of: find.text('A line'), matching: find.byType(DecoratedBox)), findsNothing);
    final stroke = t.widget<Text>(find.text('A line').first).style!.foreground!;
    expect(stroke.style, PaintingStyle.stroke);
    expect(stroke.strokeWidth, closeTo(2 * 2.5 * 1080 / 720, .01), reason: "mpv's 2.5, for a 720-line screen, each side");

    AppSettings.subtitleBackground.set(75);
    await t.pump();
    final box = t.widget<DecoratedBox>(find.ancestor(of: find.text('A line'), matching: find.byType(DecoratedBox)).first);
    expect((box.decoration as BoxDecoration).color!.a, closeTo(.75, .01));
  });

  testWidgets('the lean interface draws no blur', (t) async {
    AppSettings.subtitleBackground.set(0); // (the blur softens the outline, and a box has none)
    AppSettings.subtitleBlur.set(20);
    final lines = await show(t);
    lines.add('A line');
    await t.pump();
    Paint outline() => t.widget<Text>(find.text('A line').first).style!.foreground!;
    expect(outline().maskFilter, isNotNull);
    Lean.debugOn = true;
    AppSettings.subtitleBlur.set(25); // (anything that has it built again)
    await t.pump();
    expect(outline().maskFilter, isNull);
  });

  testWidgets('a press goes through to what is under it', (t) async {
    var pressed = 0;
    final lines = StreamController<String>.broadcast();
    addTearDown(lines.close);
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => pressed++)),
            Positioned.fill(child: CaptionOverlay(lines: lines.stream, initial: 'A line over the video')),
          ],
        ),
      ),
    );
    await t.tap(find.text('A line over the video').last, warnIfMissed: false);
    expect(pressed, 1);
  });
}
