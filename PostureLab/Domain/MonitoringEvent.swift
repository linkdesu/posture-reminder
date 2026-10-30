import Foundation

enum MonitoringEvent: Equatable {
  case sessionStarted(scenario: String?)
  case config(sensitivity: Sensitivity, distanceThresholdCM: Double, pitchThresholdDeg: Double)
  case calibrated(baselineDistanceCM: Double, baselinePitchDeg: Double)
  case screenShown(name: String)
  case sample(t: TimeInterval, distanceCM: Double?, pitchDeg: Double?)
  case statusChanged(to: PostureStatus, t: TimeInterval, distanceCM: Double?, pitchDeg: Double?)
  case reminder(kind: PostureKind, level: ReminderLevel, t: TimeInterval, breachSeconds: Double, distanceCM: Double?, pitchDeg: Double?)
  /// Feature sample line, one per five samples (2 Hz at the 10 Hz tick): enough for QA to
  /// reconstruct a decision, not enough to flood the log.
  case features(t: TimeInterval, readings: [FeatureReading], highlighted: PostureFeature?)
  /// Layer state, written when the avatar/black-board mode or either overlay switch changes.
  case viewMode(mode: String, overlay: Bool, avatar: Bool)
  /// The pomodoro countdown, once per second of the sample clock while a phase runs. A countdown
  /// that keeps moving is only provable as a series of lines, but one per sample (10 Hz) would bury
  /// the log, so a tick is written when the sample clock crosses into a new whole second.
  case pomodoroTick(remainingSeconds: Double, phase: String)
  /// Speech watchdog: the player stopped awaiting synthesis for too long. The speaker has no
  /// session clock, so these carry no `t`.
  case speechTimeout(kind: PostureKind, level: ReminderLevel)
  case speechUnavailable(kind: PostureKind)
  /// A voice clip reported that it started playing. Written when the player actually starts the
  /// clip, not when it is queued, so the line never claims a sound the device did not make; an asset
  /// that is missing or will not play reports `speechUnavailable` instead.
  case speechPlayed(kind: PostureKind, level: ReminderLevel)
  /// A pomodoro cue — the one-minute warning or an end sound — reported that it started playing.
  /// Written on the same rule as `speechPlayed`: only once playback really began, so the line never
  /// claims a sound the device did not make. The cue's name rides in the log's existing `message`
  /// key rather than a key of its own.
  case cuePlayed(cue: String)
  /// A focus timeline segment, written when a non-posture band closes: the「识别中」段 from the 开始
  /// tap to the focus's first posture sample (`detecting`), or a stretch after it with no sample at
  /// all (`no_data`, v0.6.1). Times are Unix epoch seconds, so they sit on the same axis as the
  /// record's `startedAt`.
  case segment(kind: String, start: TimeInterval, end: TimeInterval)
  /// 发热降级开始或结束：`serious`/`critical` 时 Vision 降到 5 Hz、点云降到 15 Hz。两侧各写一行，
  /// 读者按 `thermal_degraded` 的翻转切出降级时段；`thermal_state` 仍由写入器按采样值盖上。
  case thermal(degraded: Bool)
  case paused(t: TimeInterval)
  case resumed(t: TimeInterval)
  case sessionEnded(summary: SessionSummary)
}

