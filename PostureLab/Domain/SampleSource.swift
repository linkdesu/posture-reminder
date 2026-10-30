import Foundation

protocol SampleSource: AnyObject {
  var onSample: ((PostureSample) -> Void)? { get set }
  func start()
  func stop()
}
