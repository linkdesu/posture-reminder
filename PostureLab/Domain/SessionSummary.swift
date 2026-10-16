import Foundation

struct SessionSummary: Equatable, Codable {
  var startedAt: Date
  var totalSeconds: Double
  var goodSeconds: Double
  var tooCloseSeconds: Double
  var headDownSeconds: Double
  var tooCloseCount: Int
  var longestGoodStreakSeconds: Double

  var goodRatio: Double { totalSeconds > 0 ? goodSeconds / totalSeconds : 0 }
}
