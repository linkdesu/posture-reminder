import XCTest
@testable import PostureLab

/// 0.6.7：首页「今天 x/目标」在专注倒计时归零那一刻加一，放弃不加，下一阶段开始（落盘）时不重复加。
final class CompletedTodayCountTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10))!

  private func record(_ outcome: PomodoroOutcome, minutesAgo: Double = 30) -> PomodoroRecord {
    let start = now.timeIntervalSince1970 - minutesAgo * 60
    return PomodoroRecord(startedAt: start, endedAt: start + 1500, plannedSeconds: 1500,
                          focusedSeconds: 1500, pausedSeconds: 0, outcome: outcome,
                          skippedBreak: false, focusIndex: 1, postureSegments: [], reminderCounts: [:])
  }

  private func count(_ records: [PomodoroRecord], pending: PomodoroRecord?) -> Int {
    PomodoroHistory.completedToday(records, pending: pending, now: now, calendar: calendar)
  }

  func testCountdownReachingZeroCountsBeforeBreakEnds() {
    let stored = [record(.completed, minutesAgo: 90)]
    XCTAssertEqual(count(stored, pending: nil), 1)
    // 归零：记录处于待落盘（休息中），计数立即 +1。
    XCTAssertEqual(count(stored, pending: record(.completed)), 2)
  }

  func testAbandonedFocusDoesNotCount() {
    let stored = [record(.completed, minutesAgo: 90)]
    XCTAssertEqual(count(stored, pending: record(.abandoned)), 1)
    XCTAssertEqual(count(stored + [record(.abandoned)], pending: nil), 1)
  }

  func testNextPhaseStartDoesNotCountTwice() {
    let finished = record(.completed)
    let stored = [record(.completed, minutesAgo: 90)]
    XCTAssertEqual(count(stored, pending: finished), 2)
    // 休息结束、下一段专注开始：记录落盘，待落盘清空 —— 仍是 2。
    XCTAssertEqual(count(stored + [finished], pending: nil), 2)
    // 落盘与待落盘短暂并存也只算一次。
    XCTAssertEqual(count(stored + [finished], pending: finished), 2)
  }
}
