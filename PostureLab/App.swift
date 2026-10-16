import SwiftUI

@main
struct PostureLabApp: App {
  private let settings: Settings
  private let controller: SessionController

  init() {
    let defaults = UserDefaults.standard
    let settings = Settings()
    let scenarios = PostureLabApp.scenarios(from: defaults)
    // Any -scenario launch argument means a QA replay, which needs the log.
    if defaults.string(forKey: "scenario") != nil {
      settings.debugEnabled = true
    }
    if let sensitivity = PostureLabApp.sensitivity(from: defaults) {
      settings.sensitivity = sensitivity
    }

    let logger = FileDebugLogger(enabled: settings.debugEnabled)
    let store = SessionStore()
    self.settings = settings
    controller = SessionController(settings: settings, store: store, logger: logger, scenarios: scenarios)
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(controller)
        .environmentObject(settings)
    }
  }

  private static func scenarios(from defaults: UserDefaults) -> [Scenario] {
    guard let raw = defaults.string(forKey: "scenario") else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .compactMap { Scenario(rawValue: $0) }
  }

  private static func sensitivity(from defaults: UserDefaults) -> Sensitivity? {
    defaults.string(forKey: "sensitivity").flatMap { Sensitivity(rawValue: $0) }
  }
}
