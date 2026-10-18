import Foundation

/// One posture's three numbers in a session; the value type of `SessionSummary.postureStats`.
struct PostureStat: Equatable, Codable {
  /// Episodes that reached level 1.
  var episodes: Int
  /// Reminder lines actually emitted, both levels; an escalated episode counts twice.
  var reminders: Int
  /// Breaching seconds accumulated for this posture, with pauses excluded.
  var seconds: Double

  enum CodingKeys: String, CodingKey {
    case episodes
    case reminders
    case seconds
  }
}

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
  /// Per-posture statistics, keyed by `PostureKind.rawValue`: a string key keeps the dictionary
  /// stable under `Codable`. Every kind has an entry from construction on, so a session that ends
  /// before its first usable sample still reports all seven. The v2 fields above stay because QA's
  /// evidence and the checker read them.
  var postureStats: [String: PostureStat] = SessionSummary.zeroPostureStats()

  /// Stored-property names, which are the JSON keys of `sessions.json`. Declared so the tolerant
  /// `init(from:)` below and the synthesised `encode(to:)` read the same list.
  enum CodingKeys: String, CodingKey {
    case startedAt
    case totalSeconds
    case goodSeconds
    case tooCloseSeconds
    case headDownSeconds
    case pausedSeconds
    case tooCloseCount
    case tooCloseRemindCount
    case headDownCount
    case headDownRemindCount
    case longestGoodStreakSeconds
    case postureStats
  }

  var goodRatio: Double { totalSeconds > 0 ? goodSeconds / totalSeconds : 0 }

  /// All seven postures at zero, the state a fresh summary starts in.
  static func zeroPostureStats() -> [String: PostureStat] {
    Dictionary(uniqueKeysWithValues: PostureKind.allCases.map {
      ($0.rawValue, PostureStat(episodes: 0, reminders: 0, seconds: 0))
    })
  }

  /// The statistics of one posture; a kind with no entry reads back as all zeros.
  func stat(_ kind: PostureKind) -> PostureStat {
    postureStats[kind.rawValue] ?? PostureStat(episodes: 0, reminders: 0, seconds: 0)
  }

  /// Episodes of the experimental tier. Those kinds never speak, so the summary folds them into a
  /// single line instead of a row each: otherwise "no reminders but many violations" reads as a
  /// contradiction.
  var experimentalEpisodes: Int {
    PostureKind.allCases.filter { $0.tier == .experimental }.reduce(0) { $0 + stat($1).episodes }
  }
}

// The saved history outlives the schema, and `SessionStore` loads it with `try?`, so a key added
// after a file was written must not throw the file away. The decoders live in extensions: an
// initialiser in the type body itself would suppress the memberwise one.
extension SessionSummary {
  /// Every key but `startedAt` — the record's origin, present since the first schema — falls back
  /// to its zero value when absent. Encoding stays synthesised and still writes all of them.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    totalSeconds = try container.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
    goodSeconds = try container.decodeIfPresent(Double.self, forKey: .goodSeconds) ?? 0
    tooCloseSeconds = try container.decodeIfPresent(Double.self, forKey: .tooCloseSeconds) ?? 0
    headDownSeconds = try container.decodeIfPresent(Double.self, forKey: .headDownSeconds) ?? 0
    pausedSeconds = try container.decodeIfPresent(Double.self, forKey: .pausedSeconds) ?? 0
    tooCloseCount = try container.decodeIfPresent(Int.self, forKey: .tooCloseCount) ?? 0
    tooCloseRemindCount = try container.decodeIfPresent(Int.self, forKey: .tooCloseRemindCount) ?? 0
    headDownCount = try container.decodeIfPresent(Int.self, forKey: .headDownCount) ?? 0
    headDownRemindCount = try container.decodeIfPresent(Int.self, forKey: .headDownRemindCount) ?? 0
    longestGoodStreakSeconds =
      try container.decodeIfPresent(Double.self, forKey: .longestGoodStreakSeconds) ?? 0
    postureStats = try container.decodeIfPresent([String: PostureStat].self, forKey: .postureStats)
      ?? SessionSummary.zeroPostureStats()
  }
}

extension PostureStat {
  /// A missing count reads as zero: an entry saved before a field existed must not fail the whole
  /// dictionary it sits in.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    episodes = try container.decodeIfPresent(Int.self, forKey: .episodes) ?? 0
    reminders = try container.decodeIfPresent(Int.self, forKey: .reminders) ?? 0
    seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
  }
}
