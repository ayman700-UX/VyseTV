import 'package:flutter/foundation.dart';

import '../../data/app_settings.dart';

/// The cards of Home's rows, as chosen in Settings > Appearance > Home.
enum HomeCards {
  classic('Classic', 'Each row in the style that suits it: posters, backdrops and top 10s'),
  posters('Posters', 'Every card a poster, all one size, Continue watching too'),
  backdrops('Backdrops', 'Every card a wide backdrop picture, all one size'),
  mixed('Mixed', "Rows take turns between posters and backdrops, your addons' rows too");

  const HomeCards(this.label, this.blurb);
  final String label;
  final String blurb;
}

/// How big Home's cards are drawn: [scale] times the size the screen gives them.
enum HomeCardSize {
  smaller('Smaller', .85),
  standard('Standard', 1),
  larger('Larger', 1.2);

  const HomeCardSize(this.label, this.scale);
  final String label;
  final double scale;
}

/// A row of titles' cards: portrait posters or wide backdrops.
enum CardShape { poster, backdrop }

/// Home's look (Settings > Appearance > Home), read from [AppSettings]. Out of the box it is the
/// classic one: every row in its own style, the hero on top, the genre cards, logo art.
abstract final class HomeLook {
  static HomeCards get cards => HomeCards.values.firstWhere((c) => c.name == AppSettings.homeCards.value, orElse: () => HomeCards.classic);
  static HomeCardSize get size => HomeCardSize.values.firstWhere((s) => s.name == AppSettings.homeCardSize.value, orElse: () => HomeCardSize.standard);

  /// The slideshow at the top. Off: Home is rows only.
  static bool get hero => AppSettings.homeHero.value;

  /// "Explore genres" and each addon's "More from" cards.
  static bool get categories => AppSettings.homeCategories.value;

  /// Backdrop cards show the title's logo art; false: its name.
  static bool get logos => AppSettings.homeLogos.value;

  /// The title's name and year under each poster.
  static bool get names => AppSettings.homeNames.value;

  /// Any of them changed: Home lays itself out again, with no restart.
  static final Listenable changes = Listenable.merge([
    AppSettings.homeCards,
    AppSettings.homeCardSize,
    AppSettings.homeHero,
    AppSettings.homeCategories,
    AppSettings.homeLogos,
    AppSettings.homeNames,
  ]);
}

/// Hands each row of titles its cards, top to bottom: the row's own in the classic look, the
/// same for all in Posters and Backdrops, and turn about in Mixed (backdrops first). Made once
/// per build of Home, and asked in the order the rows are on the page.
class RowShapes {
  RowShapes(this.cards);
  final HomeCards cards;
  int _turn = 0;

  CardShape next(CardShape own) {
    final turn = _turn++;
    return switch (cards) {
      HomeCards.classic => own,
      HomeCards.posters => CardShape.poster,
      HomeCards.backdrops => CardShape.backdrop,
      HomeCards.mixed => turn.isEven ? CardShape.backdrop : CardShape.poster,
    };
  }

  /// The cards of the next [count] rows.
  List<CardShape> take(int count, CardShape own) => [for (var i = 0; i < count; i++) next(own)];
}