/// One feature's reading on a `features` line, `{"value": …, "threshold": …, "over": …}`.
/// It is the wire shape of `FeatureReading`: the baseline is dropped because QA can read it off
/// the `calibration_done` line.
struct FeatureLogValue: Codable, Equatable {
  var value: Double
  var threshold: Double
  var over: Bool
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
    case near_remind_count
    case head_down_count
    case head_down_remind_count
    case longest_good_streak_seconds
    case scenario
    case message
    case battery_level
    case thermal_state
    case highlighted_feature
    case feature_values
    case view_mode
    case overlay_on
    case avatar_on
    case posture_stats
    case remaining_seconds
    case phase
    case segment_kind
    case segment_start
    case segment_end
    case segment_seconds
    case thermal_degraded
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
  var near_remind_count: Int?
  var head_down_count: Int?
  var head_down_remind_count: Int?
  var longest_good_streak_seconds: Double?
  var scenario: String?
  var message: String?
  /// Battery charge in 0...1; filled by the writer, not the event.
  var battery_level: Double?
  /// One of `nominal`, `fair`, `serious`, `critical`; filled by the writer, not the event.
  var thermal_state: String?
  /// The feature the debug overlay highlights, on `features` lines.
  var highlighted_feature: String?
  /// Per-feature readings of a `features` line, keyed by `PostureFeature.rawValue`.
  var feature_values: [String: FeatureLogValue]?
  /// Layer state, on `view_mode` lines.
  var view_mode: String?
  var overlay_on: Bool?
  var avatar_on: Bool?
  /// Per-posture counts and accumulated breach seconds, on the `session_ended` line; keyed by
  /// `PostureKind.rawValue`.
  var posture_stats: [String: PostureStat]?
  /// Seconds left in the pomodoro phase, on a `pomodoro_tick` line.
  var remaining_seconds: Double?
  /// The pomodoro phase rawValue (`focus` / `shortBreak` / `longBreak`), on a `pomodoro_tick` line.
  var phase: String?
  /// The timeline segment kind, on a `segment` line: `detecting` for the 识别中段, `no_data` for a
  /// stalled stream after the first sample.
  var segment_kind: String?
  /// The segment's start and end, Unix epoch milliseconds, on a `segment` line.
  var segment_start: Int64?
  var segment_end: Int64?
  /// The segment's length in seconds, on a `segment` line.
  var segment_seconds: Double?
  /// Whether a `thermal` line marks the start (`true`) or the end (`false`) of a heat-driven
  /// degradation of the capture load.
  var thermal_degraded: Bool?

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
    try container.encode(near_remind_count, forKey: .near_remind_count)
    try container.encode(head_down_count, forKey: .head_down_count)
    try container.encode(head_down_remind_count, forKey: .head_down_remind_count)
    try container.encode(longest_good_streak_seconds, forKey: .longest_good_streak_seconds)
    try container.encode(scenario, forKey: .scenario)
    try container.encode(message, forKey: .message)
    try container.encode(battery_level, forKey: .battery_level)
    try container.encode(thermal_state, forKey: .thermal_state)
    try container.encode(highlighted_feature, forKey: .highlighted_feature)
    try container.encode(feature_values, forKey: .feature_values)
    try container.encode(view_mode, forKey: .view_mode)
    try container.encode(overlay_on, forKey: .overlay_on)
    try container.encode(avatar_on, forKey: .avatar_on)
    try container.encode(posture_stats, forKey: .posture_stats)
    try container.encode(remaining_seconds, forKey: .remaining_seconds)
    try container.encode(phase, forKey: .phase)
    try container.encode(segment_kind, forKey: .segment_kind)
    try container.encode(segment_start, forKey: .segment_start)
    try container.encode(segment_end, forKey: .segment_end)
    try container.encode(segment_seconds, forKey: .segment_seconds)
    try container.encode(thermal_degraded, forKey: .thermal_degraded)
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

    case .features(let t, let readings, let highlighted):
      record.event = "features"
      record.t = t
      record.highlighted_feature = highlighted?.rawValue
      var values: [String: FeatureLogValue] = [:]
      for reading in readings {
        values[reading.feature.rawValue] = FeatureLogValue(value: reading.value,
                                                          threshold: reading.threshold,
                                                          over: reading.isOverThreshold)
      }
      record.feature_values = values

    case .viewMode(let mode, let overlay, let avatar):
      record.event = "view_mode"
      record.view_mode = mode
      record.overlay_on = overlay
      record.avatar_on = avatar

    case .pomodoroTick(let remainingSeconds, let phase):
      record.event = "pomodoro_tick"
      record.remaining_seconds = remainingSeconds
      record.phase = phase

    case .reminder(let kind, let level, let t, let breachSeconds, let distanceCM, let pitchDeg):
      record.event = "reminder"
      record.t = t
      record.alert_type = kind.rawValue
      record.level = level.rawValue
      record.breach_seconds = breachSeconds
      record.distance_cm = distanceCM
      record.pitch_deg = pitchDeg

    case .speechTimeout(let kind, let level):
      record.event = "speech_timeout"
      record.alert_type = kind.rawValue
      record.level = level.rawValue

    case .speechUnavailable(let kind):
      record.event = "speech_unavailable"
      record.alert_type = kind.rawValue

    case .speechPlayed(let kind, let level):
      record.event = "speech_played"
      record.alert_type = kind.rawValue
      record.level = level.rawValue

    case .cuePlayed(let cue):
      record.event = "cue_played"
      record.message = cue

    case .segment(let kind, let start, let end):
      record.event = "segment"
      record.segment_kind = kind
      record.segment_start = Int64((start * 1000).rounded())
      record.segment_end = Int64((end * 1000).rounded())
      record.segment_seconds = max(0, end - start)

    case .thermal(let degraded):
      record.event = "thermal"
      record.thermal_degraded = degraded

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
      record.near_remind_count = summary.tooCloseRemindCount
      record.head_down_count = summary.headDownCount
      record.head_down_remind_count = summary.headDownRemindCount
      record.longest_good_streak_seconds = summary.longestGoodStreakSeconds
      record.posture_stats = summary.postureStats
    }

    return record
  }
}
