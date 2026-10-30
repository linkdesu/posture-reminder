import Foundation

/// Whether the app holds the screen awake, as one value that needs no UIKit.
///
/// The screen is kept lit for exactly one situation: a focus is counting and the app is on screen.
/// A break, a pause (the child's own or an absence suspension), a finished run and a backgrounded
/// app all let the screen go dark, because none of them is a child sitting in front of a running
/// countdown. Coming back to the foreground while the focus still counts lights it again.
/// Since 0.6.4 there is no switch: a working pomodoro needs the screen on, so this is not a preference.
struct IdleTimerPolicy: Equatable {
  /// A focus is counting: started, open and neither paused nor suspended by an absence.
  var isFocusCounting: Bool
  /// The scene has the screen: true while the app is active, false once it is in the background.
  var isSceneActive: Bool

  /// The one answer the app applies to `UIApplication.isIdleTimerDisabled`.
  var disablesIdleTimer: Bool { isFocusCounting && isSceneActive }

  /// The one definition of "counting", so the controller, the tests and this file cannot drift:
  /// a break is a different phase, a parked focus was never started, and a paused or
  /// absence-suspended focus holds its countdown where it stopped.
  static func focusIsCounting(phase: PomodoroPhase,
                              isRunning: Bool,
                              focusOpen: Bool,
                              isPausedByAbsence: Bool) -> Bool {
    phase == .focus && focusOpen && isRunning && !isPausedByAbsence
  }
}

extension IdleTimerPolicy {
  /// The policy read off the timer the controller holds: `pomodoro` is the whole session state,
  /// `focusOpen` the controller's own flag for a focus that was started and not closed yet.
  init(pomodoro: PomodoroEngine?,
       focusOpen: Bool,
       isSceneActive: Bool) {
    self.init(isFocusCounting: Self.focusIsCounting(
                phase: pomodoro?.phase ?? .focus,
                isRunning: pomodoro?.isRunning ?? false,
                focusOpen: focusOpen,
                isPausedByAbsence: pomodoro?.isPausedByAbsence ?? false),
              isSceneActive: isSceneActive)
  }
}
