import Foundation

/// One calendar day of the parent report. Produced by `PomodoroHistory.day(_:on:calendar:)`.
struct ReportDay: Equatable {
  /// The calendar day this reports on, at its start-of-day boundary.
  var date: Date
  /// Pomodoros whose outcome is `.completed` that started this day.
  var completedPomodoros: Int
  /// Focus seconds summed over every record on the day, abandoned ones included.
  var focusSeconds: Double
  /// Good-posture seconds over the seconds that carried posture data at all; 0 on an empty day.
  var goodRatio: Double
  /// Per-posture seconds, keyed by `PostureKind.rawValue`; every kind has an entry.
  var postureSeconds: [String: Double]
  /// The day's posture segments, ordered by start time; the timeline draws these in order.
  var segments: [PostureSegment]
}

/// Period-wide sums for the week/month views.
struct ReportTotals: Equatable {
  var completedPomodoros: Int
  var focusSeconds: Double
  /// Good seconds over posture-data seconds across the whole period; 0 when there is none.
  var goodRatio: Double
  /// Per-posture seconds, keyed by `PostureKind.rawValue`; every kind has an entry.
  var postureSeconds: [String: Double]
}

/// A run of `ReportDay`s (a week, a month) with their totals.
struct ReportPeriod: Equatable {
  var days: [ReportDay]
  var totals: ReportTotals
}

/// Pure aggregation over `PomodoroRecord`s for the parent report. No clock, no I/O: the caller
/// supplies the records and the calendar, so tests pin a timezone and get deterministic results.
enum PomodoroHistory {
  /// Aggregates one calendar day. `date` may be any instant in the day; the day boundary comes from
  /// `calendar`, and records are assigned to the day their `startedAt` falls in.
  static func day(_ records: [PomodoroRecord], on date: Date, calendar: Calendar) -> ReportDay {
    let dayStart = calendar.startOfDay(for: date)
    let dayRecords = records.filter {
      calendar.isDate(Date(timeIntervalSince1970: $0.startedAt), inSameDayAs: dayStart)
    }
    return makeDay(date: dayStart, records: dayRecords)
  }

  /// The `count` calendar days ending on `endingAt`'s day, inclusive, oldest first.
  static func days(_ records: [PomodoroRecord],
                   endingAt: Date,
                   count: Int,
                   calendar: Calendar) -> [ReportDay] {
    guard count > 0 else { return [] }
    let endDay = calendar.startOfDay(for: endingAt)
    return (0..<count).compactMap { offset in
      guard let dayDate = calendar.date(byAdding: .day, value: -(count - 1 - offset), to: endDay) else {
        return nil
      }
      return day(records, on: dayDate, calendar: calendar)
    }
  }

  /// The `count` calendar days ending on `endingAt`'s day plus their period totals.
  static func period(_ records: [PomodoroRecord],
                     endingAt: Date,
                     count: Int,
                     calendar: Calendar) -> ReportPeriod {
    let days = days(records, endingAt: endingAt, count: count, calendar: calendar)

    var completed = 0
    var focus = 0.0
    var posture = emptyPostureSeconds()
    var good = 0.0
    var dataSeconds = 0.0
    for day in days {
      completed += day.completedPomodoros
      focus += day.focusSeconds
      for (kind, seconds) in day.postureSeconds {
        posture[kind, default: 0] += seconds
      }
      let components = ratioComponents(day.segments)
      good += components.good
      dataSeconds += components.data
    }

    let totals = ReportTotals(completedPomodoros: completed,
                              focusSeconds: focus,
                              goodRatio: dataSeconds > 0 ? good / dataSeconds : 0,
                              postureSeconds: posture)
    return ReportPeriod(days: days, totals: totals)
  }

  // MARK: - Private

  private static func makeDay(date: Date, records: [PomodoroRecord]) -> ReportDay {
    var completed = 0
    var focus = 0.0
    var posture = emptyPostureSeconds()
    var segments: [PostureSegment] = []
    var good = 0.0
    var dataSeconds = 0.0

    for record in records {
      if record.outcome == .completed { completed += 1 }
      focus += record.focusedSeconds
      for segment in record.postureSegments {
        // Every segment reaches the timeline, the non-posture bands included; only the ones the
        // domain vocabulary recognises feed the figures below.
        segments.append(segment)
        // `detecting` (the wait before the first sample), `no_data` (a stalled stream) and
        // `paused` are not `PostureStatus` values, so they fail this parse and are skipped whole:
        // none adds to the bad-posture tally, to `postureSeconds`, nor to the denominator of the
        // good ratio. They are still in `segments`, which is what lets the band draw them without
        // the day being scored for them.
        guard let status = PostureStatus(rawValue: segment.kind) else { continue }
        switch status {
        case .good:
          good += segment.seconds
          dataSeconds += segment.seconds
        case .posture(let kind):
          posture[kind.rawValue, default: 0] += segment.seconds
          dataSeconds += segment.seconds
        case .noPerson:
          break
        }
      }
    }

    segments.sort { $0.start < $1.start }
    return ReportDay(date: date,
                     completedPomodoros: completed,
                     focusSeconds: focus,
                     goodRatio: dataSeconds > 0 ? good / dataSeconds : 0,
                     postureSeconds: posture,
                     segments: segments)
  }

  /// Good seconds and the seconds that carried posture data at all: `no_person` is excluded from
  /// the denominator because absence is not a posture the child could have held, and every kind the
  /// domain vocabulary does not recognise — `detecting` (the wait before the first sample),
  /// `no_data` (a stalled stream) and `paused` — is excluded for the same reason by the parse
  /// below. Keeping them out is what makes the ratio a share of measured postures rather than of
  /// the whole focus.
  private static func ratioComponents(_ segments: [PostureSegment]) -> (good: Double, data: Double) {
    var good = 0.0
    var data = 0.0
    for segment in segments {
      guard let status = PostureStatus(rawValue: segment.kind) else { continue }
      switch status {
      case .good:
        good += segment.seconds
        data += segment.seconds
      case .posture:
        data += segment.seconds
      case .noPerson:
        break
      }
    }
    return (good, data)
  }

  private static func emptyPostureSeconds() -> [String: Double] {
    var seconds: [String: Double] = [:]
    for kind in PostureKind.allCases { seconds[kind.rawValue] = 0 }
    return seconds
  }
}
