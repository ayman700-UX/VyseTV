// VyseTV on Apple TV: the few things the app asks of the Apple TV itself (vyse/apple_tv).
//
//   keepAwake {on: bool}   no screen saver while a video plays (the job wakelock_plus does on
//                          the other platforms; its Apple code is not built for tvOS)
//
// See lib/core/platform/apple_tv.dart.

import Flutter
import UIKit

final class AppleTvPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "vyse/apple_tv", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AppleTvPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "keepAwake":
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = on
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
