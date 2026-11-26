import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';

import 'apple_tv_remote.dart';
import 'tv_secrets.dart';

/// The Apple TV build.
///
/// To Dart an Apple TV is an iPhone: `Platform.isIOS` is true and `defaultTargetPlatform` is
/// `TargetPlatform.iOS`. The Apple TV build is told apart by `--dart-define=TVOS_BUILD=true`,
/// which tvos/scripts/xcode_appletv.sh passes (the same name upstream uses, so the D-pad kit's
/// own Apple TV branches answer to it: `PlatformDetector.isAppleTV`). Whatever must differ from
/// an iPhone asks here: it is a TV with a remote, its files can be cleared by the system when
/// space is short, it has no browser, and only the plugins tvos/Runner compiles in have a
/// native side (see tvos/README.md).
abstract final class AppleTv {
  static const _build = bool.fromEnvironment('TVOS_BUILD');

  /// Tests run on a PC: this stands in for "the Apple TV build".
  @visibleForTesting
  static bool? debugIs;

  /// Whether this is the app on an Apple TV.
  static bool get isTv => debugIs ?? _build;

  static const _channel = MethodChannel('vyse/apple_tv');

  // The tvOS engine's own: whether the remote's Menu goes to the system (the Apple TV's home
  // screen) instead of to the app.
  static const _navigation = BasicMessageChannel<Object?>('flutter/tvos_system_navigation', JSONMessageCodec());
  static bool? _menuToSystem;

  /// What the app needs set up before anything else on an Apple TV. Called first thing in
  /// main().
  static void install() {
    if (!isTv) return;
    // Flutter's tool writes no plugin registrant for a target it does not know, so the Dart
    // half of a plugin that registers itself from Dart is registered here (the native halves:
    // tvos/Runner/AppDelegate.swift).
    SharedPreferencesFoundation.registerWith();
    // The image caches keep their index in a JSON file, not in SQLite: sqflite has no Apple TV
    // build. (The files themselves are in Caches, which the system may clear: images are
    // fetched again.)
    CachedNetworkImageProvider.defaultCacheManager = CacheManager(
      Config(DefaultCacheManager.key, repo: JsonCacheInfoRepository(databaseName: DefaultCacheManager.key)),
    );
    TvSecrets.install();
    AppleTvRemote.instance.start();
  }

  /// The configuration of a cache manager of the app's own: on an Apple TV its index goes in a
  /// JSON file (see [install]); elsewhere it is flutter_cache_manager's own.
  static Config cacheConfig(String key, {Duration stalePeriod = const Duration(days: 30), int maxNrOfCacheObjects = 200}) => isTv
      ? Config(key, stalePeriod: stalePeriod, maxNrOfCacheObjects: maxNrOfCacheObjects, repo: JsonCacheInfoRepository(databaseName: key))
      : Config(key, stalePeriod: stalePeriod, maxNrOfCacheObjects: maxNrOfCacheObjects);

  /// Whether the remote's Menu leaves the app for the Apple TV's home screen, as it does in any
  /// Apple TV app at its top level, or is the app's Back. The shell says which, as focus moves
  /// (lib/screens/shell/shell.dart). The press has to go one way or the other before it
  /// arrives, so this is a standing setting, not an answer to a press.
  static void setMenuToSystem(bool on) {
    if (!isTv || _menuToSystem == on) return;
    _menuToSystem = on;
    unawaited(_navigation.send({'menuPassthroughEnabled': on}).catchError((Object _) => null));
  }

  /// No screen saver while a video plays (wakelock_plus has no Apple TV build).
  static Future<void> keepAwake(bool on) async {
    if (!isTv) return;
    try {
      await _channel.invokeMethod<void>('keepAwake', {'on': on});
    } catch (_) {
      // (a build without the native side: the screen saver may come, nothing else changes)
    }
  }
}
