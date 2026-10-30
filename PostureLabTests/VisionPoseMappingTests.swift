import XCTest
@testable import PostureLab

/// Vision 关节映射与深度配对的纯函数测试：置信度门槛、只出上半身、肩不能在头上、坐标空间、配对窗口。
final class VisionPoseMappingTests: XCTestCase {
  // MARK: - 只出上半身

  func testOnlyHeadNeckAndShouldersSurviveTheMapping() {
    let points = JointID.allCases.map { joint in
      VisionPosePoint(joint: joint, x: 0.5, y: 0.5, confidence: 0.9)
    }
    let mapped = VisionPoseMapping.joints(from: points)

    XCTAssertEqual(Set(mapped.joints.keys), Set(VisionPoseMapping.deliveredJoints))
    for joint in [JointID.root, .leftHip, .rightHip, .leftElbow, .rightElbow, .leftWrist, .rightWrist] {
      XCTAssertNil(mapped.joints[joint], "\(joint.rawValue) must never be delivered")
    }
  }

  // MARK: - 置信度

  func testAConfidenceBelowTheThresholdIsTreatedAsUnmeasured() {
    let mapped = VisionPoseMapping.joints(from: [
      VisionPosePoint(joint: .nose, x: 0.5, y: 0.2, confidence: 0.49),
      VisionPosePoint(joint: .neck, x: 0.5, y: 0.4, confidence: 0.5),
    ])

    XCTAssertNil(mapped.joints[.nose], "0.49 is below the 0.5 threshold")
    XCTAssertNotNil(mapped.joints[.neck], "0.5 is exactly at the threshold and counts")
    XCTAssertEqual(VisionPoseMapping.minimumConfidence, 0.5)
  }

  func testTheMoreConfidentReadingWinsADuplicateJoint() {
    let mapped = VisionPoseMapping.joints(from: [
      VisionPosePoint(joint: .nose, x: 0.1, y: 0.2, confidence: 0.6),
      VisionPosePoint(joint: .nose, x: 0.7, y: 0.8, confidence: 0.95),
    ])

    XCTAssertEqual(mapped.joints[.nose]?.x ?? 0, 0.7, accuracy: 1e-9)
    XCTAssertEqual(mapped.joints[.nose]?.confidence ?? 0, 0.95, accuracy: 1e-9)
  }

  // MARK: - 肩不能在头上

  func testShouldersAboveTheNoseInvalidateBothShoulders() {
    let mapped = VisionPoseMapping.joints(from: [
      VisionPosePoint(joint: .nose, x: 0.5, y: 0.30, confidence: 0.9),
      VisionPosePoint(joint: .leftShoulder, x: 0.3, y: 0.20, confidence: 0.9),
      VisionPosePoint(joint: .rightShoulder, x: 0.7, y: 0.45, confidence: 0.9),
      VisionPosePoint(joint: .neck, x: 0.5, y: 0.40, confidence: 0.9),
    ])

    XCTAssertTrue(mapped.shouldersInvalidated)
    XCTAssertNil(mapped.joints[.leftShoulder], "a shoulder above the nose is a head")
    XCTAssertNil(mapped.joints[.rightShoulder], "the pair is dropped together")
    XCTAssertNotNil(mapped.joints[.neck], "the neck is not part of the rule")
  }

  func testShouldersBelowTheNoseStay() {
    let mapped = VisionPoseMapping.joints(from: [
      VisionPosePoint(joint: .nose, x: 0.5, y: 0.30, confidence: 0.9),
      VisionPosePoint(joint: .leftShoulder, x: 0.3, y: 0.45, confidence: 0.9),
      VisionPosePoint(joint: .rightShoulder, x: 0.7, y: 0.47, confidence: 0.9),
    ])

    XCTAssertFalse(mapped.shouldersInvalidated)
    XCTAssertNotNil(mapped.joints[.leftShoulder])
    XCTAssertNotNil(mapped.joints[.rightShoulder])
  }

  // MARK: - 坐标空间

  func testAPortraitBufferFlipsTheModelYAxis() {
    // Vision 的原点在左下、y 向上；应用的关节空间原点在左上、y 向下。
    let point = VisionPoseMapping.imagePoint(x: 0.25, y: 0.75, portrait: true)
    XCTAssertEqual(point.x, 0.25, accuracy: 1e-9)
    XCTAssertEqual(point.y, 0.25, accuracy: 1e-9)
  }

  func testALandscapeBufferSwapsTheAxes() {
    let point = VisionPoseMapping.imagePoint(x: 0.25, y: 0.75, portrait: false)
    XCTAssertEqual(point.x, 0.75, accuracy: 1e-9)
    XCTAssertEqual(point.y, 0.25, accuracy: 1e-9)
  }

  // MARK: - 关节距离

