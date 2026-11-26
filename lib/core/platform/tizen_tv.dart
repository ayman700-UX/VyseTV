import 'package:flutter/foundation.dart';

import 'webos.dart';

/// The Samsung TV build (Tizen).
///
/// Tizen runs Linux, and Dart says so there as on an LG TV: `Platform.isLinux` is true. So the
/// Tizen build is compiled with `--dart-define=VYSE_TIZEN=true` (tool/tizen does that), and
/// whatever must differ asks here: it is a TV, with a remote, Samsung's own video player
/// (mpv/player/platform/player_tizen.dart), no window to manage, and no desktop session
/// services (no D-Bus, no secret store).
abstract final class TizenTv {
  static const _build = bool.fromEnvironment('VYSE_TIZEN');

  /// Tests run on a PC: this stands in for "the Tizen build".
  @visibleForTesting
  static bool? debugIs;

  /// Whether this is the app on a Samsung TV.
  static bool get isTv => debugIs ?? _build;
}

/// A TV whose system Dart takes for Linux: LG's webOS or Samsung's Tizen. What either needs
/// apart from a Linux desktop (no desktop windows, no session bus, the TV's own player, a
/// remote) asks here; what only one of them has asks [WebOS] or [TizenTv].
abstract final class LinuxTv {
  static bool get isTv => WebOS.isTv || TizenTv.isTv;
}
