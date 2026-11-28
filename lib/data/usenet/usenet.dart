// The built-in Usenet source's place in the app: what is read at start (your providers and
// indexers from the keychain, what releases did before), what the statistics hear, and what
// happens when the app goes to the background and comes back.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_settings.dart';
import 'newznab.dart';
import 'usenet_engine.dart';
import 'usenet_play.dart';
import 'usenet_release.dart';
import 'usenet_search.dart';
import 'usenet_sources.dart';
import 'usenet_stats.dart';

class Usenet {
  Usenet._();

  static bool _started = false;

  /// At start, before anything is searched or played. Nothing starts the engine unless
  /// "Pre-warm Usenet Engine" is on.
  static Future<void> initialize() async {
    if (_started) return;
    _started = true;
    // (a keychain that doesn't answer never holds the app up: Usenet is then off until it does)
    await UsenetSourcesStore.load().timeout(const Duration(seconds: 5), onTimeout: () {});
    await UsenetReleases.load();
    unawaited(Newznab.instance.load()); // (what indexers said last: pauses, limits, for Settings)
    _connectStatistics();
    // the app in the background: an engine with nothing open goes, the counts are written; back
    // in front: the engine starts again if Settings keeps it warm
    AppLifecycleListener(
      onHide: () {
        UsenetPlay.cancelPrefetch();
        unawaited(UsenetEngine.instance.backgrounded());
        unawaited(UsenetStats.instance.flush());
      },
      onShow: () => unawaited(UsenetEngine.instance.foregrounded()),
    );
    if (AppSettings.usenetPrewarm.value) unawaited(UsenetEngine.instance.foregrounded());
    // the memory the engine may use and its NZB cache are set as it starts
    void restart() => unawaited(UsenetEngine.instance.settingsChanged().then((_) => UsenetEngine.instance.foregrounded()));
    AppSettings.usenetProfile.addListener(restart);
    AppSettings.usenetCacheNzb.addListener(restart);
  }

  static void _connectStatistics() {
    final stats = UsenetStats.instance;
    Newznab.onRequest = stats.indexerRequest;
    UsenetSearch.onSearch = stats.indexerSearch;
    UsenetEngine.instance.onProviderReport = (servers, report, {required refused, kind, required content}) =>
        stats.providerReport(servers, report, refused: refused, failureKind: kind, contentKind: content);
    UsenetPlay.onOpened = (s, session) {
      final nzb = s.nzbUrl;
      if (nzb != null && !session.nzbFromCache) stats.grab(nzb);
    };
    UsenetPlay.onPlayed = (s) {
      if (s.nzbUrl case final nzb?) stats.played(nzb);
    };
    UsenetPlay.onUnplayable = (s, kind) {
      if (s.nzbUrl case final nzb?) stats.unavailable(nzb, kind);
    };
    // the statistics know your providers by their addresses as they are now (and were: an edited
    // provider keeps its counts)
    void known() => stats.knownProviders(UsenetSourcesStore.current.value.providers);
    known();
    UsenetSourcesStore.current.addListener(known);
  }

  /// Forgets everything Usenet on this device: providers and indexers, what indexers said,
  /// what releases did, the statistics. The engine goes too. (Settings > Danger Zone.)
  static Future<void> reset() async {
    UsenetPlay.cancelPrefetch();
    await UsenetEngine.instance.stop();
    await UsenetSourcesStore.clear();
    await Newznab.instance.clear();
    await UsenetReleases.clear();
    await UsenetStats.instance.clearAll();
    await UsenetDiagnostics.instance.clear();
    UsenetSearch.instance.forget(); // (searches kept for 15 minutes)
  }
}
