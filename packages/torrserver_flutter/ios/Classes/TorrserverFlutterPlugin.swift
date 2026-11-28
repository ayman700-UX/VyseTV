import Flutter
import UIKit

// VyseTV: the torrent engine is in the same Go library as the Usenet engine (one Go runtime in
// the app: packages/vyse_usenet/apple). On an iPhone that library comes with the Usenet plugin's
// pod, whose module declares the entry points (VyseUsenetEngine.h); on Apple TV both plugins are
// compiled into the app and the bridging header declares them.
#if canImport(vyse_usenet)
  import vyse_usenet
#endif

public class TorrserverFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "torrserver_flutter", binaryMessenger: registrar.messenger())
    let instance = TorrserverFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// The engine's answer: nil, or why not (a string the engine made, freed here).
  private static func message(_ error: UnsafeMutablePointer<CChar>?) -> String? {
    guard let error else { return nil }
    defer { TorrServerFree(error) }
    return String(cString: error)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startServer":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Arguments must be a dictionary", details: nil))
        return
      }
      let port = args["port"] as? Int ?? 8090
      let dataDir = args["dataDir"] as? String ?? ""

      DispatchQueue.global(qos: .userInitiated).async {
        let error = dataDir.withCString { dir in
          "".withCString { ip in
            TorrserverFlutterPlugin.message(
              TorrServerStart(Int32(port), UnsafeMutablePointer(mutating: dir), UnsafeMutablePointer(mutating: ip)))
          }
        }
        DispatchQueue.main.async {
          if let error, !error.isEmpty {
            result(FlutterError(code: "START_FAILED", message: error, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "stopServer":
      DispatchQueue.global(qos: .userInitiated).async {
        let error = TorrserverFlutterPlugin.message(TorrServerStop())
        DispatchQueue.main.async {
          if let error, !error.isEmpty {
            result(FlutterError(code: "STOP_FAILED", message: error, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "hasEngine":
      // VyseTV: the engine is always linked in (the build stops without it)
      result(true)
    case "isRunning":
      result(TorrServerIsRunning() != 0)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
