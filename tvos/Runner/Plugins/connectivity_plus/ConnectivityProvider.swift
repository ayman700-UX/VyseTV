// VyseTV Apple TV copy of connectivity_plus 7.3.1: made by tool/tvos/vendor_plugins.py, do not edit.
import Foundation

public enum ConnectivityType {
  case none
  case wiredEthernet
  case wifi
  case cellular
  case satellite
  case other
}

public protocol ConnectivityProvider: NSObjectProtocol {
  typealias ConnectivityUpdateHandler = ([ConnectivityType]) -> Void
  
  var currentConnectivityTypes: [ConnectivityType] { get }
  
  var connectivityUpdateHandler: ConnectivityUpdateHandler? { get set }
  
  func start()
  
  func stop()
}
