// VyseTV addition (not in upstream).
//
// Memory while a film plays on an LG or a Samsung TV. There the TV's player runs inside the
// app's own process: its buffers for a 4K film and the pictures the pages had decoded count
// against one limit, and the TV ends an app that goes over it. A Samsung tester's 2025 set
// (Tizen 8) did, on a 4K 10-bit HEVC film after a while of browsing catalogues: a black screen.
//
// So while a film plays there, the pictures nothing shows any more (posters scrolled past, the
// backdrops of pages left) are let go, and fewer are kept until it closes. What is on screen
// under the player stays, and comes back as it was.

import 'package:flutter/widgets.dart';

abstract final class TvMemory {
  static int _films = 0;
  static int? _keptBytes;
  static int? _keptCount;

  /// While a film plays: about a screen of pictures.
  static const filmBytes = 24 << 20;

  /// A video player opened (not one for sound alone).
  static void filmOpened() {
    if (_films++ > 0) return;
    try {
      final cache = PaintingBinding.instance.imageCache;
      _keptBytes = cache.maximumSizeBytes;
      _keptCount = cache.maximumSize;
      cache.clear();
      cache.maximumSizeBytes = filmBytes;
      cache.maximumSize = 120;
    } catch (_) {
      // (no binding: a test that drives a player without one)
    }
  }

  /// That player closed.
  static void filmClosed() {
    if (_films == 0) return;
    if (--_films > 0) return;
    try {
      final cache = PaintingBinding.instance.imageCache;
      if (_keptBytes != null) cache.maximumSizeBytes = _keptBytes!;
      if (_keptCount != null) cache.maximumSize = _keptCount!;
    } catch (_) {}
    _keptBytes = null;
    _keptCount = null;
  }

  /// Tests: how many films are open, as far as this knows.
  @visibleForTesting
  static int get debugFilms => _films;
}
