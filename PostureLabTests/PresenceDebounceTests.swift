import XCTest
@testable import PostureLab

/// 在场去抖：无人连续 3 秒暂停；离开一次再回来，日志恰好一条 paused、一条 resumed。
final class PresenceDebounceTests: XCTestCase {
  private func engine() -> MonitoringEngine {
    MonitoringEngine(config: .forSensitivity(.medium), baselineDistanceCM: 40, baselinePitchDeg: 0)
  }

  private func sample(at t: TimeInterval, present: Bool) -> PostureSample {
    let joints: [JointID: JointSample] = present ? [
      .nose: JointSample(x: 0.5, y: 0.30, depthM: 0.45, confidence: 0.9),
      .neck: JointSample(x: 0.5, y: 0.42, depthM: 0.5, confidence: 0.9),
      .leftShoulder: JointSample(x: 0.3, y: 0.52, depthM: 0.5, confidence: 0.9),
      .rightShoulder: JointSample(x: 0.7, y: 0.52, depthM: 0.5, confidence: 0.9),
    ] : [:]
    return PostureSample(t: t,
                         distanceCM: present ? 45 : nil,
                         pitchDeg: present ? 0 : nil,
                         joints: joints,
                         personPresent: present)
  }

  private func feed(_ engine: inout MonitoringEngine,
                    from: TimeInterval, to: TimeInterval,
                    present: Bool) -> [MonitoringEvent] {
    var events: [MonitoringEvent] = []
    var t = from
    while t <= to + 1e-9 {
      events += engine.ingest(sample(at: t, present: present))
      t += 0.1
    }
    return events
  }

  func testOneAbsenceCycleWritesExactlyOnePauseAndOneResume() {
    var engine = engine()
    var events = feed(&engine, from: 0, to: 3, present: true)
    // 离开 6 秒（越过 3 秒门槛），再回来 3 秒（越过 1 秒去抖）。
    events += feed(&engine, from: 3.1, to: 9, present: false)
    events += feed(&engine, from: 9.1, to: 12, present: true)

    let paused = events.filter { if case .paused = $0 { return true }; return false }
    let resumed = events.filter { if case .resumed = $0 { return true }; return false }
    XCTAssertEqual(paused.count, 1)
    XCTAssertEqual(resumed.count, 1)
    XCTAssertFalse(engine.isPaused)
  }

  func testABriefFlickerOfPresenceDoesNotResume() {
    var engine = engine()
    _ = feed(&engine, from: 0, to: 2, present: true)
    var events = feed(&engine, from: 2.1, to: 8, present: false)
    // 只回来 0.5 秒，还没到 1 秒去抖。
    events += feed(&engine, from: 8.1, to: 8.6, present: true)
    events += feed(&engine, from: 8.7, to: 9.5, present: false)

    XCTAssertEqual(events.filter { if case .resumed = $0 { return true }; return false }.count, 0)
    XCTAssertTrue(engine.isPaused)
  }
}
