import XCTest
@testable import PostureLab

/// 真机上「Vision 说人在场、但身体特征一个都没测到」的区间：不进 total/good，也不提醒。
/// 脚本 rig 永远有关节，不受这条规则影响。
final class UnmeasuredIntervalTests: XCTestCase {
  private func engine() -> MonitoringEngine {
    MonitoringEngine(config: .forSensitivity(.medium),
                     baselineDistanceCM: 40,
                     baselinePitchDeg: 0)
  }

  private func sample(at t: TimeInterval, personPresent: Bool?, joints: [JointID: JointSample]) -> PostureSample {
    PostureSample(t: t,
                  distanceCM: personPresent == false ? nil : 45,
                  pitchDeg: personPresent == false ? nil : 0,
                  joints: joints,
                  personPresent: personPresent)
  }

  func testAPresentButUnmeasurableStretchIsExcludedFromThePercentages() {
    var engine = engine()
    var events: [MonitoringEvent] = []
    // 40 ticks（4 秒）里 Vision 说人在场，但没有任何关节；距离与俯仰正常。
    for tick in 0...40 {
      events += engine.ingest(sample(at: Double(tick) / 10, personPresent: true, joints: [:]))
    }
    XCTAssertEqual(engine.summary.totalSeconds, 0, accuracy: 0.01,
                   "unmeasured time must not enter the good-ratio denominator")
    XCTAssertEqual(engine.summary.goodSeconds, 0, accuracy: 0.01)
    XCTAssertFalse(engine.isPaused, "a present person is not an absence pause")
    XCTAssertTrue(events.allSatisfy { if case .reminder = $0 { return false }; return true })
  }

  func testAMeasuredStretchStillCounts() {
    var engine = engine()
    let joints: [JointID: JointSample] = [
      .nose: JointSample(x: 0.5, y: 0.30, depthM: 0.4, confidence: 0.9),
      .neck: JointSample(x: 0.5, y: 0.42, depthM: 0.45, confidence: 0.9),
      .leftShoulder: JointSample(x: 0.28, y: 0.52, depthM: 0.5, confidence: 0.9),
      .rightShoulder: JointSample(x: 0.72, y: 0.52, depthM: 0.5, confidence: 0.9),
    ]
    for tick in 0...20 {
      _ = engine.ingest(sample(at: Double(tick) / 10, personPresent: true, joints: joints))
    }
    XCTAssertEqual(engine.summary.totalSeconds, 2.0, accuracy: 0.05)
    XCTAssertEqual(engine.summary.goodSeconds, 2.0, accuracy: 0.05)
  }
}
