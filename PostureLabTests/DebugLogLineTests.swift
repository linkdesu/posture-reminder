#if DEBUG
import XCTest
@testable import PostureLab

/// 两条 DEBUG 日志的键名与单位。QA 按这些键名算验收指标，所以它们和换算一起被钉住。
final class DebugLogLineTests: XCTestCase {
  private func json(_ line: String) throws -> [String: Any] {
    let data = try XCTUnwrap(line.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func perfLine(window: Double = 1,
                        frames: Int = 30,
                        gap: TimeInterval = 0.04,
                        render: (Int, TimeInterval, TimeInterval) = (30, 0.3, 0.02),
                        capture: (Int, TimeInterval, TimeInterval) = (30, 0.9, 0.05),
                        segment: (Int, TimeInterval, TimeInterval) = (30, 0.6, 0.03),
                        cloud: (Int, TimeInterval, TimeInterval) = (30, 0.3, 0.02),
                        cloudPoints: Int = 600,
                        cloudGaps: (TimeInterval, TimeInterval) = (0.033, 0.05),
                        vision: (Int, TimeInterval, TimeInterval) = (10, 0.2, 0.03),
                        assess: (Int, TimeInterval, TimeInterval) = (10, 0.05, 0.01),
                        degraded: Bool = false) -> String {
    PerfMonitor.line(window: window,
                     frames: frames,
                     gap: gap,
                     render: render,
                     capture: capture,
                     segment: segment,
                     cloud: cloud,
                     cloudFrames: cloud.0,
                     cloudPoints: cloudPoints,
                     cloudGaps: cloudGaps,
                     vision: vision,
                     assess: assess,
                     thermalState: "nominal",
                     battery: 0.82,
                     degraded: degraded)
  }

  func testPerfLineCarriesOneSecondsNumbers() throws {
    let values = try json(perfLine())

    XCTAssertEqual(values["frames"] as? Int, 30)
    XCTAssertEqual(values["fps"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["frame_gap_ms"] as? Double ?? 0, 40, accuracy: 0.01)
    // 每一步的均值是「该秒内的总耗时 / 次数」，单位毫秒。
    XCTAssertEqual(values["render_ms_avg"] as? Double ?? 0, 10, accuracy: 0.01)
    XCTAssertEqual(values["capture_ms_avg"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["segment_ms_avg"] as? Double ?? 0, 20, accuracy: 0.01)
    XCTAssertEqual(values["cloud_ms_avg"] as? Double ?? 0, 10, accuracy: 0.01)
    XCTAssertEqual(values["vision_ms_avg"] as? Double ?? 0, 20, accuracy: 0.01)
    XCTAssertEqual(values["assess_ms_avg"] as? Double ?? 0, 5, accuracy: 0.01)
    XCTAssertEqual(values["capture_ms_max"] as? Double ?? 0, 50, accuracy: 0.01)
    XCTAssertEqual(values["vision_ms_max"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["cloud_points"] as? Int, 600)
    XCTAssertEqual(values["cloud_gap_p95_ms"] as? Double ?? 0, 33, accuracy: 0.01)
    XCTAssertEqual(values["cloud_gap_max_ms"] as? Double ?? 0, 50, accuracy: 0.01)
    XCTAssertEqual(values["cloud_frames"] as? Int, 30)
    XCTAssertEqual(values["vision_calls"] as? Int, 10)
    XCTAssertEqual(values["assess_count"] as? Int, 10)
    XCTAssertEqual(values["thermal_state"] as? String, "nominal")
    XCTAssertEqual(values["battery_level"] as? Double ?? 0, 0.82, accuracy: 0.001)
    XCTAssertEqual(values["degraded"] as? Bool, false)
    // epoch 毫秒是 64 位；截成 32 位会读出负数。
    XCTAssertGreaterThan(values["t"] as? Int ?? 0, 1_600_000_000_000)
  }

  func testPerfLineKeepsItsFpsHonestWhenTheWindowDrifts() throws {
    let values = try json(perfLine(window: 1.5, frames: 45,
                                   vision: (0, 0, 0), assess: (0, 0, 0)))
    XCTAssertEqual(values["fps"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["vision_ms_avg"] as? Double, 0)
    XCTAssertEqual(values["assess_ms_avg"] as? Double, 0)
  }

  func testPerfLineMarksADegradedSecond() throws {
    let values = try json(perfLine(degraded: true))
    XCTAssertEqual(values["degraded"] as? Bool, true)
  }

  func testJointFrameLineCarriesConfidenceAndVisibilityPerJoint() throws {
    let line = JointFrameLog.line(JointFrameDebugSample(
      sessionT: 12.5,
      stale: false,
      shouldersInvalidated: false,
      confidence: ["nose": 0.93, "leftShoulder": 0.71, "rightShoulder": 0.68, "neck": 0.9],
      visible: ["nose": true, "leftShoulder": true, "rightShoulder": true, "neck": true]))
    let values = try json(line)

    XCTAssertEqual(values["session_t"] as? Double ?? 0, 12.5, accuracy: 0.001)
    XCTAssertEqual(values["stale"] as? Bool, false)
    XCTAssertEqual(values["shoulders_invalidated"] as? Bool, false)
    XCTAssertEqual(values["shoulders_available"] as? Bool, true)

    let joints = try XCTUnwrap(values["joints"] as? [String: Any])
    // 八个关节每个都有条目：可见的带置信度，不可见的写 null 且 v=false。
    XCTAssertEqual(joints.count, VisionPoseMapping.deliveredJoints.count)
    let nose = try XCTUnwrap(joints["nose"] as? [String: Any])
    XCTAssertEqual(nose["c"] as? Double ?? 0, 0.93, accuracy: 0.001)
    XCTAssertEqual(nose["v"] as? Bool, true)
    let eye = try XCTUnwrap(joints["leftEye"] as? [String: Any])
    XCTAssertNil(eye["c"] as? Double, "an invisible joint has no confidence")
    XCTAssertEqual(eye["v"] as? Bool, false)
  }

  func testJointFrameLineReportsAStalePairAndNoShoulders() throws {
    let line = JointFrameLog.line(JointFrameDebugSample(
      sessionT: 3,
      stale: true,
      shouldersInvalidated: true,
      confidence: [:],
      visible: [:]))
    let values = try json(line)

    XCTAssertEqual(values["stale"] as? Bool, true)
    XCTAssertEqual(values["shoulders_invalidated"] as? Bool, true)
    XCTAssertEqual(values["shoulders_available"] as? Bool, false)
  }
}
#endif
