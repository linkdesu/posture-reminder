import Foundation

enum ReminderMode: String, CaseIterable, Equatable {
  case sound
  case voice
  case both

  var displayName: String {
    switch self {
    case .sound: return "音效"
    case .voice: return "语音"
    case .both: return "音效+语音"
    }
  }
}

final class Settings: ObservableObject {
  @Published var sensitivity: Sensitivity {
    didSet {
      guard !suppressPersistence else { return }
      defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity)
    }
  }
  @Published var reminderMode: ReminderMode {
    didSet {
      guard !suppressPersistence else { return }
      defaults.set(reminderMode.rawValue, forKey: Keys.reminderMode)
    }
  }
  @Published var debugEnabled: Bool {
    didSet {
      guard !suppressPersistence else { return }
      defaults.set(debugEnabled, forKey: Keys.debugEnabled)
    }
  }
  @Published var baselineDistanceCM: Double? {
    didSet {
      guard !suppressPersistence else { return }
      store(baselineDistanceCM, forKey: Keys.baselineDistanceCM)
    }
  }
  @Published var baselinePitchDeg: Double? {
    didSet {
      guard !suppressPersistence else { return }
      store(baselinePitchDeg, forKey: Keys.baselinePitchDeg)
    }
  }

  /// When true, assignments to the published settings still update the in-memory values but are
  /// not written to `defaults`. Launch-argument overrides are per-run, so the app stages them
  /// inside this window to keep them out of the user's saved settings.
  var suppressPersistence = false

  var isCalibrated: Bool { baselineDistanceCM != nil && baselinePitchDeg != nil }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    sensitivity = Sensitivity(rawValue: defaults.string(forKey: Keys.sensitivity) ?? "") ?? .medium
    reminderMode = ReminderMode(rawValue: defaults.string(forKey: Keys.reminderMode) ?? "") ?? .both
    debugEnabled = defaults.bool(forKey: Keys.debugEnabled)
    // A baseline of nil means "never calibrated", so presence of the key decides, not the value.
    baselineDistanceCM = defaults.object(forKey: Keys.baselineDistanceCM) != nil
      ? defaults.double(forKey: Keys.baselineDistanceCM)
      : nil
    baselinePitchDeg = defaults.object(forKey: Keys.baselinePitchDeg) != nil
      ? defaults.double(forKey: Keys.baselinePitchDeg)
      : nil
  }

  /// A real user action taken during calibration, so it persists even while launch overrides have
  /// persistence suppressed.
  func setBaseline(distanceCM: Double, pitchDeg: Double) {
    let wasSuppressed = suppressPersistence
    suppressPersistence = false
    baselineDistanceCM = distanceCM
    baselinePitchDeg = pitchDeg
    suppressPersistence = wasSuppressed
  }

  func clearBaseline() {
    baselineDistanceCM = nil
    baselinePitchDeg = nil
  }

  var engineConfig: MonitoringEngine.Config { .forSensitivity(sensitivity) }

  private func store(_ value: Double?, forKey key: String) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  private enum Keys {
    static let sensitivity = "settings.sensitivity"
    static let reminderMode = "settings.reminderMode"
    static let debugEnabled = "settings.debugEnabled"
    static let baselineDistanceCM = "settings.baselineDistanceCM"
    static let baselinePitchDeg = "settings.baselinePitchDeg"
  }
}
