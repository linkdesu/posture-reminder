import UIKit

/// The one property the app writes to hold or release the screen, behind a protocol so a test can
/// pass a fake instead of the shared application.
@MainActor
protocol IdleTimerControlling: AnyObject {
  var isIdleTimerDisabled: Bool { get set }
}

extension UIApplication: IdleTimerControlling {}

/// Applies an `IdleTimerPolicy` to the application, and only when the answer changes: the policy is
/// evaluated on every sample and every tick, so the great majority of evaluations must write
/// nothing.
@MainActor
final class IdleTimerController {
  /// Resolved at every write, never cached. A SwiftUI `App.init` runs before `UIApplicationMain`,
  /// where `UIApplication.shared` is still nil; caching it there and writing through the nil is a
  /// SIGSEGV on launch (0.6.3's first build crashed exactly that way). Reading it here also means a
  /// write before the application exists is simply deferred to the first evaluation that has one.
  private let application: () -> IdleTimerControlling?
  /// The policy in force; nil before the first evaluation.
  private(set) var policy: IdleTimerPolicy?
  /// What the application was last told, so a write is not repeated.
  private var applied: Bool?

  init() {
    application = { UIApplication.shared }
  }

  /// A provider rather than the object itself, for a path that may run before the application
  /// exists; a test can hand in a fake through the same shape.
  init(application: @escaping () -> IdleTimerControlling?) {
    self.application = application
  }

  init(application: IdleTimerControlling) {
    self.application = { application }
  }

  /// Whether the screen is being held at the moment.
  var isDisabled: Bool { applied ?? false }

  /// 应用上实际的 `isIdleTimerDisabled`（v0.6.5 取证日志读这个，而不是本控制器记住的值）；
  /// 应用还不存在时为 nil。
  var actualValue: Bool? { application()?.isIdleTimerDisabled }

  /// Evaluates `policy` and writes the application if the answer changed. Returns whether it wrote.
  @discardableResult
  func update(_ policy: IdleTimerPolicy) -> Bool {
    self.policy = policy
    let wanted = policy.disablesIdleTimer
    guard wanted != applied else { return false }
    // No application yet: nothing to write and nothing to remember, so the next evaluation writes
    // whatever it finds.
    guard let application = application() else { return false }
    applied = wanted
    application.isIdleTimerDisabled = wanted
    return true
  }
}
