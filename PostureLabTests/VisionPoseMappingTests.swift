import XCTest
@testable import PostureLab

/// The Vision mapping on constructed observations: no camera, no photo, no model run.
///
/// Every fixture is a hand-placed joint set over a synthetic depth frame, so each assertion has a
/// known answer: where the joint lands, which joint the model failed to score, what distance the
/// depth map gives that pixel, and whether the classifier can now compute 手到脸.
final class VisionPoseMappingTests: XCTestCase {
  private let width = 160
  private let height = 120
  private let background: Float = 2.0

  // MARK: - Fixtures

  /// The same seated body the depth tests use: head disc centred at (80, 30), torso 39...100, 0.5 m
  /// from the camera, with a wall 2 m behind it.
  private func bodyImage(headSlope: Float = 0) -> DepthImage {
    var metres = [Float](repeating: background, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let inHead = hypot(Double(x - 80), Double(y - 30)) <= 13
        let inTorso = y >= 39 && y <= 100 && abs(x - 80) <= 22
        guard inHead || inTorso else { continue }
        metres[y * width + x] = inHead ? 0.5 + headSlope * Float(y - 30) : 0.5
      }
    }
    return DepthImage(width: width, height: height, metres: metres)!
  }

  private func flatWall() -> DepthImage {
    DepthImage(width: width, height: height,
               metres: [Float](repeating: 1.4, count: width * height))!
  }

  /// A seated child's fifteen joints in the app's joint space (y down), all on the body disc/torso so
  /// each one has a depth reading.
  private func seatedPose() -> [VisionPosePoint] {
    [
      point(.nose, 0.50, 0.25),
      point(.leftEye, 0.46, 0.22), point(.rightEye, 0.54, 0.22),
      point(.leftEar, 0.42, 0.24), point(.rightEar, 0.58, 0.24),
      point(.neck, 0.50, 0.36),
      point(.root, 0.50, 0.62),
      point(.leftShoulder, 0.35, 0.40), point(.rightShoulder, 0.65, 0.40),
      point(.leftElbow, 0.32, 0.55), point(.rightElbow, 0.68, 0.55),
      point(.leftWrist, 0.34, 0.70), point(.rightWrist, 0.66, 0.70),
      point(.leftHip, 0.40, 0.75), point(.rightHip, 0.60, 0.75),
    ]
  }

  private func point(_ joint: JointID, _ x: Double, _ y: Double, confidence: Double = 0.9) -> VisionPosePoint {
    VisionPosePoint(joint: joint, x: x, y: y, confidence: confidence)
  }

  private func sample(_ estimate: JointEstimate) -> PostureSample {
    PostureSample(t: 0,
                  distanceCM: estimate.distanceCM,
                  pitchDeg: estimate.pitchDeg,
                  rollDeg: estimate.rollDeg,
                  joints: estimate.joints,
                  depthAvailable: estimate.mask != nil,
                  cloud: estimate.cloud,
                  unavailableJoints: estimate.unavailable)
  }

  // MARK: - Joints

  func testEveryModelledJointLandsWhereTheModelPutIt() throws {
    let estimate = VisionPoseMapping.estimate(points: seatedPose(), depth: bodyImage())

    XCTAssertTrue(estimate.unavailable.isEmpty, "all fifteen joints were scored")
    XCTAssertEqual(estimate.joints.count, JointID.allCases.count)
    let nose = try XCTUnwrap(estimate.joints[.nose])
    XCTAssertEqual(nose.x, 0.50, accuracy: 0.001)
    XCTAssertEqual(nose.y, 0.25, accuracy: 0.001)
    // The distance comes from the depth map under the joint, not from the model.
    XCTAssertEqual(try XCTUnwrap(nose.depthM), 0.5, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(estimate.distanceCM), 50, accuracy: 2)
    // Eyes, ears, elbows and wrists are exactly what a depth-only source cannot report.
    for joint in [JointID.leftEye, .rightEye, .leftEar, .rightEar,
                  .leftElbow, .rightElbow, .leftWrist, .rightWrist] {
      XCTAssertNotNil(estimate.joints[joint], "\(joint.rawValue) must come from the model")
    }
  }

  func testAWeaklyScoredJointIsReportedUnavailable() {
    var points = seatedPose()
    points.removeAll { $0.joint == .leftWrist }
    points.append(point(.leftWrist, 0.34, 0.70, confidence: 0.12))
    let estimate = VisionPoseMapping.estimate(points: points, depth: bodyImage())

    XCTAssertNil(estimate.joints[.leftWrist])
    XCTAssertTrue(estimate.unavailable.contains(.leftWrist))
    XCTAssertEqual(estimate.joints.count, JointID.allCases.count - 1)
    // The other wrist is untouched: one bad limb does not erase the limb pair.
    XCTAssertNotNil(estimate.joints[.rightWrist])
  }

  func testTwoReadingsForOneJointKeepTheMoreConfidentOne() throws {
    let points = [
      point(.nose, 0.10, 0.10, confidence: 0.4),
      point(.nose, 0.50, 0.25, confidence: 0.95),
    ]
    let estimate = VisionPoseMapping.estimate(points: points, depth: bodyImage())
    XCTAssertEqual(try XCTUnwrap(estimate.joints[.nose]).x, 0.50, accuracy: 0.001)
  }

  func testNoObservationLeavesEveryJointUnavailableButKeepsTheDepthSilhouette() {
    let estimate = VisionPoseMapping.estimate(points: [], depth: bodyImage())

    XCTAssertTrue(estimate.joints.isEmpty)
    XCTAssertEqual(estimate.unavailable, Set(JointID.allCases))
    XCTAssertNil(estimate.distanceCM)
    XCTAssertFalse(estimate.cloud.isEmpty, "the cloud is depth geometry and survives a lost pose")
    XCTAssertNotNil(estimate.mask)
  }

  func testNobodyInFrameHasNoCloud() {
    let estimate = VisionPoseMapping.estimate(points: seatedPose(), depth: flatWall())
    XCTAssertNil(estimate.mask)
    XCTAssertTrue(estimate.cloud.isEmpty)
    // The joints are still 2D observations; only their depth is missing.
    XCTAssertNotNil(estimate.joints[.nose])
    XCTAssertNil(estimate.joints[.nose]?.depthM)
    XCTAssertNil(estimate.distanceCM)
  }

  // MARK: - Orientation

  func testRollFollowsTheEyeLine() throws {
    let estimate = VisionPoseMapping.estimate(points: seatedPose(), depth: bodyImage())
    XCTAssertEqual(try XCTUnwrap(estimate.rollDeg), 0, accuracy: 0.5)

    var tilted = seatedPose()
    tilted.removeAll { $0.joint == .leftEye || $0.joint == .rightEye }
    tilted.append(point(.leftEye, 0.46, 0.20))
    tilted.append(point(.rightEye, 0.54, 0.24))
    let rolled = VisionPoseMapping.estimate(points: tilted, depth: bodyImage())
    // atan2(0.04, 0.08) ≈ 26.6°: the right eye sits lower, so the head rolls that way.
    XCTAssertEqual(try XCTUnwrap(rolled.rollDeg), 26.6, accuracy: 1)
  }

  func testPitchComesFromTheDepthPlaneAroundTheNose() throws {
    let upright = VisionPoseMapping.estimate(points: seatedPose(), depth: bodyImage())
    XCTAssertEqual(try XCTUnwrap(upright.pitchDeg), 0, accuracy: 1.5)

    let down = VisionPoseMapping.estimate(points: seatedPose(),
                                          depth: bodyImage(headSlope: -0.3 / 30))
    XCTAssertLessThan(try XCTUnwrap(down.pitchDeg), -5)
    // The eye line is unaffected by the depth slope, so roll stays a 2D reading.
    XCTAssertEqual(try XCTUnwrap(down.rollDeg), 0, accuracy: 0.5)
  }

  // MARK: - The metric the depth build could not compute

  func testHandToFaceIsMeasurableAndBreachesWhenAWristSitsAtTheNose() {
    var points = seatedPose()
    points.removeAll { $0.joint == .leftWrist || $0.joint == .rightWrist }
    points.append(point(.leftWrist, 0.51, 0.27))
    points.append(point(.rightWrist, 0.66, 0.70))

    let estimate = VisionPoseMapping.estimate(points: points, depth: bodyImage())
    let assessment = PostureClassifier.assess(sample(estimate),
                                              baseline: PostureBaseline.from(
                                                calibration: CalibrationResult(distanceCM: 50,
                                                                               pitchDeg: 0)),
                                              thresholds: .forSensitivity(.medium))
    let reading = assessment.readings.first { $0.feature == .handToFace }
    // hypot(0.01, 0.02) = 0.022, under the 0.10 threshold.
    XCTAssertEqual(reading?.value ?? .nan, 0.022, accuracy: 0.003)
    XCTAssertEqual(reading?.isOverThreshold, true)
    XCTAssertEqual(assessment.breached[.chinRest], true)
  }

  func testHandsDownLeavesHandToFaceWellUnderTheThreshold() {
    let estimate = VisionPoseMapping.estimate(points: seatedPose(), depth: bodyImage())
    let assessment = PostureClassifier.assess(sample(estimate),
                                              baseline: PostureBaseline.from(
                                                calibration: CalibrationResult(distanceCM: 50,
                                                                               pitchDeg: 0)),
                                              thresholds: .forSensitivity(.medium))
    let reading = assessment.readings.first { $0.feature == .handToFace }
    XCTAssertEqual(reading?.isOverThreshold, false)
    XCTAssertEqual(assessment.breached[.chinRest], false)
  }

  // MARK: - Orientation of the frame

  func testPortraitPointsFlipVerticallyAndLandscapePointsRotate() {
    let portrait = VisionPoseMapping.imagePoint(x: 0.2, y: 0.8, portrait: true)
    XCTAssertEqual(portrait.x, 0.2, accuracy: 0.0001)
    XCTAssertEqual(portrait.y, 0.2, accuracy: 0.0001)

    // A landscape buffer Vision was told `.right` about: its normalized x is the portrait vertical.
    let landscape = VisionPoseMapping.imagePoint(x: 0.2, y: 0.8, portrait: false)
    XCTAssertEqual(landscape.x, 0.8, accuracy: 0.0001)
    XCTAssertEqual(landscape.y, 0.2, accuracy: 0.0001)
  }

  /// The depth source ignores the colour frame the seam now carries: same estimate with and without.
  func testDepthSourceIgnoresTheColourFrame() {
    let image = bodyImage()
    let bare = DepthJointSource().estimate(from: image)
    let withColour = DepthJointSource().estimate(from: image, colour: nil)
    XCTAssertEqual(bare, withColour)
  }
}
