import Foundation

/// One stretch of the posture timeline inside a pomodoro.
///
/// `kind` is a `PostureStatus.rawValue` — a `PostureKind.rawValue`, `"good"` or `"no_person"`.
/// Times are epoch seconds so that segments from different sessions can be laid on the same
/// day/week/month axis.
struct PostureSegment: Equatable, Codable {
  var kind: String
  var start: Double
  var end: Double

  var seconds: Double { max(0, end - start) }

  init(kind: String, start: Double, end: Double) {
    self.kind = kind
    self.start = start
    self.end = end
  }

  /// The「识别中」band (v0.6): from the 开始 tap to the focus's first posture sample. It is a segment
  /// of its own, never part of the first posture, and the aggregation neither scores it nor counts it
  /// in the good-posture ratio.
  static let detectingKind = "detecting"
  /// The pause band (B2): wall time the focus did not count. Not a posture, and not a `state` value.
  static let pausedKind = "paused"
}

enum PomodoroOutcome: String, Codable, Equatable {
  case completed
  case abandoned
  /// The child stayed away from a focus longer than the engine allows, so the focus ended where it
  /// stood (B5). Not a completion: no break follows it and the countdown is re-armed for the next
  /// start.
  case interrupted
}

/// One pomodoro as it is persisted: the plan, what actually happened, and the evidence attached to
/// it.
///
/// The engine fills the plan and the timing; `postureSegments` and `reminderCounts` are attached by
/// the aggregation side, which is the only place that sees `MonitoringEngine`'s per-posture numbers.
/// They stay in the record so a stored history carries its own evidence.
struct PomodoroRecord: Equatable, Codable, Identifiable {
  var id: UUID
  /// Epoch seconds.
  var startedAt: Double
  /// Epoch seconds; absent while the pomodoro is still in flight.
  var endedAt: Double?
  var plannedSeconds: Double
  /// Actually counted focus time: pauses and absences excluded, so it is never time the child was
  /// not in front of the camera.
  var focusedSeconds: Double
  /// Time the focus spent manually paused (B2). An absence is not a pause — it is only excluded.
  var pausedSeconds: Double
  var outcome: PomodoroOutcome
  var skippedBreak: Bool
  var focusIndex: Int
  var postureSegments: [PostureSegment]
  /// Keyed by `PostureKind.rawValue`.
  var reminderCounts: [String: Int]

  init(id: UUID = UUID(),
       startedAt: Double,
       endedAt: Double? = nil,
       plannedSeconds: Double,
       focusedSeconds: Double,
       pausedSeconds: Double,
       outcome: PomodoroOutcome,
       skippedBreak: Bool = false,
       focusIndex: Int,
       postureSegments: [PostureSegment] = [],
       reminderCounts: [String: Int] = [:]) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.plannedSeconds = plannedSeconds
    self.focusedSeconds = focusedSeconds
    self.pausedSeconds = pausedSeconds
    self.outcome = outcome
    self.skippedBreak = skippedBreak
    self.focusIndex = focusIndex
    self.postureSegments = postureSegments
    self.reminderCounts = reminderCounts
  }
}
