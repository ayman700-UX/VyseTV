#if os(iOS) || os(tvOS)
import Flutter
import Foundation

/// The Usenet engine inside the app (an iPhone or Apple TV app starts no program of its own):
/// `start` hands it its bootstrap record and answers the port it serves on, `stop` ends it.
/// Shared by the iPhone pod and the Apple TV app (tool/tvos/make_project.py).
public class VyseUsenetPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "vyse/usenet", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VyseUsenetPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasEngine":
      result(true)
    case "start":
      guard let bootstrap = call.arguments as? String else {
        result(FlutterError(code: "args", message: "a bootstrap record is needed", details: nil))
        return
      }
      // (the engine starts in well under a second, but never on the main thread)
      DispatchQueue.global(qos: .userInitiated).async {
        let port = bootstrap.withCString { VyseUsenetStart(UnsafeMutablePointer(mutating: $0)) }
        let reason = port < 0 ? VyseUsenetError().map { String(cString: $0) } : nil
        DispatchQueue.main.async {
          if port < 0 {
            result(FlutterError(code: "start", message: reason ?? "the engine did not start", details: nil))
          } else {
            result(Int(port))
          }
        }
      }
    case "stop":
      DispatchQueue.global(qos: .utility).async {
        VyseUsenetStop()
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
#endif
