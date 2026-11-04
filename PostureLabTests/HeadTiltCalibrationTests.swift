import XCTest
@testable import PostureLab

/// issue #8 AC5：横滚折回 ±90°、左右歪写进个人基线、坐正 3 分钟歪头计时为 0 秒。
///
/// 三条都在纯逻辑层验：折叠是 `VisionPoseMapping` 的纯函数，基线是 `RollCalibrator`，计时是
/// `MonitoringEngine` 的体态秒数。真机上同一条链路由 `verify.py device-logs` 的 `head-tilt` 判定。
final class HeadTiltCalibrationTests: XCTestCase {
  /// 一帧坐正的样本：关节齐全（横滚因此可测），距离与俯仰稳定，`rollDeg` 是采集侧给出的角度。
  private func sample(at t: TimeInterval, rollDeg: Double, pitchDeg: Double = 0) -> PostureSample {
    let joints: [JointID: JointSample] = [
      .nose: JointSample(x: 0.5, y: 0.30, depthM: 0.40, confidence: 0.9),
      .leftEye: JointSample(x: 0.56, y: 0.28, depthM: 0.40, confidence: 0.9),
      .rightEye: JointSample(x: 0.44, y: 0.28, depthM: 0.40, confidence: 0.9),
      .neck: JointSample(x: 0.5, y: 0.42, depthM: 0.45, confidence: 0.9),
      .leftShoulder: JointSample(x: 0.28, y: 0.52, depthM: 0.5, confidence: 0.9),
      .rightShoulder: JointSample(x: 0.72, y: 0.52, depthM: 0.5, confidence: 0.9),
    ]
    return PostureSample(t: t,
                         distanceCM: 40,
                         pitchDeg: pitchDeg,
                         rollDeg: rollDeg,
                         joints: joints,
                         personPresent: true)
  }

  private func engine() -> MonitoringEngine {
    MonitoringEngine(config: .forSensitivity(.medium),
                     baselineDistanceCM: 40,
                     baselinePitchDeg: 0)
  }

  /// 镜像的前置摄像头让坐直时的眼线读到 ±180°：折回后必须是 0°，否则「坐得再直也判歪头」。
  func testAMirroredUprightEyeLineFoldsToZero() throws {
    let joints: [JointID: JointSample] = [
      .leftEye: JointSample(x: 0.60, y: 0.30, depthM: nil, confidence: 0.9),
      .rightEye: JointSample(x: 0.40, y: 0.30, depthM: nil, confidence: 0.9),
    ]
    XCTAssertEqual(try XCTUnwrap(VisionPoseMapping.eyeLineDegrees(joints)), 0, accuracy: 0.5)

    // 同一条镜像眼线歪 10°：折回后是 +10°，不是 170°。
    let tilted: [JointID: JointSample] = [
      .leftEye: JointSample(x: 0.60, y: 0.30, depthM: nil, confidence: 0.9),
      .rightEye: JointSample(x: 0.40, y: 0.30 + 0.2 * tan(10 * .pi / 180), depthM: nil, confidence: 0.9),
    ]
    XCTAssertEqual(try XCTUnwrap(VisionPoseMapping.eyeLineDegrees(tilted)), 10, accuracy: 0.5)
  }

  /// 左右两个方向都写进基线：中位数就是把孩子自己的歪头减掉的那一个数。
  func testTheCalibratedBaselineTakesEitherDirection() throws {
    for natural in [12.0, -9.0] {
      var calibrator = RollCalibrator()
      for step in 0...30 {
        calibrator.observe(natural + Double(step % 3) - 1, at: Double(step) / 10)
      }
      XCTAssertEqual(try XCTUnwrap(calibrator.baseline), natural, accuracy: 1.5)
      XCTAssertEqual(try XCTUnwrap(calibrator.relative(natural + 0.4)), 0.4, accuracy: 1.6)
    }
  }

