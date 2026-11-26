import 'package:flutter/widgets.dart';

// One source for two Flutter versions.
//
// Every platform but one builds with the Flutter this project is pinned to. The LG webOS build
// has to use LG's own Flutter SDK, which is an older release (3.38), and a few calls the app
// used only exist in the newer one. The older forms below do the same thing on both, so they are
// what the app calls. Nothing here is webOS code: it runs everywhere.
//
// When LG's SDK catches up, the three callers can go back to the newer names and this file can go.

/// Whether tickers are on for [context] (they are off under a page that is covered).
///
/// The newer name is `TickerMode.valuesOf(context).enabled`; both read the same value.
// ignore: deprecated_member_use
bool tickersOn(BuildContext context) => TickerMode.of(context);

/// For a reorderable list's `onReorder`: calls [move] with where the row ends up, as the newer
/// `onReorderItem` does.
///
/// `onReorder` gives the place the row was dropped at while it is still counted in the list, so
/// a row moved down arrives one too far; and it also fires for a row put back where it was.
ReorderCallback reorderTo(void Function(int from, int to) move) => (from, to) {
  if (to > from) to -= 1; // (taking the row out shortens the list by one)
  if (from != to) move(from, to);
};
