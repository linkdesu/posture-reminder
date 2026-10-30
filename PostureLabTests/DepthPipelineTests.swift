import XCTest
@testable import PostureLab

/// The depth pipeline end to end on synthetic frames: segmentation, the head geometry depth alone
/// can honestly report, and the cloud sampled from the mask. Joints come from Vision now; their
/// mapping has its own tests.
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

  private func flatWall() -> DepthImage {
    DepthImage(width: width, height: height,
               metres: [Float](repeating: 1.4, count: width * height))!
  }

  /// The same seated body at TrueDepth's own size: 320 by 240, head disc radius 26, torso 120 px
  /// wide, wall at 2 m. `DepthCaptureSource` resamples this down before segmenting it.
  private func wideBodyImage() -> DepthImage {
    let wideWidth = 320
    let wideHeight = 240
    var metres = [Float](repeating: background, count: wideWidth * wideHeight)
    for y in 0..<wideHeight {
      for x in 0..<wideWidth {
        let inHead = hypot(Double(x - 160), Double(y - 60)) <= 26
        let inTorso = y >= 78 && y <= 200 && abs(Double(x - 160)) <= 60
        guard inHead || inTorso else { continue }
        metres[y * wideWidth + x] = 0.5
      }
    }
    return DepthImage(width: wideWidth, height: wideHeight, metres: metres)!
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

  // MARK: - Head geometry

  /// 头部深度带给出的距离、俯仰、横滚。关节现在来自 Vision，深度一侧只负责这三样，所以它们必须
  /// 在没有关节的情况下也成立。
  func testHeadGeometryReadsDistanceFromTheMaskOnly() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let reading = HeadGeometry.measure(depth: image, mask: mask)

    XCTAssertEqual(try XCTUnwrap(reading.distanceCM), 50, accuracy: 6,
                   "the wall behind the child must not pull the distance back")
  }

  func testHeadGeometryIsEmptyWithoutABody() {
    let reading = HeadGeometry.measure(depth: flatWall(), mask: nil)
    XCTAssertNil(reading.distanceCM)
    XCTAssertNil(reading.pitchDeg)
    XCTAssertNil(reading.rollDeg)
  }

  func testHeadGeometryFollowsTheDepthSlope() throws {
    let uprightImage = bodyImage()
    let upright = HeadGeometry.measure(depth: uprightImage,
                                       mask: try XCTUnwrap(DepthSegmentation.segment(uprightImage)))
    XCTAssertEqual(upright.pitchDeg ?? .nan, 0, accuracy: 1.5)

    // The bottom of the head 0.3 m farther than its top: a head tipped back, positive pitch here.
    let upImage = bodyImage(headSlope: 0.3 / 30)
    let up = HeadGeometry.measure(depth: upImage,
                                  mask: try XCTUnwrap(DepthSegmentation.segment(upImage)))
    XCTAssertGreaterThan(try XCTUnwrap(up.pitchDeg), 5)

    // The opposite slope is a nod.
    let downImage = bodyImage(headSlope: -0.3 / 30)
    let down = HeadGeometry.measure(depth: downImage,
                                    mask: try XCTUnwrap(DepthSegmentation.segment(downImage)))
    XCTAssertLessThan(try XCTUnwrap(down.pitchDeg), -5)
  }

  /// 深度图的两种「没读数」：NaN（TrueDepth 的 Float32 用 NaN 表示没有读数）与 0。
  /// 真机排查靠这两列分开「传感器整帧没读数」与「有人但没分割出来」。
  func testDepthValiditySeparatesNaNAndValidReadings() throws {
    let nanFrame = try XCTUnwrap(DepthImage(width: 2, height: 2, metres: [.nan, .nan, .nan, .nan]))
    XCTAssertEqual(nanFrame.validFraction, 0, accuracy: 0.0001)
    XCTAssertEqual(nanFrame.nanFraction, 1, accuracy: 0.0001)

    let mixed = try XCTUnwrap(DepthImage(width: 2, height: 2, metres: [0.5, .nan, 0, 2.0]))
    XCTAssertEqual(mixed.validFraction, 0.5, accuracy: 0.0001)
    XCTAssertEqual(mixed.nanFraction, 0.25, accuracy: 0.0001)
  }

  // MARK: - Cloud

  func testCloudComesFromMaskPixelsAndKeepsTheirDepth() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let cloud = DepthCloud.points(mask: mask, image: image)

    XCTAssertEqual(cloud.count, DepthCloud.pointBudget,
                   "every depth frame carries the same number of points")
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

  /// 点数固定是插值每帧生效的前提：同一个预算下，大身子和小身子都给 600 点。
  func testEveryFrameFillsTheSamePointBudget() throws {
    XCTAssertEqual(DepthCloud.pointBudget, 600)
    for image in [bodyImage(), bodyImage(headRadius: 8, torsoHalfWidth: 10)] {
      let mask = try XCTUnwrap(DepthSegmentation.segment(image))
      XCTAssertEqual(DepthCloud.points(mask: mask, image: image).count, 600)
    }
  }

  /// 预算比身体的格点还多时（极瘦的轮廓）循环补齐，补齐的点仍来自轮廓本身。
  func testASparseBodyFillsTheBudgetByRepeatingItsOwnPoints() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let cloud = DepthCloud.points(mask: mask, image: image, maxPoints: 2000)

    XCTAssertEqual(cloud.count, 2000)
    for point in cloud {
      XCTAssertEqual(point.z, 0.5, accuracy: 0.001)
      XCTAssertTrue((0...1).contains(point.x))
      XCTAssertTrue((0...1).contains(point.y))
    }
  }

  /// 补齐的点按收集顺序重复：同样的遮罩、同样的预算，永远给同一份点。
  func testThePaddingIsDeterministic() throws {
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    XCTAssertEqual(DepthCloud.points(mask: mask, image: image, maxPoints: 2000),
                   DepthCloud.points(mask: mask, image: image, maxPoints: 2000))
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

  // MARK: - Resampling

  func testResamplingHalvesTheFrameAndKeepsTheBodyOffTheWall() throws {
    let wide = wideBodyImage()
    let small = wide.resampled(maxWidth: 160)

    XCTAssertEqual(small.width, 160)
    XCTAssertEqual(small.height, 120)
    // 躯干中心还是 0.5 m，画面角落还是 2 m 的墙：缩放不能把人抹掉，也不能把墙拉近。
    XCTAssertEqual(small.value(x: 80, y: 90), 0.5, accuracy: 0.06)
    XCTAssertEqual(small.value(x: 1, y: 1), background, accuracy: 0.06)
  }

  func testAWideFrameIsResampledBeforeTheHeadIsMeasured() throws {
    // 真机的深度帧是 320×240；采集源先缩到 160 px 再分割、量头，距离仍是半米。
    let image = wideBodyImage().resampled(maxWidth: 160)
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let reading = HeadGeometry.measure(depth: image, mask: mask)

    XCTAssertEqual(try XCTUnwrap(reading.distanceCM), 50, accuracy: 6)
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