  /// 坐正 3 分钟：横滚读数一直在相对基线 0.4° 上下，歪头一秒都不许记。
  func testAThreeMinuteUprightStretchAccruesNoTiltSeconds() throws {
    var calibrator = RollCalibrator()
    for step in 0...30 { calibrator.observe(18 + Double(step % 2), at: Double(step) / 10) }
    let relative = try XCTUnwrap(calibrator.relative(18.4))

    var engine = engine()
    var events: [MonitoringEvent] = []
    for tick in 0...1800 {
      events += engine.ingest(sample(at: Double(tick) / 10, rollDeg: relative))
    }

    XCTAssertEqual(engine.summary.postureStats["head_tilt"]?.seconds ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(engine.summary.goodSeconds, 180, accuracy: 0.05)
    let tiltReminders = events.filter {
      if case let .reminder(kind, _, _, _, _, _) = $0 { return kind == .headTilt }
      return false
    }
    XCTAssertTrue(tiltReminders.isEmpty, "坐正 3 分钟不许有一条歪头提醒")
  }

  /// 头高基线也在同一个 3 秒窗口里测：只记日志、不上屏（issue #8 AC4），但日志里的数字必须
  /// 是孩子这一次坐正的中位数，而不是写死的直立参考值。
  func testTheMedianHeadHeightJoinsTheSameCalibrationWindow() throws {
    var calibrator = RollCalibrator()
    for step in 0...30 {
      calibrator.observe(8, headHeight: 0.30 + Double(step % 2) * 0.004, at: Double(step) / 10)
    }
    XCTAssertEqual(try XCTUnwrap(calibrator.headHeightBaseline), 0.302, accuracy: 0.003)

    var short = RollCalibrator()
    short.observe(8, headHeight: 0.30, at: 0)
    short.observe(8, headHeight: 0.30, at: 3.2)
    XCTAssertTrue(short.isSettled)
    XCTAssertNil(short.headHeightBaseline, "样本不足时不写头高基线，绝不写一个假的中位数")
  }

  /// 引擎用测到的头高基线判趴桌：同一副骨架，基线不同结论就不同。
  ///
  /// 骨架里鼻点在肩线中线之上 0.22，俯仰 −45° 越过趴桌规则要求的「2×20°」深俯。基线 0.22
  /// （孩子自己坐正的中位数）时头高不下降，只有低头；基线 0.36 时头高下降 0.14 过 0.10 门槛，
  /// 趴桌成立。
  func testTheCalibratedHeadHeightMovesTheDeskLeanBaseline() throws {
    func leaningAt(headHeight baseline: Double) -> Bool {
      var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                    baselineDistanceCM: 40,
                                    baselinePitchDeg: 0,
                                    baselineHeadHeight: baseline)
      var leaning = false
      for tick in 0...100 {
        let events = engine.ingest(sample(at: Double(tick) / 10, rollDeg: 0, pitchDeg: -45))
        leaning = leaning || events.contains {
          if case let .statusChanged(to, _, _, _) = $0 { return to == .posture(.deskLean) }
          return false
        }
      }
      return leaning
    }
    XCTAssertFalse(leaningAt(headHeight: 0.22))
    XCTAssertTrue(leaningAt(headHeight: 0.36))
  }

  /// 反向保险：同一套管线在真的歪头 22° 时必须记秒并发提醒，否则上面的 0 秒只是没在测。
  func testATiltedHeadStillAccruesTiltSeconds() {
    var engine = engine()
    var events: [MonitoringEvent] = []
    for tick in 0...200 {
      events += engine.ingest(sample(at: Double(tick) / 10, rollDeg: 22))
    }
    XCTAssertEqual(engine.summary.postureStats["head_tilt"]?.seconds ?? 0, 20, accuracy: 0.05)
    XCTAssertTrue(events.contains {
      if case let .reminder(kind, level, _, _, _, _) = $0 { return kind == .headTilt && level == .gentle }
      return false
    })
  }
}
