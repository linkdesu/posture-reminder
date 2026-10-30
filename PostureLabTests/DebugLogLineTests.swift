#if DEBUG
import XCTest
@testable import PostureLab

/// 两条 DEBUG 日志的键名与单位。QA 按这些键名算验收指标，所以它们和换算一起被钉住。
final class DebugLogLineTests: XCTestCase {
  private func json(_ line: String) throws -> [String: Any] {
    let data = try XCTUnwrap(line.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testPerfLineCarriesOneSecondsNumbers() throws {
    let line = PerfMonitor.line(window: 1,
                                frames: 30,
                                gap: 0.04,
                                jointTotal: 0.06,
                                jointMax: 0.09,
                                jointCalls: 3,
                                assessments: 10)
    let values = try json(line)

    XCTAssertEqual(values["frames"] as? Int, 30)
    XCTAssertEqual(values["fps"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["frame_gap_ms"] as? Double ?? 0, 40, accuracy: 0.01)
    XCTAssertEqual(values["joint_ms_avg"] as? Double ?? 0, 20, accuracy: 0.01)
    XCTAssertEqual(values["joint_ms_max"] as? Double ?? 0, 90, accuracy: 0.01)
    XCTAssertEqual(values["joint_calls"] as? Int, 3)
    XCTAssertEqual(values["assess_count"] as? Int, 10)
    XCTAssertEqual(values["window_s"] as? Double ?? 0, 1, accuracy: 0.001)
    // epoch 毫秒是 64 位；截成 32 位会读出负数。
    XCTAssertGreaterThan(values["t"] as? Int ?? 0, 1_600_000_000_000)
  }

  func testPerfLineKeepsItsFpsHonestWhenTheWindowDrifts() throws {
    let values = try json(PerfMonitor.line(window: 1.5,
                                           frames: 45,
                                           gap: 0.05,
                                           jointTotal: 0,
                                           jointMax: 0,
                                           jointCalls: 0,
                                           assessments: 0))
    XCTAssertEqual(values["fps"] as? Double ?? 0, 30, accuracy: 0.01)
    XCTAssertEqual(values["joint_ms_avg"] as? Double, 0)
  }

  func testJointLineNamesTheShouldersAndWritesNullForAMissingOne() throws {
    let line = JointDebugLog.line(JointDebugSample(
      neck: JointSample(x: 0.5, y: 0.3, depthM: 0.45, confidence: 1),
      leftShoulder: JointSample(x: 0.3, y: 0.4, depthM: 0.5, confidence: 1),
      rightShoulder: nil,
      shoulderSpanCM: nil,
      shouldersAvailable: false,
      headWidth: 0.2,
      headTopY: 0.1,
      headBottomY: 0.3,
      shoulderRowY: 0.4))
    let values = try json(line)

    XCTAssertEqual(values["neck_x"] as? Double ?? 0, 0.5, accuracy: 1e-6)
    XCTAssertEqual(values["neck_z_m"] as? Double ?? 0, 0.45, accuracy: 1e-6)
    XCTAssertEqual(values["left_shoulder_x"] as? Double ?? 0, 0.3, accuracy: 1e-6)
    XCTAssertEqual(values["left_shoulder_z_m"] as? Double ?? 0, 0.5, accuracy: 1e-6)
    XCTAssertNil(values["right_shoulder_x"] as? Double, "a missing shoulder must be null, not zero")
    XCTAssertNil(values["shoulder_span_cm"] as? Double)
    XCTAssertEqual(values["shoulders_available"] as? Bool, false)
    XCTAssertEqual(values["head_width"] as? Double ?? 0, 0.2, accuracy: 1e-6)
    XCTAssertEqual(values["shoulder_row_y"] as? Double ?? 0, 0.4, accuracy: 1e-6)
  }
}
#endif
