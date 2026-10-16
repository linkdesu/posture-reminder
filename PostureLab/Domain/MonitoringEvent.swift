import Foundation

enum MonitoringEvent: Equatable {
  case sessionStarted(scenario: String?)
  case config(sensitivity: Sensitivity, distanceThresholdCM: Double, pitchThresholdDeg: Double)
  case calibrated(baselineDistanceCM: Double, baselinePitchDeg: Double)
  case screenShown(name: String)
  case sample(t: TimeInterval, distanceCM: Double?, pitchDeg: Double?)
  case statusChanged(to: PostureStatus, t: TimeInterval, distanceCM: Double?, pitchDeg: Double?)
  case reminder(kind: ReminderKind, level: ReminderLevel, t: TimeInterval, breachSeconds: Double, distanceCM: Double?, pitchDeg: Double?)
  case paused(t: TimeInterval)
  case resumed(t: TimeInterval)
  case sessionEnded(summary: SessionSummary)
}

struct LogRecord: Codable {
  var t: Double?
  var wallClock: String
  var event: String
  var status: String?
  var kind: String?
  var level: Int?
  var distanceCM: Double?
  var pitchDeg: Double?
  var breachSeconds: Double?
  var sensitivity: String?
  var distanceThresholdCM: Double?
  var pitchThresholdDeg: Double?
  var baselineDistanceCM: Double?
  var baselinePitchDeg: Double?
  var totalSeconds: Double?
  var goodSeconds: Double?
  var tooCloseSeconds: Double?
  var headDownSeconds: Double?
  var tooCloseCount: Int?
  var longestGoodStreakSeconds: Double?
  var scenario: String?
  var screen: String?
  var message: String?
}

extension MonitoringEvent {
  /// Shared formatter: ISO8601DateFormatter construction is comparatively expensive, and the
  /// formatter is not mutated after configuration.
  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  func logRecord(now: Date) -> LogRecord {
    var record = LogRecord(
      t: nil,
      wallClock: Self.iso8601.string(from: now),
      event: "",
      status: nil,
      kind: nil,
      level: nil,
      distanceCM: nil,
      pitchDeg: nil,
      breachSeconds: nil,
      sensitivity: nil,
      distanceThresholdCM: nil,
      pitchThresholdDeg: nil,
      baselineDistanceCM: nil,
      baselinePitchDeg: nil,
      totalSeconds: nil,
      goodSeconds: nil,
      tooCloseSeconds: nil,
      headDownSeconds: nil,
      tooCloseCount: nil,
      longestGoodStreakSeconds: nil,
      scenario: nil,
      screen: nil,
      message: nil
    )

    switch self {
    case .sessionStarted(let scenario):
      record.event = "session_started"
      record.scenario = scenario

    case .config(let sensitivity, let distanceThresholdCM, let pitchThresholdDeg):
      record.event = "config"
      record.sensitivity = sensitivity.rawValue
      record.distanceThresholdCM = distanceThresholdCM
      record.pitchThresholdDeg = pitchThresholdDeg

    case .calibrated(let baselineDistanceCM, let baselinePitchDeg):
      record.event = "calibrated"
      record.baselineDistanceCM = baselineDistanceCM
      record.baselinePitchDeg = baselinePitchDeg

    case .screenShown(let name):
      record.event = "screen_shown"
      record.screen = name

    case .sample(let t, let distanceCM, let pitchDeg):
      record.event = "sample"
      record.t = t
      record.distanceCM = distanceCM
      record.pitchDeg = pitchDeg

    case .statusChanged(let to, let t, let distanceCM, let pitchDeg):
      record.event = "status_changed"
      record.t = t
      record.status = to.rawValue
      record.distanceCM = distanceCM
      record.pitchDeg = pitchDeg

    case .reminder(let kind, let level, let t, let breachSeconds, let distanceCM, let pitchDeg):
      record.event = "reminder"
      record.t = t
      record.kind = kind.rawValue
      record.level = level.rawValue
      record.breachSeconds = breachSeconds
      record.distanceCM = distanceCM
      record.pitchDeg = pitchDeg

    case .paused(let t):
      record.event = "paused"
      record.t = t

    case .resumed(let t):
      record.event = "resumed"
      record.t = t

    case .sessionEnded(let summary):
      record.event = "session_ended"
      record.totalSeconds = summary.totalSeconds
      record.goodSeconds = summary.goodSeconds
      record.tooCloseSeconds = summary.tooCloseSeconds
      record.headDownSeconds = summary.headDownSeconds
      record.tooCloseCount = summary.tooCloseCount
      record.longestGoodStreakSeconds = summary.longestGoodStreakSeconds
    }

    return record
  }
}
