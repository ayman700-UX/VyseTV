// VyseTV on Apple TV: the few things the app asks of the Apple TV itself (vyse/apple_tv).
//
//   keepAwake {on: bool}   no screen saver while a video plays (the job wakelock_plus does on
//                          the other platforms; its Apple code is not built for tvOS)
//   playSound {path, volume}  a party's short sound, a WAV file (audioplayers has no tvOS side)
//   externalPlayers        which other player apps are on this Apple TV (VLC, Infuse)
//   openExternal {player, url}  hands a video to one of them (Android TV's "Another app")
//   pickMicrophone         tvOS 17's Continuity picker: an iPhone or iPad near the Apple TV lends
//                          its microphone, for talking in a party's voice call. Answers whether
//                          a microphone is there once the picker is gone.
//
// See lib/core/platform/apple_tv.dart.

import AVFoundation
import AVKit
import Flutter
import UIKit

final class AppleTvPlugin: NSObject, FlutterPlugin {
  private static var playing: [AVAudioPlayer] = []
  private static var picker: AnyObject?

  /// The player apps a video can be handed to, by their x-callback URL schemes (listed in
  /// Info.plist's LSApplicationQueriesSchemes, so the system says whether each is there).
  private static let players: [(name: String, probe: String, open: (String) -> String)] = [
    ("VLC", "vlc-x-callback://", { "vlc-x-callback://x-callback-url/stream?url=\(encode($0))" }),
    ("Infuse", "infuse://", { "infuse://x-callback-url/play?url=\(encode($0))" }),
  ]

  private static func encode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

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
    case "playSound":
      let args = call.arguments as? [String: Any]
      guard let path = args?["path"] as? String else {
        result(nil)
        return
      }
      let volume = Float(args?["volume"] as? Double ?? 0.8)
      DispatchQueue.main.async {
        // (kept until it has played; a new sound does not cut one that is playing)
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
          result(nil)
          return
        }
        player.volume = volume
        AppleTvPlugin.playing = AppleTvPlugin.playing.filter { $0.isPlaying }
        AppleTvPlugin.playing.append(player)
        player.play()
        result(nil)
      }
    case "pickMicrophone":
      DispatchQueue.main.async { AppleTvPlugin.pickMicrophone(result) }
    case "externalPlayers":
      DispatchQueue.main.async {
        result(AppleTvPlugin.players.filter { p in
          URL(string: p.probe).map { UIApplication.shared.canOpenURL($0) } ?? false
        }.map { $0.name })
      }
    case "openExternal":
      let args = call.arguments as? [String: Any]
      guard let name = args?["player"] as? String, let url = args?["url"] as? String,
        let player = AppleTvPlugin.players.first(where: { $0.name == name }),
        let link = URL(string: player.open(url))
      else {
        result(false)
        return
      }
      DispatchQueue.main.async { UIApplication.shared.open(link, options: [:]) { ok in result(ok) } }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Whether a microphone is there now (one an iPhone or iPad lends, on an Apple TV).
  private static func hasMicrophone() -> Bool {
    if #available(tvOS 17.0, *) {
      return AVCaptureDevice.default(for: .audio) != nil
    }
    return false
  }

  private static func pickMicrophone(_ result: @escaping FlutterResult) {
    guard #available(tvOS 17.0, *), AVContinuityDevicePickerViewController.isSupported else {
      result(hasMicrophone())
      return
    }
    guard let top = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first
    else {
      result(hasMicrophone())
      return
    }
    let delegate = MicrophonePicker(done: { result(hasMicrophone()) })
    picker = delegate
    let controller = AVContinuityDevicePickerViewController()
    controller.delegate = delegate
    var shown = top
    while let next = shown.presentedViewController { shown = next }
    shown.present(controller, animated: true)
  }
}

// The picker's delegate: answers once, when the picker is gone (whether or not a device came).
@available(tvOS 17.0, *)
private final class MicrophonePicker: NSObject, AVContinuityDevicePickerViewControllerDelegate {
  private var done: (() -> Void)?

  init(done: @escaping () -> Void) { self.done = done }

  private func finish() {
    let d = done
    done = nil
    d?()
  }

  func continuityDevicePicker(_ pickerViewController: AVContinuityDevicePickerViewController, didConnect device: AVContinuityDevice) {
    pickerViewController.dismiss(animated: true)
    finish()
  }

  func continuityDevicePickerDidCancel(_ pickerViewController: AVContinuityDevicePickerViewController) {
    finish()
  }

  func continuityDevicePickerDidEndPresenting(_ pickerViewController: AVContinuityDevicePickerViewController) {
    finish()
  }
}
