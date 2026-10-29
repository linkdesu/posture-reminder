import XCTest
@testable import PostureLab

/// The depth pipeline end to end on synthetic frames: segmentation, the joints a depth-only source
/// can honestly report, the joints it must leave unavailable, and the cloud sampled from the mask.
///
/// The fixtures are built by hand rather than recorded from a device so every assertion has a known
/// geometry: a head disc, a torso trapezoid and a flat wall behind them, in metres.
final class DepthPipelineTests: XCTestCase {
  private let width = 160
  private let height = 120
  private let background: Float = 2.0

  // MARK: - Fixtures

  /// A seated upper body: head disc centred at (80, 30) with radius 13, torso from y 40 to 100 with
  /// shoulders 60 px wide (about 22 cm at 50 cm through the assumed 60° depth field), everything
  /// `bodyDepth` metres from the camera.
  private func bodyImage(bodyDepth: Float = 0.5,
                         headDepth: Float? = nil,
                         headSlope: Float = 0,
                         headRadius: Double = 13,
                         torsoHalfWidth: Double = 30,
                         torsoTop: Int = 39) -> DepthImage {
    var metres = [Float](repeating: background, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let inHead = hypot(Double(x - 80), Double(y - 30)) <= headRadius
        let inTorso = y >= torsoTop && y <= 100 && abs(Double(x - 80)) <= torsoHalfWidth
        guard inHead || inTorso else { continue }
        if inHead {
          // `headSlope` is metres of depth change per image row, so a positive slope means the
          // bottom of the head is farther away: a head tilted up.
          metres[y * width + x] = (headDepth ?? bodyDepth) + headSlope * Float(y - 30)
        } else {
          metres[y * width + x] = bodyDepth
        }
      }
    }
    return DepthImage(width: width, height: height, metres: metres)!
  }

  /// A close child whose mask is cut off at the chest: a wide head with ears, and a neck that never
  /// opens into a shoulder line because the shoulders are below the frame. The frame that made
  /// v0.6.1 call the ears "shoulders".
  private func headWithEarsImage() -> DepthImage {
    var metres = [Float](repeating: background, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let inHead = hypot(Double(x - 80), Double(y - 35)) <= 30
        let inEar = (y >= 30 && y <= 44) && (abs(x - 44) <= 6 || abs(x - 116) <= 6)
        let inNeck = y >= 65 && abs(x - 80) <= 12
        guard inHead || inEar || inNeck else { continue }
        metres[y * width + x] = 0.32
      }
    }
    return DepthImage(width: width, height: height, metres: metres)!
  }

  private func flatWall() -> DepthImage {
    DepthImage(width: width, height: height,
               metres: [Float](repeating: 1.4, count: width * height))!
  }

  // MARK: - Segmentation

  func testSegmentationKeepsTheBodyAndDropsTheWall() throws {
    let mask = try XCTUnwrap(DepthSegmentation.segment(bodyImage()))

    XCTAssertGreaterThan(mask.count, 400)
    XCTAssertLessThan(mask.maxY, height)
    XCTAssertGreaterThan(mask.minY, 0)
    // The wall is 1.5 m behind the body and never enters the mask.
    XCTAssertFalse(mask.contains(x: 2, y: 2))
    XCTAssertTrue(mask.contains(x: 80, y: 60))
  }

  func testSegmentationDropsAnIsolatedNearArtifact() throws {
    // A 3x3 speck at 25 cm in front of everything: nearer than the body, but a separate component.
    var image = bodyImage()
    var metres = image.metres
    for y in 2..<5 {
      for x in 2..<5 { metres[y * width + x] = 0.25 }
    }
    image = DepthImage(width: width, height: height, metres: metres)!

    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    XCTAssertTrue(mask.contains(x: 80, y: 60), "the body must survive a near artifact")
    XCTAssertFalse(mask.contains(x: 3, y: 3), "the 3x3 speck is not a body")
  }

  func testSegmentationFindsNobodyInAFlatWall() {
    XCTAssertNil(DepthSegmentation.segment(flatWall()))
  }

  func testSegmentationFindsNobodyInAnEmptyFrame() {
    let empty = DepthImage(width: width, height: height,
                           metres: [Float](repeating: 0, count: width * height))!
    XCTAssertNil(DepthSegmentation.segment(empty))
  }

  // MARK: - Joints

  func testDepthJointsReportTheHeadNeckShouldersTorsoAndHips() throws {
    let estimate = DepthJointSource().estimate(from: bodyImage())

    XCTAssertEqual(estimate.joints[.nose]?.depthM ?? 0, 0.5, accuracy: 0.05)
    for joint in [JointID.neck, .leftShoulder, .rightShoulder, .root, .leftHip, .rightHip] {
      XCTAssertNotNil(estimate.joints[joint], "\(joint.rawValue) should come from the mask")
    }
    XCTAssertEqual(estimate.distanceCM ?? 0, 50, accuracy: 6)
  }

  // MARK: - Shoulders

  func testShouldersSitBelowTheNeckInANormalSittingPose() throws {
    let estimate = DepthJointSource().estimate(from: bodyImage())
    let neck = try XCTUnwrap(estimate.joints[.neck])
    let left = try XCTUnwrap(estimate.joints[.leftShoulder])
    let right = try XCTUnwrap(estimate.joints[.rightShoulder])

    XCTAssertGreaterThan(left.y, neck.y, "a shoulder above the neck is a head")
    XCTAssertGreaterThan(right.y, neck.y, "a shoulder above the neck is a head")
    // 两肩的三维距离落在 20–45 cm：这条约束是肩点被判为可用的前提。
    let span = try XCTUnwrap(DepthCamera().distance(left, right))
    XCTAssertGreaterThanOrEqual(span, 0.20)
    XCTAssertLessThanOrEqual(span, 0.45)
    XCTAssertFalse(estimate.unavailable.contains(.leftShoulder))
    XCTAssertFalse(estimate.unavailable.contains(.rightShoulder))
  }

  func testTheEarsOfACutOffNearMaskAreNotShoulders() {
    let estimate = DepthJointSource().estimate(from: headWithEarsImage())

    // 头部两侧的耳朵与颈部都在轮廓里，但没有任何一行宽到能当肩线：双肩必须记为不可用。
    XCTAssertNil(estimate.joints[.leftShoulder], "an ear is not a shoulder")
    XCTAssertNil(estimate.joints[.rightShoulder], "an ear is not a shoulder")
    XCTAssertTrue(estimate.unavailable.contains(.leftShoulder))
    XCTAssertTrue(estimate.unavailable.contains(.rightShoulder))
  }

  func testShouldersAreUnavailableWhenTheSpanIsOutOfRange() throws {
    // 肩线比头宽合理，但同样的宽度在 0.8 m 处换算是 58 cm：远超两肩 20–45 cm 的区间。
    let estimate = DepthJointSource().estimate(from: bodyImage(bodyDepth: 0.8,
                                                               headRadius: 20,
                                                               torsoHalfWidth: 50,
                                                               torsoTop: 40))
    XCTAssertNil(estimate.joints[.leftShoulder])
    XCTAssertNil(estimate.joints[.rightShoulder])
    XCTAssertTrue(estimate.unavailable.contains(.leftShoulder))
    // 颈部本身仍然可用：不可用的只是没有通过约束的肩。
    XCTAssertNotNil(estimate.joints[.neck])
  }

  func testShouldersAreUnavailableWhenTheHeadIsWiderThanTheShoulderLine() {
    // 头（含耳朵）60 px、肩线只有 40 px：肩宽 / 头宽 落到合理区间之外。
    let estimate = DepthJointSource().estimate(from: bodyImage(headRadius: 30, torsoHalfWidth: 20))
    XCTAssertNil(estimate.joints[.leftShoulder])
    XCTAssertNil(estimate.joints[.rightShoulder])
  }

  func testDepthJointsNeverInventEyesEarsElbowsOrWrists() {
    let estimate = DepthJointSource().estimate(from: bodyImage())

    let mustBeUnavailable: Set<JointID> = [
      .leftEye, .rightEye, .leftEar, .rightEar, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
    ]
    XCTAssertTrue(mustBeUnavailable.isSubset(of: estimate.unavailable))
    for joint in mustBeUnavailable {
      XCTAssertNil(estimate.joints[joint], "\(joint.rawValue) must not be fabricated")
    }
    XCTAssertEqual(estimate.unavailable.count + estimate.joints.count, JointID.allCases.count)
  }

  func testNobodyInFrameLeavesEveryJointUnavailable() {
    let estimate = DepthJointSource().estimate(from: flatWall())
    XCTAssertTrue(estimate.joints.isEmpty)
    XCTAssertTrue(estimate.cloud.isEmpty)
    XCTAssertNil(estimate.distanceCM)
    XCTAssertEqual(estimate.unavailable, Set(JointID.allCases))
  }

  func testHeadOrientationFollowsTheDepthSlope() throws {
    let upright = DepthJointSource().estimate(from: bodyImage())
    XCTAssertEqual(upright.pitchDeg ?? .nan, 0, accuracy: 1.5)

    // The bottom of the head 0.3 m farther than its top: a head tipped back, positive pitch here.
    let up = DepthJointSource().estimate(from: bodyImage(headSlope: 0.3 / 30))
    let pitch = try XCTUnwrap(up.pitchDeg)
    XCTAssertGreaterThan(pitch, 5)

    // The opposite slope is a nod.
    let down = DepthJointSource().estimate(from: bodyImage(headSlope: -0.3 / 30))
    XCTAssertLessThan(try XCTUnwrap(down.pitchDeg), -5)
  }

  // MARK: - Cloud

  func testCloudComesFromMaskPixelsAndKeepsTheirDepth() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let cloud = DepthCloud.points(mask: mask, image: image)

    XCTAssertFalse(cloud.isEmpty)
    XCTAssertLessThanOrEqual(cloud.count, 1200)
    for point in cloud {
      XCTAssertEqual(point.z, 0.5, accuracy: 0.001)
      XCTAssertTrue((0...1).contains(point.x))
      XCTAssertTrue((0...1).contains(point.y))
    }
  }

  func testCloudIsDeterministic() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    XCTAssertEqual(DepthCloud.points(mask: mask, image: image),
                   DepthCloud.points(mask: mask, image: image))
  }

  func testDownsamplingKeepsTheSilhouetteBoundary() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let cloud = DepthCloud.points(mask: mask, image: image, maxPoints: 120)

    XCTAssertLessThanOrEqual(cloud.count, 120)
    XCTAssertGreaterThan(cloud.count, 40, "a downsampled body is still a body, not a scatter")
    // 轮廓的四个极值都要有点：少了任何一个，人形就缺一块。
    XCTAssertTrue(cloud.contains { $0.y < 0.35 }, "the top of the head is missing")
    XCTAssertTrue(cloud.contains { $0.x < 0.45 }, "the left edge is missing")
    XCTAssertTrue(cloud.contains { $0.x > 0.55 }, "the right edge is missing")
    XCTAssertTrue(cloud.contains { $0.y > 0.75 }, "the bottom of the torso is missing")
  }

  func testDownsamplingPrefersBoundaryCells() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let maxPoints = 60
    // 与 DepthCloud 同一条格距公式：预算够宽时轮廓格点先入场，内部格点只能拿剩下的。
    let step = max(1, Int((Double(mask.count) / Double(maxPoints)).squareRoot().rounded(.up)))
    let boundary = latticeCells(mask: mask, step: step).filter { isBoundary(mask, x: $0.0, y: $0.1) }
    XCTAssertGreaterThanOrEqual(boundary.count, 4, "the fixture's silhouette has a boundary")

    let cloud = DepthCloud.points(mask: mask, image: image, maxPoints: maxPoints)
    for cell in boundary {
      let position = mask.normalized(x: cell.0, y: cell.1)
      XCTAssertTrue(cloud.contains { $0.x == position.x && $0.y == position.y },
                    "boundary cell \(cell) lost its budget to the interior")
    }
  }

  /// 与 `DepthCloud` 相同的锚点与步长，供测试核对哪些格点落在轮廓上。
  private func latticeCells(mask: BodyMask, step: Int) -> [(Int, Int)] {
    var cells: [(Int, Int)] = []
    for y in stride(from: mask.minY, through: mask.maxY, by: step) {
      for x in stride(from: mask.minX, through: mask.maxX, by: step) where mask.contains(x: x, y: y) {
        cells.append((x, y))
      }
    }
    return cells
  }

  private func isBoundary(_ mask: BodyMask, x: Int, y: Int) -> Bool {
    !mask.contains(x: x - 1, y: y) || !mask.contains(x: x + 1, y: y)
      || !mask.contains(x: x, y: y - 1) || !mask.contains(x: x, y: y + 1)
  }

  // MARK: - Coarse grid

  func testDownsampleKeepsTheBodyCellsAndBlanksTheWall() throws {
    let frame = DepthImage(width: 160, height: 120, metres: bodyImage().metres)!.downsampled()
    XCTAssertEqual(frame.metres.count, DepthFrame.width * DepthFrame.height)
    // The head occupies the centre column near the top of the frame.
    XCTAssertGreaterThan(frame.value(x: 12, y: 6), 0)
    XCTAssertEqual(frame.value(x: 0, y: 0), 2.0, accuracy: 0.01)
  }
}
