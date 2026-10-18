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
    let pomodoroMode = PostureLabApp.pomodoroMode(from: defaults)
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
    if let focus = PostureLabApp.intArgument("focusMinutes", from: defaults) {
      stagedPomodoro.focusMinutes = focus
    }
    if let shortBreak = PostureLabApp.intArgument("shortBreakMinutes", from: defaults) {
      stagedPomodoro.shortBreakMinutes = shortBreak
    }
    if let longBreak = PostureLabApp.intArgument("longBreakMinutes", from: defaults) {
      stagedPomodoro.longBreakMinutes = longBreak
    }
    pomodoroSettings.settings = stagedPomodoro
    settings.suppressPersistence = false
    pomodoroSettings.suppressPersistence = false

    // The log and its screenshots stay on for every scripted run even when `-debug 0` hides the
    // overlay, so those runs still leave evidence behind. A pomodoro screen is only ever reached by a
    // launch argument in this slice, so a pomodoro launch is a capture run and needs the same.
    let logger = FileDebugLogger(enabled: settings.debugEnabled || !scenarios.isEmpty || pomodoroMode)
    let store = SessionStore()
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
                                   store: store,
                                   logger: logger,
                                   scenarios: scenarios,
                                   captureSettings: PostureLabApp.captureSettings(from: defaults),
                                   pomodoroStore: pomodoroStore,
                                   pomodoroSettings: pomodoroSettings)

    // The pomodoro screens are reached by launch argument before the first frame: `-pomodoro 1` is the
    // child's screen, `-settings 1` the pomodoro settings (never the reading-session 设置 screen, which
    // `-settings` deliberately does not open outside pomodoro mode), and `-report day|week|month` the
    // parent report with that period selected.
    if pomodoroMode {
      controller.enterPomodoroMode()
      if PostureLabApp.boolOverride("settings", from: defaults) == true {
        controller.showPomodoroSettings()
      }
      if let reportScope {
        controller.showReport(scope: reportScope)
      }
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

  /// `-pomodoro 1`, or a report launch argument: the report is only reachable in pomodoro mode, so
  /// asking for one implies the mode.
  private static func pomodoroMode(from defaults: UserDefaults) -> Bool {
    if boolOverride("pomodoro", from: defaults) == true { return true }
    return reportScope(from: defaults) != nil
  }

  /// `-report day|week|month`: which report to open, nil when the flag was not given.
  private static func reportScope(from defaults: UserDefaults) -> ReportScope? {
    defaults.string(forKey: "report").flatMap { ReportScope(rawValue: $0) }
  }

  /// `-captureSettings value` on the launch arguments; anything but `0`/`false` counts as on.
  private static func captureSettings(from defaults: UserDefaults) -> Bool {
    guard let raw = defaults.string(forKey: "captureSettings") else { return false }
    return raw != "0" && raw.lowercased() != "false"
  }
}
