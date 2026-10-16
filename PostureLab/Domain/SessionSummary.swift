import Foundation

struct SessionSummary: Equatable, Codable {
  var startedAt: Date
  var totalSeconds: Double
  var goodSeconds: Double
  var tooCloseSeconds: Double
  var headDownSeconds: Double
  /// Time the face was not detected; excluded from `totalSeconds`.
  var pausedSeconds: Double
  /// Episodes that reached level 1.
  var tooCloseCount: Int
  /// Reminder lines of kind tooClose, both levels; an escalated episode counts twice.
  var tooCloseRemindCount: Int
  /// Head-down episodes that reached level 1.
  var headDownCount: Int
  /// Reminder lines of kind headDown, both levels.
  var headDownRemindCount: Int
  var longestGoodStreakSeconds: Double

  var goodRatio: Double { totalSeconds > 0 ? goodSeconds / totalSeconds : 0 }
}
