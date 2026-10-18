import Foundation

/// The end-of-phase sound. `soft` is the default: the product is quiet by design.
enum EndSound: String, Codable, CaseIterable, Equatable {
  case soft
  case chime
  case none
}

/// The settings of a pomodoro session, with the defaults and ranges of the product north star.
///
/// The synthesized memberwise initialiser does not clamp: launch-argument overrides
/// (`-focusMinutes 1`) deliberately reach below the user-facing range so simulated runs stay
/// short. `clamped()` is the gate for values coming from the settings screen or from persistence.
struct PomodoroSettings: Equatable, Codable {
  var focusMinutes: Int = 25            // 5...60, step 5
  var shortBreakMinutes: Int = 5        // 1...15
  var longBreakMinutes: Int = 15        // 5...30
  var focusPerLongBreak: Int = 4        // 2...8
  var autoStartBreak: Bool = true
  var autoStartFocus: Bool = false
  var dailyGoal: Int = 4                // 1...12
  var endSound: EndSound = .soft        // .soft / .chime / .none
  var remindBeforeEnd: Bool = false     // 1-minute warning before the end
  var postureVoiceEnabled: Bool = true  // posture voice reminders
  var postureVoiceVolume: Double = 0.8  // 0...1, the same settings row as the switch above
  var monitorDuringBreak: Bool = false
  var keepScreenAwake: Bool = true

  private static let focusRange = 5...60
  private static let focusStep = 5
  private static let shortBreakRange = 1...15
  private static let longBreakRange = 5...30
  private static let focusPerLongBreakRange = 2...8
  private static let dailyGoalRange = 1...12

  /// The legal range of every integer setting, keyed by property name, so the settings screen can
  /// generate its controls from the table the clamp enforces instead of repeating the numbers.
  static let ranges: [String: ClosedRange<Int>] = [
    "focusMinutes": focusRange,
    "shortBreakMinutes": shortBreakRange,
    "longBreakMinutes": longBreakRange,
    "focusPerLongBreak": focusPerLongBreakRange,
    "dailyGoal": dailyGoalRange
  ]

  /// Pulls every setting back into its legal range: the user-facing gate for a value written by the
  /// settings screen or restored from storage. The focus length is also snapped onto its 5-minute
  /// step, which is part of its north-star range.
  func clamped() -> PomodoroSettings {
    var next = self
    next.focusMinutes = Self.stepped(focusMinutes, within: Self.focusRange, step: Self.focusStep)
    next.shortBreakMinutes = Self.bounded(shortBreakMinutes, within: Self.shortBreakRange)
    next.longBreakMinutes = Self.bounded(longBreakMinutes, within: Self.longBreakRange)
    next.focusPerLongBreak = Self.bounded(focusPerLongBreak, within: Self.focusPerLongBreakRange)
    next.dailyGoal = Self.bounded(dailyGoal, within: Self.dailyGoalRange)
    next.postureVoiceVolume = min(max(postureVoiceVolume, 0), 1)
    return next
  }

  private static func bounded(_ value: Int, within range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// Clamps into `range` and then to the nearest multiple of `step` inside it. `focusMinutes` is
  /// the only setting with a step.
  private static func stepped(_ value: Int, within range: ClosedRange<Int>, step: Int) -> Int {
    let snapped = Int((Double(bounded(value, within: range)) / Double(step)).rounded()) * step
    return bounded(snapped, within: range)
  }
}
