import SwiftUI

@main
struct PostureLabApp: App {
  private let settings: Settings
  private let pomodoroSettings: PomodoroSettingsStore
  private let controller: SessionController

  init() {
    let defaults = UserDefaults.standard
    let settings = Settings()
    let pomodoroSettings = PomodoroSettingsStore(defaults: defaults)
    let scenarios = PostureLabApp.scenarios(from: defaults)
    let reportScope = PostureLabApp.reportScope(from: defaults)
    // Launch arguments are per-run overrides: stage them without writing to the store, so they
    // never become the user's saved settings on the next launch.
    settings.suppressPersistence = true
    pomodoroSettings.suppressPersistence = true
    // A scripted run forces the overlay on, unless `-debug` was given: an explicit 0 has to win.
    if let debug = PostureLabApp.boolOverride("debug", from: defaults) {
      settings.debugEnabled = debug
    } else if !scenarios.isEmpty {
      settings.debugEnabled = true
    }
    if let avatar = PostureLabApp.boolOverride("avatar", from: defaults) {
      settings.avatarEnabled = avatar
    }
    if let sensitivity = PostureLabApp.sensitivity(from: defaults) {
      settings.sensitivity = sensitivity
    }
    // `-focusMinutes 1 -shortBreakMinutes 1` keep a simulated pomodoro short. The values are staged
    // unclamped on purpose: `PomodoroSettings.clamped()` is the gate for what the settings screen and
    // persistence write, not for a per-run override.
    var stagedPomodoro = pomodoroSettings.settings
    #if DEBUG
    // `-presetSettings focusMinutes=10,endSound=chime`: a debug-only list of the eleven settable
    // pomodoro settings, for the acceptance run that has to photograph every row before and after a
    // change. It is staged like every other launch-argument override, so nothing it names becomes the
    // saved setting, and it is applied before the single-value arguments below, which therefore still
    // win when both name the same key.
    PostureLabApp.applyPresetSettings(from: defaults, to: &stagedPomodoro)
    #endif
    if let focus = PostureLabApp.intArgument("focusMinutes", from: defaults) {
      stagedPomodoro.focusMinutes = focus
    }
    if let shortBreak = PostureLabApp.intArgument("shortBreakMinutes", from: defaults) {
      stagedPomodoro.shortBreakMinutes = shortBreak
    }
    if let longBreak = PostureLabApp.intArgument("longBreakMinutes", from: defaults) {
      stagedPomodoro.longBreakMinutes = longBreak
    }
    // `-voice 0|1` and `-endSound soft|chime|none` let the acceptance flip the two audio switches
    // between runs without tapping through the settings screen.
    if let voice = PostureLabApp.boolOverride("voice", from: defaults) {
      stagedPomodoro.postureVoiceEnabled = voice
    }
    if let endSound = PostureLabApp.endSound(from: defaults) {
      stagedPomodoro.endSound = endSound
    }
    pomodoroSettings.settings = stagedPomodoro
    settings.suppressPersistence = false
    pomodoroSettings.suppressPersistence = false

    // The log and its screenshots stay on for every scripted run even when `-debug 0` hides the
    // overlay, so those runs still leave evidence behind.
    let logger = FileDebugLogger(enabled: settings.debugEnabled || !scenarios.isEmpty)
    let pomodoroStore = PomodoroStore()
    // `-seedHistory 30` fills the report for screenshots. It replaces the history rather than adding
    // to it, so a seeded report shows the same picture on every run of the capture script.
    if let days = PostureLabApp.intArgument("seedHistory", from: defaults), days > 0 {
      pomodoroStore.clear()
      for record in PomodoroStore.seeds(days: days, endingAt: Date()) {
        pomodoroStore.add(record)
      }
    }
    self.settings = settings
    self.pomodoroSettings = pomodoroSettings
    controller = SessionController(settings: settings,
                                   logger: logger,
                                   scenarios: scenarios,
                                   pomodoroStore: pomodoroStore,
                                   pomodoroSettings: pomodoroSettings)
    #if DEBUG
    // `-autopause 30:20`: a debug-only plan the controller carries out on the shared sample clock,
    // so a scripted run can photograph the paused screen and the grey band a manual pause draws.
    controller.debugAutoPause = DebugAutoPause(defaults.string(forKey: "autopause"))
    #endif

    // The child's screen is the app's only root. The two parent pages are reached by launch argument
    // before the first frame: `-settings 1` is the pomodoro settings, and `-report day|week|month`
    // the parent report with that period selected.
    if PostureLabApp.boolOverride("settings", from: defaults) == true {
      controller.showPomodoroSettings()
    }
    if let reportScope {
      controller.showReport(scope: reportScope)
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(controller)
        .environmentObject(settings)
        .environmentObject(pomodoroSettings)
    }
  }

  private static func scenarios(from defaults: UserDefaults) -> [Scenario] {
    guard let raw = defaults.string(forKey: "scenario") else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .compactMap { Scenario(rawValue: $0) }
  }

  /// `-debug 0|1` / `-avatar 0|1` launch arguments; nil when the flag was not given.
  private static func boolOverride(_ key: String, from defaults: UserDefaults) -> Bool? {
    switch defaults.string(forKey: key) {
    case "0": return false
    case "1": return true
    default: return nil
    }
  }

