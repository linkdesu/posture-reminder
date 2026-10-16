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

/// One log line, schema v2. Properties are named after their JSON keys because the wire format is
/// a contract with the QA scripts.
struct LogRecord: Codable {
  /// The full key set of a line. `encode(to:)` writes all of them on every line so a consumer can
  /// read the same keys from any record; `Decodable` is synthesised from these names.
  enum CodingKeys: String, CodingKey {
    case ts
    case t
    case wall_clock
    case event
    case state
    case screen
    case distance_cm
    case pitch_deg
    case alert_type
    case level
    case breach_seconds
    case sensitivity
    case distance_threshold_cm
    case pitch_threshold_deg
    case baseline_distance_cm
    case baseline_pitch_deg
    case total_seconds
    case good_seconds
    case near_seconds
    case head_down_seconds
    case paused_seconds
    case near_count
    case longest_good_streak_seconds
    case scenario
    case message
  }

  /// Unix epoch milliseconds when the line was produced.
  var ts: Int64
  /// Seconds since session start; only events that carry a time fill it.
  var t: Double?
  var wall_clock: String?
  var event: String?
  var state: String?
  var screen: String?
  var distance_cm: Double?
  var pitch_deg: Double?
  var alert_type: String?
  var level: Int?
  var breach_seconds: Double?
  var sensitivity: String?
  var distance_threshold_cm: Double?
  var pitch_threshold_deg: Double?
  var baseline_distance_cm: Double?
  var baseline_pitch_deg: Double?
  var total_seconds: Double?
  var good_seconds: Double?
  var near_seconds: Double?
  var head_down_seconds: Double?
  var paused_seconds: Double?
  var near_count: Int?
  var longest_good_streak_seconds: Double?
  var scenario: String?
  var message: String?

  /// Every key is encoded, absent values as JSON null: an `Optional` value reaching the keyed
  /// container goes through `Optional.encode`, i.e. `encodeNil()`. Do not switch to
  /// `encodeIfPresent`.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ts, forKey: .ts)
    try container.encode(t, forKey: .t)
    try container.encode(wall_clock, forKey: .wall_clock)
    try container.encode(event, forKey: .event)
    try container.encode(state, forKey: .state)
    try container.encode(screen, forKey: .screen)
    try container.encode(distance_cm, forKey: .distance_cm)
    try container.encode(pitch_deg, forKey: .pitch_deg)
    try container.encode(alert_type, forKey: .alert_type)
    try container.encode(level, forKey: .level)
    try container.encode(breach_seconds, forKey: .breach_seconds)
    try container.encode(sensitivity, forKey: .sensitivity)
    try container.encode(distance_threshold_cm, forKey: .distance_threshold_cm)
    try container.encode(pitch_threshold_deg, forKey: .pitch_threshold_deg)
    try container.encode(baseline_distance_cm, forKey: .baseline_distance_cm)
    try container.encode(baseline_pitch_deg, forKey: .baseline_pitch_deg)
    try container.encode(total_seconds, forKey: .total_seconds)
    try container.encode(good_seconds, forKey: .good_seconds)
    try container.encode(near_seconds, forKey: .near_seconds)
    try container.encode(head_down_seconds, forKey: .head_down_seconds)
    try container.encode(paused_seconds, forKey: .paused_seconds)
    try container.encode(near_count, forKey: .near_count)
    try container.encode(longest_good_streak_seconds, forKey: .longest_good_streak_seconds)
    try container.encode(scenario, forKey: .scenario)
    try container.encode(message, forKey: .message)
  }
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
      ts: Int64((now.timeIntervalSince1970 * 1000).rounded()),
      wall_clock: Self.iso8601.string(from: now)
    )

    switch self {
    case .sessionStarted(let scenario):
      record.event = "session_started"
      record.scenario = scenario

    case .config(let sensitivity, let distanceThresholdCM, let pitchThresholdDeg):
      record.event = "config"
      record.sensitivity = sensitivity.rawValue
      record.distance_threshold_cm = distanceThresholdCM
      record.pitch_threshold_deg = pitchThresholdDeg

    case .calibrated(let baselineDistanceCM, let baselinePitchDeg):
      record.event = "calibration_done"
      record.baseline_distance_cm = baselineDistanceCM
      record.baseline_pitch_deg = baselinePitchDeg

    case .screenShown(let name):
      record.event = "screen_shown"
      record.screen = name

    case .sample(let t, let distanceCM, let pitchDeg):
      record.event = "sample"
      record.t = t
      record.distance_cm = distanceCM
      record.pitch_deg = pitchDeg

    case .statusChanged(let to, let t, let distanceCM, let pitchDeg):
      record.event = "status_changed"
      record.t = t
      record.state = to.rawValue
      record.distance_cm = distanceCM
      record.pitch_deg = pitchDeg

    case .reminder(let kind, let level, let t, let breachSeconds, let distanceCM, let pitchDeg):
      record.event = "reminder"
      record.t = t
      record.alert_type = kind.rawValue
      record.level = level.rawValue
      record.breach_seconds = breachSeconds
      record.distance_cm = distanceCM
      record.pitch_deg = pitchDeg

    case .paused(let t):
      record.event = "paused"
      record.t = t

    case .resumed(let t):
      record.event = "resumed"
      record.t = t

    case .sessionEnded(let summary):
      record.event = "session_ended"
      record.total_seconds = summary.totalSeconds
      record.good_seconds = summary.goodSeconds
      record.near_seconds = summary.tooCloseSeconds
      record.head_down_seconds = summary.headDownSeconds
      record.paused_seconds = summary.pausedSeconds
      record.near_count = summary.tooCloseCount
      record.longest_good_streak_seconds = summary.longestGoodStreakSeconds
    }

    return record
  }
}
