import XCTest
@testable import PostureLab

final class PomodoroHistoryTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func segment(_ kind: String, from base: Date, start: Double, end: Double) -> PostureSegment {
    PostureSegment(kind: kind,
                   start: base.timeIntervalSince1970 + start,
                   end: base.timeIntervalSince1970 + end)
  }

  private func record(startedAt: Date,
                      focusedSeconds: Double = 1500,
                      outcome: PomodoroOutcome = .completed,
                      segments: [PostureSegment]) -> PomodoroRecord {
    PomodoroRecord(startedAt: startedAt.timeIntervalSince1970,
                   endedAt: startedAt.timeIntervalSince1970 + focusedSeconds,
                   plannedSeconds: focusedSeconds,
                   focusedSeconds: focusedSeconds,
                   pausedSeconds: 0,
                   outcome: outcome,
                   skippedBreak: false,
                   focusIndex: 1,
                   postureSegments: segments,
                   reminderCounts: [:])
  }

  // MARK: - Day aggregation

  func testDayAggregatesLiteralFocusSegmentsAndPostureTotals() throws {
    let base = date(2026, 10, 15, hour: 9)
    let good = PostureStatus.good.rawValue
    let near = PostureKind.near.rawValue
    let headDown = PostureKind.headDown.rawValue
    let noPerson = PostureStatus.noPerson.rawValue

    let segments = [
      segment(good, from: base, start: 0, end: 1080),
      segment(near, from: base, start: 1080, end: 1320),
      segment(headDown, from: base, start: 1320, end: 1440),
      segment(noPerson, from: base, start: 1440, end: 1500),
    ]
    let entry = record(startedAt: base, focusedSeconds: 1500, segments: segments)

    let day = PomodoroHistory.day([entry], on: base, calendar: calendar)

    XCTAssertEqual(day.date, calendar.startOfDay(for: base))
    XCTAssertEqual(day.completedPomodoros, 1)
    XCTAssertEqual(day.focusSeconds, 1500, accuracy: 1e-9)
    XCTAssertEqual(day.segments, segments)
    XCTAssertEqual(seconds(day, near), 240, accuracy: 1e-9)
    XCTAssertEqual(seconds(day, headDown), 120, accuracy: 1e-9)
    XCTAssertEqual(seconds(day, PostureKind.deskLean.rawValue), 0, accuracy: 1e-9)
    XCTAssertEqual(seconds(day, PostureKind.headTilt.rawValue), 0, accuracy: 1e-9)
    // good 1080 over posture-data 1440 (the 60 s of no_person are excluded).
    XCTAssertEqual(day.goodRatio, 0.75, accuracy: 1e-9)
  }

  /// A missing key becomes NaN rather than 0, so an absent posture fails the assertion instead
  /// of reading as "zero seconds of it", which is exactly what a vacuous pass looks like.
  private func seconds(_ day: ReportDay, _ kind: String) -> Double {
    day.postureSeconds[kind] ?? .nan
  }

  func testEmptyDayReportsZeroRatioAndAllPostureKeys() {
    let day = PomodoroHistory.day([], on: date(2026, 10, 15), calendar: calendar)

    XCTAssertEqual(day.completedPomodoros, 0)
    XCTAssertEqual(day.focusSeconds, 0, accuracy: 1e-9)
    XCTAssertEqual(day.goodRatio, 0, accuracy: 1e-9)
    XCTAssertEqual(day.segments, [])
    XCTAssertEqual(day.postureSeconds.count, PostureKind.allCases.count)
    for kind in PostureKind.allCases {
      XCTAssertEqual(seconds(day, kind.rawValue), 0, accuracy: 1e-9)
    }
  }

  func testAbandonedRecordCountsTowardFocusButNotCompleted() {
    let base = date(2026, 10, 15, hour: 9)
    let done = record(startedAt: base, focusedSeconds: 600, outcome: .completed, segments: [])
    let dropped = record(startedAt: base.addingTimeInterval(3600), focusedSeconds: 300, outcome: .abandoned, segments: [])

    let day = PomodoroHistory.day([done, dropped], on: base, calendar: calendar)

    XCTAssertEqual(day.completedPomodoros, 1)
    XCTAssertEqual(day.focusSeconds, 900, accuracy: 1e-9)
  }

  func testGoodRatioIsTheValueTheSegmentsImply() {
    let base = date(2026, 10, 15, hour: 9)
    let good = PostureStatus.good.rawValue
    let segments = [
      segment(good, from: base, start: 0, end: 300),
      segment(PostureKind.headTilt.rawValue, from: base, start: 300, end: 600),
    ]

    let day = PomodoroHistory.day([record(startedAt: base, segments: segments)], on: base, calendar: calendar)

    XCTAssertEqual(day.goodRatio, 0.5, accuracy: 1e-9)
  }

  // MARK: - Week and month

  func testWeekAggregatesSevenDays() {
    let endingAt = date(2026, 10, 15, hour: 12)
    let records = (0..<7).map { offset -> PomodoroRecord in
      record(startedAt: date(2026, 10, 9 + offset, hour: 9),
             focusedSeconds: 600,
             segments: [])
    }

    let days = PomodoroHistory.days(records, endingAt: endingAt, count: 7, calendar: calendar)

    XCTAssertEqual(days.count, 7)
    XCTAssertEqual(days.first?.date, calendar.startOfDay(for: date(2026, 10, 9)))
    XCTAssertEqual(days.last?.date, calendar.startOfDay(for: date(2026, 10, 15)))
    XCTAssertTrue(days.allSatisfy { $0.completedPomodoros == 1 })
    XCTAssertEqual(days.reduce(0.0) { $0 + $1.focusSeconds }, 4200, accuracy: 1e-9)

    let period = PomodoroHistory.period(records, endingAt: endingAt, count: 7, calendar: calendar)
    XCTAssertEqual(period.days.count, 7)
    XCTAssertEqual(period.totals.completedPomodoros, 7)
    XCTAssertEqual(period.totals.focusSeconds, 4200, accuracy: 1e-9)
  }

  func testMonthDayCountMatchesCalendar() {
    let october = date(2026, 10, 15)
    let february = date(2026, 2, 10)

    let octoberCount = calendar.range(of: .day, in: .month, for: october)!.count
    let februaryCount = calendar.range(of: .day, in: .month, for: february)!.count
    XCTAssertEqual(octoberCount, 31)
    XCTAssertEqual(februaryCount, 28)

    let octoberDays = PomodoroHistory.days([], endingAt: october, count: octoberCount, calendar: calendar)
    let februaryDays = PomodoroHistory.days([], endingAt: february, count: februaryCount, calendar: calendar)
    XCTAssertEqual(octoberDays.count, 31)
    XCTAssertEqual(februaryDays.count, 28)
  }

  // MARK: - Seeds

  func testSeedsAreDeterministicAcrossCalls() throws {
    let endingAt = date(2026, 10, 15, hour: 12)

    let first = PomodoroStore.seeds(days: 30, endingAt: endingAt)
    let second = PomodoroStore.seeds(days: 30, endingAt: endingAt)

    XCTAssertFalse(first.isEmpty)
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.allSatisfy { !$0.postureSegments.isEmpty && $0.focusIndex >= 1 && $0.outcome == .completed })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
  }

  func testSeedsCoverEachRequestedDay() {
    // `seeds` lays the days out on `Calendar.current`; bucket with the same calendar.
    let storeCalendar = Calendar.current
    let endingAt = storeCalendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    let seeded = PomodoroStore.seeds(days: 30, endingAt: endingAt)

    let daysWithRecords = Set(seeded.map { storeCalendar.startOfDay(for: Date(timeIntervalSince1970: $0.startedAt)) })
    XCTAssertEqual(daysWithRecords.count, 30)
    XCTAssertTrue(daysWithRecords.contains(storeCalendar.startOfDay(for: endingAt)))
  }

  // MARK: - Store

  func testStoreStartsEmptyOnCorruptFileAndKeepsAddedRecords() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pomodoro-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("pomodoro-history.json")
    try Data("{ not valid json".utf8).write(to: url)

    let store = PomodoroStore(fileURL: url)
    XCTAssertTrue(store.records.isEmpty)

    let early = record(startedAt: date(2026, 10, 15, hour: 9), segments: [])
    let late = record(startedAt: date(2026, 10, 15, hour: 10), segments: [])
    store.add(late)
    store.add(early)

    XCTAssertEqual(store.records, [early, late])

    let reloaded = PomodoroStore(fileURL: url)
    XCTAssertEqual(reloaded.records, [early, late])
  }

  func testStoreClearRemovesEverything() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pomodoro-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("pomodoro-history.json")
    let store = PomodoroStore(fileURL: url)
    store.add(record(startedAt: date(2026, 10, 15, hour: 9), segments: []))
    XCTAssertEqual(store.records.count, 1)

    store.clear()
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertTrue(PomodoroStore(fileURL: url).records.isEmpty)
  }

  /// v0.6: the「识别中」band is on the timeline but is not a posture. It adds no bad-posture seconds,
  /// no good seconds and no denominator, so a focus whose camera answered late is scored on what was
  /// actually measured rather than on the wait.
  func testDetectingBandIsDrawnButNotScoredAsPosture() {
    let base = date(2026, 10, 20, hour: 9)
    let near = PostureKind.near.rawValue
    let segments = [
      segment(PostureSegment.detectingKind, from: base, start: 0, end: 1.4),
      segment(near, from: base, start: 1.4, end: 11.4),
      segment(PostureStatus.good.rawValue, from: base, start: 11.4, end: 60),
    ]
    let entry = record(startedAt: base, focusedSeconds: 60, segments: segments)

    let day = PomodoroHistory.day([entry], on: base, calendar: calendar)

    XCTAssertEqual(day.segments, segments)
    XCTAssertEqual(seconds(day, near), 10, accuracy: 1e-9)
    XCTAssertNil(day.postureSeconds[PostureSegment.detectingKind])
    XCTAssertEqual(day.postureSeconds.values.reduce(0, +), 10, accuracy: 1e-9,
                   "detecting must not add seconds to any posture")
    XCTAssertEqual(day.goodRatio, 48.6 / 58.6, accuracy: 1e-9,
                   "the wait is not in the ratio's denominator")
  }

  /// v0.6.1: a stretch with no sample is drawn but never scored, and — the point of the fix — it
  /// takes the seconds away from the posture that preceded it instead of letting that posture carry
  /// the report visit. 9.6 s good / (9.6 good + 20 near) is the whole ratio; the 30 s of no data
  /// is in neither the numerator nor the denominator.
  func testNoDataBandIsDrawnButNotScoredAsPosture() {
    let base = date(2026, 10, 21, hour: 9)
    let near = PostureKind.near.rawValue
    let segments = [
      segment(PostureSegment.detectingKind, from: base, start: 0, end: 0.4),
      segment(PostureStatus.good.rawValue, from: base, start: 0.4, end: 10),
      segment(PostureSegment.noDataKind, from: base, start: 10, end: 40),
      segment(near, from: base, start: 40, end: 60),
    ]
    let entry = record(startedAt: base, focusedSeconds: 60, segments: segments)

    let day = PomodoroHistory.day([entry], on: base, calendar: calendar)

    XCTAssertEqual(day.segments, segments)
    XCTAssertEqual(seconds(day, near), 20, accuracy: 1e-9)
    XCTAssertNil(day.postureSeconds[PostureSegment.noDataKind])
    XCTAssertEqual(day.postureSeconds.values.reduce(0, +), 20, accuracy: 1e-9,
                   "no_data must not add seconds to any posture")
    XCTAssertEqual(day.goodRatio, 9.6 / 29.6, accuracy: 1e-6,
                   "the gap is not in the ratio's denominator, and its seconds are not good posture")
  }
}