  func testJointDepthComesFromMaskCellsOnly() throws {
    let width = 40
    let height = 40
    var metres = [Float](repeating: 2.0, count: width * height)
    for y in 10..<20 {
      for x in 10..<20 { metres[y * width + x] = 0.5 }
    }
    let depth = try XCTUnwrap(DepthImage(width: width, height: height, metres: metres))
    let mask = try XCTUnwrap(DepthSegmentation.segment(depth))

    let onBody = VisionPoseMapping.attachDepth(
      [.nose: JointSample(x: 0.375, y: 0.375, depthM: nil, confidence: 0.9)],
      depth: depth, mask: mask)
    XCTAssertEqual(try XCTUnwrap(onBody[.nose]?.depthM), 0.5, accuracy: 0.05)

    // 关节落在遮罩外：背景的 2 米墙不能变成它的距离。
    let offBody = VisionPoseMapping.attachDepth(
      [.nose: JointSample(x: 0.95, y: 0.95, depthM: nil, confidence: 0.9)],
      depth: depth, mask: mask)
    XCTAssertNil(offBody[.nose]?.depthM)
  }

  // MARK: - 横滚的三个来源

  func testRollPrefersTheEyeLine() throws {
    let joints: [JointID: JointSample] = [
      .leftEye: JointSample(x: 0.4, y: 0.30, depthM: nil, confidence: 0.9),
      .rightEye: JointSample(x: 0.6, y: 0.30, depthM: nil, confidence: 0.9),
      .leftEar: JointSample(x: 0.35, y: 0.32, depthM: nil, confidence: 0.9),
      .rightEar: JointSample(x: 0.65, y: 0.50, depthM: nil, confidence: 0.9),
    ]
    let roll = try XCTUnwrap(VisionPoseMapping.rollDegrees(joints, fallback: 42))
    XCTAssertEqual(roll, 0, accuracy: 0.0001, "a level eye line wins over a tilted ear line")
  }

  func testRollFallsBackToTheEarLineWhenTheEyesAreMissing() throws {
    let joints: [JointID: JointSample] = [
      .leftEar: JointSample(x: 0.35, y: 0.30, depthM: nil, confidence: 0.9),
      .rightEar: JointSample(x: 0.65, y: 0.30, depthM: nil, confidence: 0.9),
    ]
    let roll = try XCTUnwrap(VisionPoseMapping.rollDegrees(joints, fallback: 42))
    XCTAssertEqual(roll, 0, accuracy: 0.0001)
  }

  func testRollFallsBackToTheDepthPlaneWhenNoFaceLineIsMeasured() throws {
    // 关节过期或一个都没测到：只剩深度平面。
    XCTAssertEqual(try XCTUnwrap(VisionPoseMapping.rollDegrees([:], fallback: -7)), -7, accuracy: 0.0001)
    XCTAssertNil(VisionPoseMapping.rollDegrees([:], fallback: nil))
  }

  func testADegenerateEyeLineStillFallsBack() throws {
    // 两眼落在同一点（模型抖动）时不能用它算角度。
    let joints: [JointID: JointSample] = [
      .leftEye: JointSample(x: 0.5, y: 0.3, depthM: nil, confidence: 0.9),
      .rightEye: JointSample(x: 0.5, y: 0.3, depthM: nil, confidence: 0.9),
      .leftEar: JointSample(x: 0.35, y: 0.30, depthM: nil, confidence: 0.9),
      .rightEar: JointSample(x: 0.65, y: 0.30, depthM: nil, confidence: 0.9),
    ]
    XCTAssertEqual(try XCTUnwrap(VisionPoseMapping.rollDegrees(joints, fallback: 42)), 0, accuracy: 0.0001)
  }

  // MARK: - 嘴

  /// 嘴是面部特征，没有逐点置信度：整条轮廓按同帧人脸框的置信度过 0.5 门槛才画。
  func testMouthIsDeliveredOnlyWhenTheFacePassesTheThreshold() {
    let lips = [CGPointLike(x: 0.45, y: 0.35), CGPointLike(x: 0.55, y: 0.35),
                CGPointLike(x: 0.50, y: 0.37)]
    XCTAssertEqual(VisionPoseMapping.mouth(points: lips, faceConfidence: 0.5), lips,
                   "0.5 is exactly at the threshold and counts")
    XCTAssertTrue(VisionPoseMapping.mouth(points: lips, faceConfidence: 0.49).isEmpty,
                  "a face below 0.5 must not add a mouth")
    XCTAssertTrue(VisionPoseMapping.mouth(points: lips, faceConfidence: nil).isEmpty,
                  "no face box, no mouth")
    XCTAssertTrue(VisionPoseMapping.mouth(points: [], faceConfidence: 0.9).isEmpty)
  }

  // MARK: - 配对窗口

  func testTheNearestDepthFrameWins() {
    let ticks: [TimeInterval] = [0.00, 0.033, 0.066, 0.099]
    XCTAssertEqual(VisionDepthPairing.nearestIndex(to: 0.070, ticks: ticks), 2)
    XCTAssertEqual(VisionDepthPairing.nearestIndex(to: 0.010, ticks: ticks), 0)
    XCTAssertNil(VisionDepthPairing.nearestIndex(to: 0.5, ticks: []))
  }

  func testGapOverOneHundredFiftyMillisecondsIsStale() {
    XCTAssertEqual(VisionDepthPairing.maximumGap, 0.15)
    XCTAssertFalse(VisionDepthPairing.isStale(visionT: 1.0, sampleT: 1.15))
    XCTAssertTrue(VisionDepthPairing.isStale(visionT: 1.0, sampleT: 1.151))
    XCTAssertTrue(VisionDepthPairing.isStale(visionT: 1.3, sampleT: 1.0))
  }
}
