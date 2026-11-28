// Home's look, chosen in Settings > Appearance > Home (screens/home/home_look.dart): the cards of
// its rows (classic, posters, backdrops, mixed), their size, the hero carousel, the genre and
// collection cards, logo art or names on backdrop cards, and names under posters. On a TV and on
// a phone: each look pictured (docs/dpad/pictures/home_look) with no overflow, Home following a
// change at once, a remote going through rows-only Home, the switches in Settings and on the
// phone page. Out of the box nothing changes (the pointer-mode baseline pictures say so).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/screens/home/home_look.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/hero_carousel.dart';
import 'package:vyse_tv/widgets/media_rows.dart';

import 'bed/fake_addons.dart';
import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

/// Settings > Appearance > Home, as [look] says (no argument: out of the box).
void look({String cards = 'classic', String size = 'standard', bool hero = true, bool categories = true, bool logos = true, bool names = false}) {
  AppSettings.homeCards.value = cards;
  AppSettings.homeCardSize.value = size;
  AppSettings.homeHero.value = hero;
  AppSettings.homeCategories.value = categories;
  AppSettings.homeLogos.value = logos;
  AppSettings.homeNames.value = names;
}

Finder onHome(Finder f) => find.descendant(of: find.byType(HomePage), matching: f);

Future<void> scrollHome(WidgetTester t, double to) async {
  final list = t.state<ScrollableState>(onHome(find.byType(Scrollable)).first);
  list.position.jumpTo(to.clamp(0, list.position.maxScrollExtent));
  await Bed.settle(t, rounds: 4);
}

/// Whether a title's name shows at rest on [card] (the details under the mouse are see-through).
bool nameShows(WidgetTester t, Finder card, String title) => find
    .descendant(of: card, matching: find.text(title))
    .evaluate()
    .any((e) => e.findAncestorWidgetOfExactType<AnimatedOpacity>()?.opacity == 1);

