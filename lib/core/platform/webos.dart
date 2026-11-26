import 'package:flutter/foundation.dart';

/// The LG webOS build.
///
/// A webOS TV runs Linux, and Dart says so there: `Platform.isLinux` is true and
/// `defaultTargetPlatform` is `TargetPlatform.linux`. There is no webOS value to ask for. So the
/// webOS build is compiled with `--dart-define=VYSE_WEBOS=true` (tool/webos does that), and
/// whatever must differ from a Linux desktop asks here: it is a TV, with a remote, the TV's own
/// video player, no window to manage, and no session services (no D-Bus, no secret store).
abstract final class WebOS {
  static const _build = bool.fromEnvironment('VYSE_WEBOS');

  /// Tests run on a PC: this stands in for "the webOS build".
  @visibleForTesting
  static bool? debugIs;

  /// Whether this is the app on an LG TV.
  static bool get isTv => debugIs ?? _build;
}
