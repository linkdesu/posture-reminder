import Foundation

/// Persisted pomodoro history: reads and writes `Documents/pomodoro-history.json`.
///
/// Same durability contract as `SessionStore`: a missing or unparseable file starts an empty
/// history instead of throwing, and a record accepted into `records` stays there even if the write
/// fails. `records` is always kept sorted by `startedAt` ascending.
final class PomodoroStore {
  static let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

  private static let fileName = "pomodoro-history.json"

  private let fileURL: URL

  private(set) var records: [PomodoroRecord]

  init(fileURL: URL = PomodoroStore.defaultDirectory.appendingPathComponent(PomodoroStore.fileName)) {
    self.fileURL = fileURL

    let stored = try? Data(contentsOf: fileURL)
    let decoded = stored.flatMap { try? JSONDecoder().decode([PomodoroRecord].self, from: $0) }
    records = (decoded ?? []).sorted { $0.startedAt < $1.startedAt }
  }

  /// Inserts keeping `startedAt` ascending; equal start times keep insertion order. The record is
  /// in memory before the write, so a failed write never drops an accepted record.
  func add(_ record: PomodoroRecord) {
    let index = records.firstIndex { $0.startedAt > record.startedAt } ?? records.endIndex
    records.insert(record, at: index)
    persist()
  }

  func clear() {
    records = []
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  /// Synthesised history for `-seedHistory` and the screenshot scenarios.
  ///
  /// Deterministic: the same `days` and `endingAt` produce byte-identical records, so a screenshot
  /// taken twice shows the same history. Randomness comes from a fixed-seed generator, never
  /// `SystemRandomNumberGenerator`. Per day: a few completed pomodoros with varied posture segments
  /// and reminder counts, and a believable spread of good and bad posture seconds. Days are laid out
  /// on the calendar's day boundaries, oldest first.
  static func seeds(days: Int, endingAt: Date) -> [PomodoroRecord] {
    guard days > 0 else { return [] }

    var rng = SeededRandom(seed: 0x5EED_C0DE_2026)
    let calendar = Calendar.current
    let endDay = calendar.startOfDay(for: endingAt)
    let speakingKinds = PostureKind.allCases.filter { $0.voiceLine != nil }.map(\.rawValue)
    let goodKind = PostureStatus.good.rawValue
    let noPersonKind = PostureStatus.noPerson.rawValue

    var result: [PomodoroRecord] = []
    for offset in stride(from: days - 1, through: 0, by: -1) {
      guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: endDay) else { continue }
      let sessions = rng.int(2...5)
      for index in 0..<sessions {
        let base = dayStart.addingTimeInterval(9.0 * 3600.0 + Double(index) * 50.0 * 60.0 + rng.double(0...600))
        let startedAt = base.timeIntervalSince1970
        let planned = 25.0 * 60
        let paused = rng.double(0...90)
        let skippedBreak = rng.int(0...3) == 0

        let badCount = rng.int(1...2)
        var badKinds: [String] = []
        var badDurations: [Double] = []
        for _ in 0..<badCount {
          badKinds.append(speakingKinds[rng.int(0...(speakingKinds.count - 1))])
          badDurations.append(rng.double(20...150))
        }
        let noPersonSeconds = rng.int(0...2) == 0 ? rng.double(5...30) : 0
        let badTotal = badDurations.reduce(0, +)
        let goodTotal = max(30, planned - badTotal - noPersonSeconds)

        var segments: [PostureSegment] = []
        var cursor = startedAt
        let parts = badCount + 1
        var remainingGood = goodTotal
        for part in 0..<parts {
          let duration = part == parts - 1 ? remainingGood : goodTotal / Double(parts)
          remainingGood -= duration
          let goodSeconds = max(0, duration)
          segments.append(PostureSegment(kind: goodKind, start: cursor, end: cursor + goodSeconds))
          cursor += goodSeconds
          if part < badCount {
            segments.append(PostureSegment(kind: badKinds[part], start: cursor, end: cursor + badDurations[part]))
            cursor += badDurations[part]
            if part == 0 && noPersonSeconds > 0 {
              segments.append(PostureSegment(kind: noPersonKind, start: cursor, end: cursor + noPersonSeconds))
              cursor += noPersonSeconds
            }
          }
        }

        var reminders: [String: Int] = [:]
        for kind in badKinds {
          reminders[kind, default: 0] += rng.int(0...3)
        }

        result.append(PomodoroRecord(
          id: rng.uuid(),
          startedAt: startedAt,
          endedAt: startedAt + planned + paused,
          plannedSeconds: planned,
          focusedSeconds: planned,
          pausedSeconds: paused,
          outcome: .completed,
          skippedBreak: skippedBreak,
          focusIndex: index + 1,
          postureSegments: segments,
          reminderCounts: reminders))
      }
    }
    return result
  }
}

/// Deterministic generator for `seeds`. SplitMix64: for a fixed seed and call order it always
/// yields the same stream, so seeded history does not change between runs.
private struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  private mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    let span = UInt64(range.upperBound - range.lowerBound + 1)
    return range.lowerBound + Int(next() % span)
  }

  mutating func double(_ range: ClosedRange<Double>) -> Double {
    let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    return range.lowerBound + unit * (range.upperBound - range.lowerBound)
  }

  /// A deterministic UUID, so seeded records are byte-identical across calls.
  mutating func uuid() -> UUID {
    let hi = next()
    let lo = next()
    let hex = Array(String(format: "%016llx%016llx", hi, lo))
    let formatted = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
      + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
    return UUID(uuidString: formatted)!
  }
}
