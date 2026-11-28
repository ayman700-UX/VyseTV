// VyseTV on Apple TV. The app is the iPhone app's Dart code on a Flutter engine built for tvOS
// (tvos/engine.version, fetched by tvos/scripts/fetch_engine.sh); this project is the Apple TV
// side of it. See tvos/README.md.
//
// Flutter's tool has no Apple TV target, so nothing registers plugins on its own: each one the
// app needs here is compiled into this target (Runner/Plugins, the iPhone player in
// ios/Runner/MpvPlayer, the torrent plugin) and registered below by hand.

import AVFoundation
import Flutter
import UIKit

/// The app's view controller: Flutter's, plus the remote's Play/Pause button.
///
/// The engine turns the Siri Remote's clicks and Menu into key events. Play/Pause it does not,
/// so the press is taken here and sent to Dart as a message on the channel the engine uses for
/// the remote's touch surface (lib/core/platform/apple_tv_remote.dart turns it into the
/// media play/pause key every player already answers).
@objc class VyseFlutterViewController: FlutterViewController {
  private lazy var remoteChannel = FlutterBasicMessageChannel(
    name: "flutter/gamepadtouchevent",
    binaryMessenger: binaryMessenger,
    codec: FlutterJSONMessageCodec.sharedInstance()
  )

  override var canBecomeFirstResponder: Bool { true }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    becomeFirstResponder()
  }

  override func viewWillDisappear(_ animated: Bool) {
    resignFirstResponder()
    super.viewWillDisappear(animated)
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .playPause }) {
      remoteChannel.sendMessage(["type": "play_pause", "source": "presses"])
      return
    }
    super.pressesBegan(presses, with: event)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .playPause }) { return }
    super.pressesEnded(presses, with: event)
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .playPause }) { return }
    super.pressesCancelled(presses, with: event)
  }

  override func remoteControlReceived(with event: UIEvent?) {
    guard let subtype = event?.subtype else {
      super.remoteControlReceived(with: event)
      return
    }
    switch subtype {
    case .remoteControlPlay, .remoteControlPause, .remoteControlTogglePlayPause:
      remoteChannel.sendMessage(["type": "play_pause", "source": "remote_control"])
    default:
      super.remoteControlReceived(with: event)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)  // as on iPhone
    } catch {
      MpvLog.error("Failed to configure the audio session: \(error)")
    }
    application.beginReceivingRemoteControlEvents()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // The storyboard's view controller makes the engine after launch; plugins go on that one.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    func add(_ name: String, _ register: (FlutterPluginRegistrar) -> Void) {
      if let registrar = registry.registrar(forPlugin: name) { register(registrar) }
    }
    // the player (the iPhone's): video, music, audiobooks, and the core that listens for
    // subtitle sync
    add("MpvPlayerPlugin") { MpvPlayerPlugin.register(with: $0) }
    add("MpvAudioPlayerPlugin") { MpvAudioPlayerPlugin.register(with: $0) }
    add("MpvAudio2PlayerPlugin") { MpvAudioPlayerPlugin.registerSecondary(with: $0) }
    add("MpvAudioListenerPlugin") { MpvAudioPlayerPlugin.registerListener(with: $0) }
    // plugins of the app's packages, compiled in here (Runner/Plugins)
    add("SharedPreferencesPlugin") { SharedPreferencesPlugin.register(with: $0) }
    add("PathProviderPlugin") { PathProviderPlugin.register(with: $0) }
    add("PackageInfoPlusPlugin") { PackageInfoPlusPlugin.register(with: $0) }
    add("DeviceInfoPlusPlugin") { DeviceInfoPlusPlugin.register(with: $0) }
    add("ConnectivityPlusPlugin") { ConnectivityPlusPlugin.register(with: $0) }
    add("KeychainPlugin") { KeychainPlugin.register(with: $0) }
    add("TorrserverFlutterPlugin") { TorrserverFlutterPlugin.register(with: $0) }
    add("VyseUsenetPlugin") { VyseUsenetPlugin.register(with: $0) }
    // a party's voice call (copied whole by tool/tvos/vendor_plugins.py; WebRTC is from tvOS 17)
    add("FlutterWebRTCPlugin") { FlutterWebRTCPlugin.register(with: $0) }
    add("LiveKitPlugin") { LiveKitPlugin.register(with: $0) }
    // the Apple TV itself
    add("AppleTvPlugin") { AppleTvPlugin.register(with: $0) }
  }
}
