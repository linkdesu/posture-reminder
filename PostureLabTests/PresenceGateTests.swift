import XCTest
@testable import PostureLab

/// 在场判定（0.6.8 (18)）：连续 3 帧、两条证据路径，只有鼻子不算有人。
///
/// 这些用例只走纯逻辑：`PresenceGate` 不碰相机、不碰锁，喂置信度就给出路径与是否在场。
final class PresenceGateTests: XCTestCase {
  /// 一帧的置信度表；缺的关节就是不传。
  private func confidence(nose: Double? = nil,
                          leftEye: Double? = nil,
                          rightEye: Double? = nil,
                          neck: Double? = nil,
                          leftShoulder: Double? = nil,
                          rightShoulder: Double? = nil) -> [JointID: Double] {
    var values: [JointID: Double] = [:]
    func put(_ joint: JointID, _ value: Double?) {
      if let value { values[joint] = value }
    }
    put(.nose, nose)
    put(.leftEye, leftEye)
    put(.rightEye, rightEye)
    put(.neck, neck)
    put(.leftShoulder, leftShoulder)
    put(.rightShoulder, rightShoulder)
    return values
  }

  /// 只喂 `frames` 次同一帧，返回每一帧的路径。
  @discardableResult
  private func feed(_ gate: inout PresenceGate,
                    frames: Int,
                    confidence values: [JointID: Double],
                    faceDetected: Bool = false) -> [PresencePath] {
    (0..<frames).map { _ in gate.observe(confidence: values, faceDetected: faceDetected) }
  }

  // MARK: - 路径一：头部 + 人脸/双眼

  func testFaceEyesPathCountsAsPresenceAfterThreeFrames() {
    var gate = PresenceGate()
    // 鼻 + 双眼都过门槛，没有人脸框：靠眼睛走通 face_eyes。
    let values = confidence(nose: 0.9, leftEye: 0.6, rightEye: 0.55)

    let paths = feed(&gate, frames: 2, confidence: values)
    XCTAssertEqual(paths, [.faceEyes, .faceEyes])
    XCTAssertFalse(gate.isPresent, "两帧还不算在场")

    XCTAssertEqual(gate.observe(confidence: values, faceDetected: false), .faceEyes)
    XCTAssertTrue(gate.isPresent, "连续 3 帧 face_eyes 才算在场")
  }

  func testADetectedFaceAloneSatisfiesTheFaceEyesPath() {
    var gate = PresenceGate()
    // 只有鼻与一张人脸框，一只眼都不过门槛：仍然走通 face_eyes。
    let values = confidence(nose: 0.9, leftEye: 0.2, rightEye: 0.1)

    let paths = feed(&gate, frames: 3, confidence: values, faceDetected: true)

    XCTAssertEqual(paths, [.faceEyes, .faceEyes, .faceEyes])
    XCTAssertTrue(gate.isPresent)
  }

  func testOneEyeIsNotEnoughWithoutAFace() {
    var gate = PresenceGate()
    // 只有一只眼过门槛、也没有人脸框：鼻子加单眼不是证据。
    let values = confidence(nose: 0.9, leftEye: 0.8)

    let paths = feed(&gate, frames: 3, confidence: values)

    XCTAssertEqual(paths, [.none, .none, .none])
    XCTAssertFalse(gate.isPresent)
    XCTAssertEqual(gate.streak, 0)
  }

  // MARK: - 路径二：头部 + 颈/肩

  func testNeckOrShoulderPathCountsAsPresenceAfterThreeFrames() {
    // 颈、左肩、右肩任意一个过门槛就够；三种各来一轮。
    for values in [confidence(nose: 0.9, neck: 0.55),
                   confidence(nose: 0.9, leftShoulder: 0.7),
                   confidence(nose: 0.9, rightShoulder: 0.51)] {
      var gate = PresenceGate()
      let paths = feed(&gate, frames: 2, confidence: values)
      XCTAssertEqual(paths, [.neckShoulder, .neckShoulder])
      XCTAssertFalse(gate.isPresent)

      XCTAssertEqual(gate.observe(confidence: values, faceDetected: false), .neckShoulder)
      XCTAssertTrue(gate.isPresent)
    }
  }

  func testFaceEyesWinsWhenBothPathsAreSatisfied() {
    var gate = PresenceGate()
    // 鼻 + 双眼 + 颈 + 双肩全过门槛：日志记 face_eyes。
    let values = confidence(nose: 0.9, leftEye: 0.7, rightEye: 0.7,
                            neck: 0.8, leftShoulder: 0.8, rightShoulder: 0.8)

    XCTAssertEqual(gate.observe(confidence: values, faceDetected: false), .faceEyes)
  }

  // MARK: - 只有鼻子不算有人

  func testNoseAloneIsNotPresence() {
    var gate = PresenceGate()
    let values = confidence(nose: 0.95)

    let paths = feed(&gate, frames: 10, confidence: values)

    XCTAssertEqual(paths, Array(repeating: .none, count: 10), "只有鼻子必须不算有人")
    XCTAssertFalse(gate.isPresent)
    XCTAssertEqual(gate.streak, 0)
  }

  func testAHeadBelowTheConfidenceThresholdIsNotPresence() {
    var gate = PresenceGate()
    // 头没过门槛：就算双眼与双肩都在，也不是在场证据（鼻是在场判定的锚点）。
    let values = confidence(nose: 0.49, leftEye: 0.9, rightEye: 0.9,
                            neck: 0.9, leftShoulder: 0.9, rightShoulder: 0.9)

    XCTAssertEqual(PresenceGate.path(confidence: values, faceDetected: true), .none)
    feed(&gate, frames: 3, confidence: values, faceDetected: true)
    XCTAssertFalse(gate.isPresent)
  }

  // MARK: - 不足 3 帧

  func testTwoEvidenceFramesAreNotPresent() {
    var gate = PresenceGate()
    feed(&gate, frames: 2, confidence: confidence(nose: 0.9, neck: 0.8))

    XCTAssertFalse(gate.isPresent)
    XCTAssertEqual(gate.streak, 2)
  }

  func testASingleMissingFrameBreaksTheStreak() {
    var gate = PresenceGate()
    let evidence = confidence(nose: 0.9, leftEye: 0.7, rightEye: 0.7)

    feed(&gate, frames: 2, confidence: evidence)
    XCTAssertEqual(gate.observe(confidence: confidence(nose: 0.9), faceDetected: false), .none)
    XCTAssertEqual(gate.streak, 0, "一帧只有鼻子就把连续计数清零")

    feed(&gate, frames: 2, confidence: evidence)
    XCTAssertFalse(gate.isPresent, "清零后再来两帧仍然不够 3 帧")
    gate.observe(confidence: evidence, faceDetected: false)
    XCTAssertTrue(gate.isPresent)
  }

  func testResetDropsTheStreak() {
    var gate = PresenceGate()
    feed(&gate, frames: 3, confidence: confidence(nose: 0.9, neck: 0.9))
    XCTAssertTrue(gate.isPresent)

    gate.reset()

    XCTAssertFalse(gate.isPresent)
    XCTAssertEqual(gate.streak, 0)
  }
}
