// VyseTV on Apple TV: sign-ins and keys in the Keychain, on the channel flutter_secure_storage's
// Dart side speaks on (plugins.it_nomads.com/flutter_secure_storage).
//
// The plugin's own Apple code does not build for tvOS (it uses LocalAuthentication, which tvOS
// lacks, for options the app never asks for), so this is the part of it the app uses: one
// generic-password item per key, readable after the first unlock, never synced. The Keychain
// is the one place on an Apple TV the system never clears to make room, which is why sign-ins
// go here and not to a file. Should it ever refuse, the Dart side keeps them in a file instead
// (lib/core/platform/tv_secrets.dart).

import Flutter
import Foundation
import Security

final class KeychainPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let service = "vyse.keychain"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "plugins.it_nomads.com/flutter_secure_storage", binaryMessenger: registrar.messenger())
    let instance = KeychainPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    // (the Dart side may listen for "protected data" changes; an Apple TV has nothing to say)
    let events = FlutterEventChannel(
      name: "plugins.it_nomads.com/flutter_secure_storage/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let key = args["key"] as? String
    switch call.method {
    case "read":
      guard let key else { return result(Self.missingKey()) }
      result(Self.read(key))
    case "write":
      guard let key, let value = args["value"] as? String else { return result(Self.missingKey()) }
      let status = Self.write(key, value)
      result(status == errSecSuccess ? nil : Self.failure("write", status))
    case "delete":
      guard let key else { return result(Self.missingKey()) }
      let status = SecItemDelete(Self.query(key) as CFDictionary)
      result(status == errSecSuccess || status == errSecItemNotFound ? nil : Self.failure("delete", status))
    case "containsKey":
      guard let key else { return result(Self.missingKey()) }
      result(Self.read(key) != nil)
    case "readAll":
      result(Self.readAll())
    case "deleteAll":
      let status = SecItemDelete(Self.query(nil) as CFDictionary)
      result(status == errSecSuccess || status == errSecItemNotFound ? nil : Self.failure("deleteAll", status))
    case "isProtectedDataAvailable":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func query(_ key: String?) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let key { q[kSecAttrAccount as String] = key }
    return q
  }

  private static func read(_ key: String) -> String? {
    var q = query(key)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func write(_ key: String, _ value: String) -> OSStatus {
    let data = Data(value.utf8)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if status != errSecItemNotFound { return status }
    var add = query(key)
    add.merge(update) { _, new in new }
    return SecItemAdd(add as CFDictionary, nil)
  }

  private static func readAll() -> [String: String] {
    var q = query(nil)
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else {
      return [:]
    }
    var all: [String: String] = [:]
    for item in items {
      if let key = item[kSecAttrAccount as String] as? String,
        let data = item[kSecValueData as String] as? Data,
        let value = String(data: data, encoding: .utf8)
      {
        all[key] = value
      }
    }
    return all
  }

  private static func missingKey() -> FlutterError {
    FlutterError(code: "Invalid argument", message: "No key given", details: nil)
  }

  private static func failure(_ what: String, _ status: OSStatus) -> FlutterError {
    FlutterError(code: "Keychain", message: "\(what) failed: \(status)", details: nil)
  }
}
