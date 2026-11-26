import 'package:flutter/services.dart';

import 'webos.dart';

/// The app's window on an LG TV.
///
/// A webOS app's window carries named properties the TV's compositor reads. One of them decides
/// who gets the remote's Back key: without it the TV answers Back itself (its "exit the app?"
/// box) and the app never hears of it, so no page could be left with the remote. With
/// `_WEBOS_ACCESS_POLICY_KEYS_BACK` set to "true" the key is the app's, and LG's embedder
/// hands it to Flutter as Escape, which is what every page's Back already listens for
/// (`backBindings` in lib/dpad). Other native apps ask for it the same way.
///
/// The native side (packages/vyse_webos) sets the property as the app starts; this says it
/// once more when the first page is up, because which of the two moments the compositor
/// honours is not written down anywhere. Unproven on a TV: LG wrote in October 2026 that
/// their Flutter SDK did not yet hand Back to apps (see webos/README.md).
abstract final class WebosWindow {
  static const _channel = MethodChannel('vyse/webos_window');

  /// The property that makes Back the app's, and its value.
  static const backKeyPolicy = '_WEBOS_ACCESS_POLICY_KEYS_BACK';

  /// Asks for the remote's Back key. Does nothing anywhere but on an LG TV.
  static Future<void> keepBackKey() => setProperty(backKeyPolicy, 'true');

  /// Sets one property of the app's window. Quietly does nothing when it cannot (not an LG TV,
  /// or a build without the native side).
  static Future<void> setProperty(String name, String value) async {
    if (!WebOS.isTv) return;
    try {
      await _channel.invokeMethod<void>('setProperty', {'name': name, 'value': value});
    } catch (_) {
      // (the native side has asked already; there is nothing more to do from here)
    }
  }
}
