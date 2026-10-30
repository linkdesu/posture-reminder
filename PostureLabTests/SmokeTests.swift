import XCTest
@testable import PostureLab

final class SmokeTests: XCTestCase {
  func testHarnessRuns() {
    XCTAssertTrue(true)
  }

  /// A stored summary outlives the schema: the tolerant decoder fills a key that was written
  /// before it existed with the zero value instead of throwing the record away.
  func testSummaryDecodesWithoutPostureStats() throws {
    let summary = makeSummary()

    let data = try JSONEncoder().encode(summary)
    var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strippedStats = fields.removeValue(forKey: "postureStats")
    XCTAssertNotNil(strippedStats, "the key should be there to strip")

    let decoded = try JSONDecoder().decode(SessionSummary.self,
                                           from: JSONSerialization.data(withJSONObject: fields))

    XCTAssertEqual(decoded.startedAt, summary.startedAt)
    XCTAssertEqual(decoded.totalSeconds, 600)
    XCTAssertEqual(decoded.goodSeconds, 300)
    XCTAssertEqual(decoded.tooCloseSeconds, 60)
    XCTAssertEqual(decoded.headDownSeconds, 30)
    XCTAssertEqual(decoded.pausedSeconds, 20)
    XCTAssertEqual(decoded.tooCloseCount, 3)
    XCTAssertEqual(decoded.tooCloseRemindCount, 4)
    XCTAssertEqual(decoded.headDownCount, 1)
    XCTAssertEqual(decoded.headDownRemindCount, 2)
    XCTAssertEqual(decoded.longestGoodStreakSeconds, 90)

    XCTAssertEqual(decoded.postureStats.count, PostureKind.allCases.count)
    for kind in PostureKind.allCases {
      XCTAssertEqual(decoded.stat(kind), PostureStat(episodes: 0, reminders: 0, seconds: 0))
    }
  }

  /// A recorded summary keeps its per-posture numbers across a save and a load.
  func testSummaryRoundTripKeepsPostureStats() throws {
    var summary = makeSummary()
    summary.postureStats[PostureKind.near.rawValue] = PostureStat(episodes: 2,
                                                                 reminders: 3,
                                                                 seconds: 24.9)

    let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(summary))

    XCTAssertEqual(decoded, summary)
    XCTAssertEqual(decoded.stat(.near), PostureStat(episodes: 2, reminders: 3, seconds: 24.9))
    XCTAssertEqual(decoded.stat(.chinRest), PostureStat(episodes: 0, reminders: 0, seconds: 0))
  }

  private func makeSummary() -> SessionSummary {
    SessionSummary(startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                   totalSeconds: 600,
                   goodSeconds: 300,
                   tooCloseSeconds: 60,
                   headDownSeconds: 30,
                   pausedSeconds: 20,
                   tooCloseCount: 3,
                   tooCloseRemindCount: 4,
                   headDownCount: 1,
                   headDownRemindCount: 2,
                   longestGoodStreakSeconds: 90)
  }
}
