import Combine
import Foundation

/// Holds the twelve pomodoro settings and keeps them across relaunches.
///
/// Same shape as `Settings`: the published value is written through `clamped()` and read back in
/// `init`, so the settings screen and storage share one gate; a missing or corrupt stored blob
/// falls back to the defaults recorded in `GLOSSARY.md` instead of failing; and
/// `suppressPersistence` lets the launch arguments override a value for one run without
/// it becoming the user's saved setting.
final class PomodoroSettingsStore: ObservableObject {
  @Published var settings: PomodoroSettings {
    didSet {
      guard !suppressPersistence else { return }
      persist(settings)
    }
  }

  /// When true, assignments to the published settings still update the in-memory values but are
  /// not written to `defaults`. Launch-argument overrides are per-run, so the app stages them
  /// inside this window to keep them out of the user's saved settings.
  var suppressPersistence = false

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // A missing key, an undecodable blob and an out-of-range value all land on the defaults, so a
    // bad write or a schema change can never leave the settings screen without a value to show.
    settings = Self.load(from: defaults) ?? PomodoroSettings()
    // `didSet` does not run during initialisation, so reading a stored value back never rewrites it.
  }

  /// Back to the defaults recorded in `GLOSSARY.md`. A user action, so it persists like any
  /// other change.
  func reset() {
    settings = PomodoroSettings()
  }

  private func persist(_ value: PomodoroSettings) {
    let clamped = value.clamped()
    guard let data = try? JSONEncoder().encode(clamped) else { return }
    defaults.set(data, forKey: Keys.settings)
  }

  /// The stored settings, clamped back into range; nil when nothing usable is stored.
  private static func load(from defaults: UserDefaults) -> PomodoroSettings? {
    guard let data = defaults.data(forKey: Keys.settings),
          let stored = try? JSONDecoder().decode(PomodoroSettings.self, from: data)
    else { return nil }
    return stored.clamped()
  }

  private enum Keys {
    static let settings = "pomodoro.settings"
  }
}