  /// `-focusMinutes 25`, `-seedHistory 30` and friends: an integer launch argument, nil when the flag
  /// is absent or does not parse. The argument domain may hand the value back as a string or as a
  /// number, so both shapes are read.
  private static func intArgument(_ key: String, from defaults: UserDefaults) -> Int? {
    guard let value = defaults.object(forKey: key) else { return nil }
    if let string = value as? String { return Int(string) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }

  private static func sensitivity(from defaults: UserDefaults) -> Sensitivity? {
    defaults.string(forKey: "sensitivity").flatMap { Sensitivity(rawValue: $0) }
  }

  /// `-endSound soft|chime|none`: which cue ends a focus, nil when the flag was not given.
  private static func endSound(from defaults: UserDefaults) -> EndSound? {
    defaults.string(forKey: "endSound").flatMap { EndSound(rawValue: $0) }
  }

  /// `-report day|week|month`: which report to open, nil when the flag was not given.
  private static func reportScope(from defaults: UserDefaults) -> ReportScope? {
    defaults.string(forKey: "report").flatMap { ReportScope(rawValue: $0) }
  }

  #if DEBUG
  /// `-presetSettings focusMinutes=10,shortBreakMinutes=1,monitorDuringBreak=1,endSound=chime`: the
  /// eleven settable pomodoro settings as one comma-separated launch argument, so the acceptance can
  /// put any of them on screen without tapping through the settings screen.
  ///
  /// Every value goes through `PomodoroSettings.clamped()`, the same gate the settings screen writes
  /// through, so a preset cannot stage a setting the app could not otherwise hold. Only the keys it
  /// names are touched, and it is applied before the single-value arguments, which still win.
  ///
  /// The keys are the settable property names: `focusMinutes`, `shortBreakMinutes`,
  /// `longBreakMinutes`, `focusPerLongBreak`, `dailyGoal`, `postureVoiceEnabled`,
  /// `monitorDuringBreak`, `keepScreenAwake`, `autoStartBreak`, `autoStartFocus` and `endSound`.
  /// Integers read as integers, booleans as `1`/`0`/`true`/`false`, and `endSound` as
  /// `soft`/`chime`/`none`. An unknown key, a malformed pair or an unparsable value is ignored.
  ///
  /// Debug builds only: this function, the argument's name, every key and the call to it are
  /// compiled out of a release build, which can neither read the argument nor act on it.
  private static func applyPresetSettings(from defaults: UserDefaults,
                                          to staged: inout PomodoroSettings) {
    guard let raw = defaults.string(forKey: "presetSettings") else { return }

    // One parsed value through the field's own clamp: a copy carrying just that value is clamped and
    // the field read back, so the preset never disturbs a setting it did not name.
    func gate<T>(_ value: T, _ keyPath: WritableKeyPath<PomodoroSettings, T>) -> T {
      var probe = PomodoroSettings()
      probe[keyPath: keyPath] = value
      return probe.clamped()[keyPath: keyPath]
    }

    for pair in raw.split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      let key = String(parts[0])
      let value = String(parts[1])

      switch key {
      case "focusMinutes":
        if let number = Int(value) { staged.focusMinutes = gate(number, \.focusMinutes) }
      case "shortBreakMinutes":
        if let number = Int(value) {
          staged.shortBreakMinutes = gate(number, \.shortBreakMinutes)
        }
      case "longBreakMinutes":
        if let number = Int(value) { staged.longBreakMinutes = gate(number, \.longBreakMinutes) }
      case "focusPerLongBreak":
        if let number = Int(value) {
          staged.focusPerLongBreak = gate(number, \.focusPerLongBreak)
        }
      case "dailyGoal":
        if let number = Int(value) { staged.dailyGoal = gate(number, \.dailyGoal) }
      case "endSound":
        if let sound = EndSound(rawValue: value) { staged.endSound = gate(sound, \.endSound) }
      case "postureVoiceEnabled":
        if let flag = presetFlag(value) {
          staged.postureVoiceEnabled = gate(flag, \.postureVoiceEnabled)
        }
      case "monitorDuringBreak":
        if let flag = presetFlag(value) {
          staged.monitorDuringBreak = gate(flag, \.monitorDuringBreak)
        }
      case "keepScreenAwake":
        if let flag = presetFlag(value) { staged.keepScreenAwake = gate(flag, \.keepScreenAwake) }
      case "autoStartBreak":
        if let flag = presetFlag(value) { staged.autoStartBreak = gate(flag, \.autoStartBreak) }
      case "autoStartFocus":
        if let flag = presetFlag(value) { staged.autoStartFocus = gate(flag, \.autoStartFocus) }
      default:
        continue  // an unknown key is ignored, not an error
      }
    }
  }

  /// The boolean spellings `-presetSettings` accepts; nil for anything else.
  private static func presetFlag(_ raw: String) -> Bool? {
    switch raw.lowercased() {
    case "1", "true": return true
    case "0", "false": return false
    default: return nil
    }
  }
  #endif
}
