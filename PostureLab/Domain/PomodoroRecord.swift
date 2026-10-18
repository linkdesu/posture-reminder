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
}

enum PomodoroOutcome: String, Codable, Equatable {
  case completed
  case abandoned
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
  /// Actually counted focus time, pauses excluded.
  var focusedSeconds: Double
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
