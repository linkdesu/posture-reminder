import Foundation

/// The few user-visible words the pomodoro screen owns as constants, so a rename is one line here
/// instead of a hunt through layouts and tests.
///
/// The end-the-focus button used to read 放弃; the outcome it produces is still `abandoned` in the
/// log, the history and `GLOSSARY.md`. Only the label the child sees changed, and it changed to a
/// word the child uses for stopping early on purpose: 休息.
enum PomodoroCopy {
  /// The secondary button that ends a started focus early (the `abandon` command).
  static let endFocusEarly = "休息"
}