void main() {
  late FakeRoute route;
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    route = Bed.http.route;
    Bed.http.route = (method, uri) => fakeAddons(method, uri) ?? route(method, uri);
  });
  tearDownAll(() => Bed.http.route = route);
  tearDown(look);
  final screens = OnScreens(Screens.android);

  /// The TV screen runs as a TV, the phone as a phone.
  Future<void> asDevice(WidgetTester t) async {
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: OnScreens.current == Screens.tv));
    addTearDown(TvDetectionService.debugReset);
  }

  test('out of the box Home is the classic one', () {
    expect(HomeLook.cards, HomeCards.classic);
    expect(HomeLook.size, HomeCardSize.standard);
    expect(HomeLook.size.scale, 1);
    expect([HomeLook.hero, HomeLook.categories, HomeLook.logos, HomeLook.names], [true, true, true, false]);
    // a value an older or newer build saved that this one does not know: the classic look
    AppSettings.homeCards.value = 'tiles';
    AppSettings.homeCardSize.value = 'huge';
    expect(HomeLook.cards, HomeCards.classic);
    expect(HomeLook.size, HomeCardSize.standard);
  });

  test('rows take their cards in turn: their own, all alike, or one and the other', () {
    const p = CardShape.poster, b = CardShape.backdrop;
    expect(RowShapes(HomeCards.classic).take(3, p), [p, p, p]);
    expect([for (final own in [b, p, b]) RowShapes(HomeCards.classic).next(own)], [b, p, b]);
    expect(RowShapes(HomeCards.posters).take(3, b), [p, p, p]);
    expect(RowShapes(HomeCards.backdrops).take(3, p), [b, b, b]);
    final mixed = RowShapes(HomeCards.mixed);
    expect([mixed.next(p), mixed.next(p), ...mixed.take(3, p)], [b, p, b, p, b], reason: 'an addon\'s rows carry on the turns');
  });

  testWidgets('each look of Home, pictured, lays out with no overflow', (t) async {
    await asDevice(t);
    final looks = <String, void Function()>{
      'classic': look,
      'posters': () => look(cards: 'posters'),
      'backdrops': () => look(cards: 'backdrops'),
      'mixed': () => look(cards: 'mixed'),
      'no_hero': () => look(hero: false),
      'rows_only_posters': () => look(cards: 'posters', hero: false, categories: false),
      'posters_named': () => look(cards: 'posters', names: true),
      'backdrops_names': () => look(cards: 'backdrops', logos: false),
      'larger': () => look(size: 'larger'),
      'smaller_named': () => look(size: 'smaller', names: true),
    };
    final problems = await Bed.overflows(() async {
      for (final l in looks.entries) {
        l.value();
        await t.pumpWidget(const SizedBox());
        await Bed.pumpShell(t);
        await Bed.picture(t, 'home_look/${l.key}');
        await scrollHome(t, OnScreens.current == Screens.tv ? 520 : 760);
        await Bed.picture(t, 'home_look/${l.key}_rows');
        await scrollHome(t, 2200);
        await Bed.picture(t, 'home_look/${l.key}_lower');
      }
    });
    expect(problems, isEmpty);
  }, variant: screens);

  testWidgets('your addons\' rows follow the look too (TMDB off)', (t) async {
    await asDevice(t);
    MetaAddons.debugReset();
    Addons.list.value = Addons.withBuiltIns([Addon.fromManifest(lanternUrl, lanternManifest), Addon.fromManifest(kiteUrl, kiteManifest)]);
    Addons.setEnabled(Addon.tmdb, false);
    addTearDown(() => Addons.list.value = const []);
    final problems = await Bed.overflows(() async {
      for (final cards in ['classic', 'backdrops', 'mixed']) {
        look(cards: cards, names: cards == 'classic');
        await t.pumpWidget(const SizedBox());
        await Bed.pumpShell(t);
        await Bed.picture(t, 'home_look/addons_$cards');
        await scrollHome(t, 1300);
        await Bed.picture(t, 'home_look/addons_${cards}_rows');
        if (cards == 'backdrops') {
          expect(onHome(find.byType(LandscapeCard)), findsWidgets, reason: 'a catalog of posters as backdrops');
        }
      }
    });
    expect(problems, isEmpty);
  }, variant: screens);

  testWidgets('Home follows a change at once, with no restart', (t) async {
    await asDevice(t);
    await Bed.pumpShell(t);
    expect(onHome(find.byType(HeroCarousel)), findsOneWidget);
    expect(onHome(find.byType(GenreGrid)), findsOneWidget);
    expect(onHome(find.byType(Top10Card)), findsWidgets);

    AppSettings.homeHero.set(false);
    await Bed.settle(t, rounds: 3);
    expect(onHome(find.byType(HeroCarousel)), findsNothing);
    expect(t.getTopLeft(find.text('Continue watching')).dy, lessThan(80), reason: 'the rows start at the top');

    AppSettings.homeCards.set('posters');
    await Bed.settle(t, rounds: 3);
    expect(onHome(find.byType(LandscapeCard)), findsNothing);
    expect(onHome(find.byType(Top10Card)), findsNothing);
    expect(onHome(find.byType(RankTag)), findsWidgets, reason: 'a top 10 is posters with their place on them');
    final posters = onHome(find.byType(PosterCard));
    final poster = t.getSize(posters.first);
    for (var i = 0; i < posters.evaluate().length; i++) {
      expect(t.getSize(posters.at(i)), poster, reason: 'every poster one size');
    }

    AppSettings.homeNames.set(true);
    await Bed.settle(t, rounds: 3);
    expect(onHome(find.byType(CardName)), findsWidgets);
    expect(t.getSize(onHome(find.byType(PosterCard)).first).height, poster.height + CardName.height);

    AppSettings.homeCards.set('backdrops');
    AppSettings.homeLogos.set(false);
    await Bed.settle(t, rounds: 3);
    expect(onHome(find.byType(PosterCard)), findsNothing);
    final card = onHome(find.byType(LandscapeCard)).first;
    expect(nameShows(t, card, t.widget<LandscapeCard>(card).media.title), isTrue, reason: 'the name, not the logo art');
    AppSettings.homeLogos.set(true);
    await Bed.settle(t, rounds: 3);
    expect(nameShows(t, card, t.widget<LandscapeCard>(card).media.title), isFalse, reason: 'the logo art again');

    AppSettings.homeCategories.set(false);
    await Bed.settle(t, rounds: 3);
    expect(onHome(find.byType(GenreGrid)), findsNothing);

    final size = t.getSize(onHome(find.byType(LandscapeCard)).first).width;
    AppSettings.homeCardSize.set('larger');
    await Bed.settle(t, rounds: 3);
    expect(t.getSize(onHome(find.byType(LandscapeCard)).first).width, closeTo(size * 1.2, .01));

    look();
    await Bed.settle(t, rounds: 3);
    // (a TV is in D-pad mode: focus left the hero for a row when it went, and the page followed)
    await scrollHome(t, 0);
    expect(onHome(find.byType(HeroCarousel)), findsOneWidget, reason: 'and back');
  }, variant: screens);

  testWidgets('with a remote: rows-only Home starts on the first row, and down and back up', (t) async {
    await asDevice(t);
    look(cards: 'posters', hero: false, names: true);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(Bed.focused(), contains('Continue watching'), reason: 'no hero: Home starts on its first row');
    await Bed.right(t, times: 2);
    final third = Bed.focused();
    await Bed.down(t);
    expect(Bed.focused(), contains('Hot right now'));
    expect(Bed.focused(), contains('PosterCard'));
    expect(Bed.focusInView(), isTrue, reason: 'the poster and its name in view');
    await Bed.picture(t, 'home_look/remote_posters_named');
    final inHot = Bed.focused();
    await Bed.up(t);
    expect(Bed.focused(), third, reason: 'straight back up to the card you left');
    await Bed.up(t);
    expect(Bed.focused(), third, reason: 'nothing above the first row');
    expect(onHome(find.byType(HeroCarousel)), findsNothing, reason: 'Up at the top opens no spotlight');
    await Bed.down(t);
    expect(Bed.focused(), inHot);
    for (var i = 0; i < 8; i++) {
      await Bed.down(t);
      expect(Bed.focusInView(), isTrue, reason: 'row ${i + 3}: ${Bed.focused()}');
    }
    // sitting still at the top drifts into no spotlight either
    await scrollHome(t, 0);
    await t.pump(const Duration(seconds: 12));
    await Bed.settle(t, rounds: 2);
    expect(onHome(find.byType(HeroCarousel)), findsNothing);
  }, variant: screens);

  testWidgets('with a remote: the hero turned off while the TV is in the spotlight (from a phone)', (t) async {
    await asDevice(t);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(Bed.focused(), contains('_PlayButton'));
    if (OnScreens.current == Screens.tv) {
      await Bed.up(t);
      await Bed.settle(t, rounds: 4);
      expect(t.getSize(find.byType(HeroCarousel)).height, OnScreens.current.size.height, reason: 'in the spotlight');
    }
    AppSettings.homeHero.set(false);
    await Bed.settle(t, rounds: 4);
    expect(onHome(find.byType(HeroCarousel)), findsNothing);
    await Bed.down(t);
    expect(Bed.focused(), isNot('nothing'));
    expect(Bed.focusInView(), isTrue, reason: 'out of the spotlight, on a row: ${Bed.focused()}');
  }, variant: screens);

  testWidgets('Settings > Appearance: the Home choices, and Home after them', (t) async {
    await asDevice(t);
    await Bed.pumpShell(t);
    await openSettings(t, 'Appearance');
    await Bed.settle(t);
    for (final row in ['Cards', 'Card size', 'Hero carousel', 'Genre and collection cards', 'On backdrop cards', 'Names under posters']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    await t.ensureVisible(find.text('Cards'));
    await Bed.settle(t, rounds: 2);
    await Bed.picture(t, 'home_look/settings');
    final problems = await Bed.overflows(() async {
      await pressOn(t, find.widgetWithText(Pressable, 'Posters'));
      expect(AppSettings.homeCards.value, 'posters');
      expect(find.text(HomeCards.posters.blurb), findsOneWidget, reason: 'the line says what the choice does');
      await pressOn(t, find.widgetWithText(Pressable, 'Larger'));
      expect(AppSettings.homeCardSize.value, 'larger');
      Finder toggleOf(String title) => find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Row')).first,
        matching: find.byType(Pressable),
      );
      await t.ensureVisible(find.text('Names under posters'));
      await pressOn(t, toggleOf('Hero carousel'));
      expect(AppSettings.homeHero.value, isFalse);
      await pressOn(t, toggleOf('Names under posters'));
      expect(AppSettings.homeNames.value, isTrue);
      await pressOn(t, find.widgetWithText(Pressable, 'Name'));
      expect(AppSettings.homeLogos.value, isFalse);
      await Bed.picture(t, 'home_look/settings_changed');
    });
    expect(problems, isEmpty);
    await Bed.back(t);
    await Bed.back(t);
    await Bed.settle(t);
    expect(onHome(find.byType(HeroCarousel)), findsNothing);
    expect(onHome(find.byType(CardName)), findsWidgets);
  }, variant: screens);

  test('the phone page has the same choices', () async {
    await TvDetectionService.getInstance(forceTv: true);
    final items = phoneSections(fonts: const [SubtitleStyle.defaultFont]).expand((s) => s.items).toList();
    PhoneItem item(String id) => items.firstWhere((i) => i.id == id);
    expect(item('look.home.cards').kind, 'choice');
    expect(item('look.home.cards').toJson()['value'], 'classic');
    expect((await item('look.home.cards').take({'v': 'backdrops'}))?.what, 'Cards: Backdrops');
    expect(HomeLook.cards, HomeCards.backdrops);
    expect(await item('look.home.cards').take({'v': 'tiles'}), isNull, reason: 'only its own choices');
    expect((await item('look.home.size').take({'v': 'larger'}))?.what, 'Card size: Larger');
    expect((await item('look.home.hero').take({'v': false}))?.what, 'Hero carousel: off');
    expect((await item('look.home.categories').take({'v': false}))?.what, 'Genre and collection cards: off');
    expect((await item('look.home.logos').take({'v': false}))?.what, 'On backdrop cards: Name');
    expect((await item('look.home.names').take({'v': true}))?.what, 'Names under posters: on');
    expect([HomeLook.hero, HomeLook.categories, HomeLook.logos, HomeLook.names, HomeLook.size], [false, false, false, true, HomeCardSize.larger]);
    TvDetectionService.debugReset();
  });
}
