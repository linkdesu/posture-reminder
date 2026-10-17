import Foundation

protocol DebugLogging: AnyObject {
  var isEnabled: Bool { get set }
  func log(_ event: MonitoringEvent)
  func screenshot(_ name: String)
}
