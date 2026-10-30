import Foundation

/// The end-of-phase sound. `soft` is the default: the product is quiet by design.
enum EndSound: String, Codable, CaseIterable, Equatable {
  case soft
  case chime
  case none
}

/// The settings of a pomodoro session, with the defaults and ranges recorded in `GLOSSARY.md`.
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
  var postureVoiceEnabled: Bool = true  // posture voice reminders
  var postureVoiceVolume: Double = 0.8  // 0...1, the same settings row as the switch above
  var monitorDuringBreak: Bool = false
  // 0.6.4 removed `keepScreenAwake` (保持屏幕常亮): the screen is always held while a focus counts.
  // A blob stored by 0.6.3 or earlier still carries that key; the synthesized decoder ignores
  // unknown keys, so the other settings load unchanged and the stale value is dropped on next write.

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
  /// step, which is part of the focus range recorded in `GLOSSARY.md`.
  func clamped() -> PomodoroSettings {
    var next = self
    next.focusMinutes = Self.clamp(focusMinutes, for: "focusMinutes") ?? focusMinutes
    next.shortBreakMinutes = Self.clamp(shortBreakMinutes, for: "shortBreakMinutes") ?? shortBreakMinutes
    next.longBreakMinutes = Self.clamp(longBreakMinutes, for: "longBreakMinutes") ?? longBreakMinutes
    next.focusPerLongBreak = Self.clamp(focusPerLongBreak, for: "focusPerLongBreak")
      ?? focusPerLongBreak
    next.dailyGoal = Self.clamp(dailyGoal, for: "dailyGoal") ?? dailyGoal
    next.postureVoiceVolume = min(max(postureVoiceVolume, 0), 1)
    return next
  }

  /// One value through the same gate `clamped()` enforces: clamped into the setting's range and, for
  /// the focus length, snapped onto its step. Nil for a key that is not an integer setting here.
  ///
  /// Both the stepper and the manual entry write through this, so a typed number and a stepped one
  /// land on exactly the same values. No range contains zero, which is what makes "never store zero"
  /// true for every path into the store.
  static func clamp(_ value: Int, for key: String) -> Int? {
    guard let range = ranges[key] else { return nil }
    let step = step(for: key)
    return step == 1 ? bounded(value, within: range) : stepped(value, within: range, step: step)
  }

  /// How far one press of a row's stepper moves, and the multiple a manual entry is snapped onto.
  static func step(for key: String) -> Int {
    key == "focusMinutes" ? focusStep : 1
  }

  /// A manual entry read back as a legal value: surrounding blanks are ignored, full-width digits
  /// (what a Chinese keyboard's number pad can emit) are read as their ASCII counterparts, and the
  /// number is clamped by `clamp(_:for:)`.
  ///
  /// Nil means "not a number this row can use", and every caller answers that the same way: the
  /// value the row already held is kept, so unparsable text can neither crash nor be stored.
  ///
  /// Digits that overflow `Int` are still a number. Their magnitude is past every range this table
  /// holds, so they clamp to the end their sign points at — a typed 21-digit value becomes the
  /// setting's maximum, never the old value. Discarding it would silently keep a number the parent
  /// did not type.
  static func value(fromManualEntry text: String, for key: String) -> Int? {
    guard ranges[key] != nil else { return nil }
    let characters = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .map(Self.asciiDigit)
    guard !characters.isEmpty else { return nil }
    if let number = Int(String(characters)) { return clamp(number, for: key) }

    var magnitude = characters[...]
    let negative = magnitude.first == "-"
    if negative { magnitude = magnitude.dropFirst() }
    guard !magnitude.isEmpty, magnitude.allSatisfy({ $0.isNumber }) else { return nil }
    return clamp(negative ? Int.min : Int.max, for: key)
  }

  /// A full-width digit as its ASCII counterpart; anything else unchanged.
  private static func asciiDigit(_ character: Character) -> Character {
    guard let scalar = character.unicodeScalars.first,
          character.unicodeScalars.count == 1,
          (0xFF10...0xFF19).contains(scalar.value),
          let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30)
    else { return character }
    return Character(ascii)
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
