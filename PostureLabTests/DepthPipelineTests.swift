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
                         torsoTop: Int = 39,
                         shift: Int = 0,
                         noise: Float = 0,
                         frame: Int = 0) -> DepthImage {
    var metres = [Float](repeating: background, count: width * height)
    // 确定性噪声：同一个 `frame` 永远给同一条 ±noise 序列。
    var seed = UInt64(truncatingIfNeeded: frame &+ 1) &* 2_654_435_761
    for y in 0..<height {
      for x in 0..<width {
        let centre = 80 + shift
        let inHead = hypot(Double(x - centre), Double(y - 30)) <= headRadius
        let inTorso = y >= torsoTop && y <= 100 && abs(Double(x - centre)) <= torsoHalfWidth
        guard inHead || inTorso else { continue }
        var depth = bodyDepth
        if inHead {
          // `headSlope` is metres of depth change per image row, so a positive slope means the
          // bottom of the head is farther away: a head tilted up.
          depth = (headDepth ?? bodyDepth) + headSlope * Float(y - 30)
        }
        if noise > 0 {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          let unit = Float(seed >> 33 % 2_000) / 1_000 - 1
          depth += unit * noise
        }
        metres[y * width + x] = depth
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

  // MARK: - Cloud（固定网格 + 帧间平滑）

  /// 验收：静坐 10 秒（遮罩包围盒抖动 ±2 px、深度噪声 ±2 cm），逐点位移 p95 ≤ 屏宽 1%。
  ///
  /// 位移的算法与画布一致：槽位的归一化位置固定不变（x/y 位移恒为 0）；画面上的位移只来自透视，
  /// 透视系数是 `cam / (cam + z - meanZ)`，对 z 的偏导约为 `1/cam`，而 `cam ≥ 0.5 m`。所以
  /// 「|Δz| p95 ≤ 5 mm」等价于「|Δperspective| ≤ 1%」，也就是距画面中心最远的点位移 ≤ 屏宽 1%。
  func testCloudIsStableUnderMaskJitterAndDepthNoise() throws {
    var stabilizer = CloudStabilizer()
    var previous: [Int: BodyPoint] = [:]
    var displacements: [Double] = []
    var shifts: [Double] = []

    // 10 秒、30 Hz：每帧把身体整体平移 ±2 px，并加 ±2 cm 的深度噪声。
    for frame in 0..<300 {
      let shift = frame % 5 - 2
      let image = bodyImage(shift: shift, noise: 0.02, frame: frame)
      let mask = try XCTUnwrap(DepthSegmentation.segment(image))
      let cloud = stabilizer.points(mask: mask, image: image, at: Double(frame) / 30)
      var current: [Int: BodyPoint] = [:]
      for point in cloud { current[point.slot] = point }
      for (slot, point) in current {
        guard let old = previous[slot] else { continue }
        shifts.append(max(abs(point.x - old.x), abs(point.y - old.y)))
        displacements.append(abs(point.z - old.z))
      }
      previous = current
    }

    XCTAssertGreaterThan(displacements.count, 1000, "the fixture has to produce a real cloud")
    // 位置固定：同一个槽位永远落在同一处，横向位移恒为 0。
    XCTAssertEqual(shifts.max() ?? 1, 0, accuracy: 1e-9, "slot positions must not move")
    let sorted = displacements.sorted()
    let p95 = sorted[Int(0.95 * Double(sorted.count - 1))]
    XCTAssertLessThanOrEqual(p95, 0.005,
                             "smoothed depth jitter must stay under 5 mm (≈1% of screen width)")
  }

  /// 槽位由固定网格决定，不随遮罩大小、包围盒起点改变：大身子与小身子给同一批槽位坐标。
  func testTheLatticeDoesNotFollowTheMask() throws {
    func cloud(for image: DepthImage) throws -> [BodyPoint] {
      var stabilizer = CloudStabilizer()
      let mask = try XCTUnwrap(DepthSegmentation.segment(image))
      return stabilizer.points(mask: mask, image: image, at: 0)
    }
    let wide = try cloud(for: bodyImage(headRadius: 16, torsoHalfWidth: 40))
    let narrow = try cloud(for: bodyImage(torsoHalfWidth: 24))

    let column = { (slot: Int) in slot % CloudStabilizer.columns }
    let row = { (slot: Int) in slot / CloudStabilizer.columns }
    // 同一个槽位在两帧里的归一化位置都必须等于网格中心，与遮罩无关。
    for point in wide.prefix(20) + narrow.prefix(20) {
      XCTAssertEqual(point.x, (Double(column(point.slot)) + 0.5) / Double(CloudStabilizer.columns),
                     accuracy: 1e-9)
      XCTAssertEqual(point.y, (Double(row(point.slot)) + 0.5) / Double(CloudStabilizer.rows),
                     accuracy: 1e-9)
    }
    XCTAssertLessThan(narrow.count, wide.count, "a smaller body covers fewer slots")
  }

  /// 一帧没有遮罩不清空点云：保留 `maxAge`，超时才丢。
  func testAPointSurvivesAShortDropoutThenExpires() throws {
    var stabilizer = CloudStabilizer()
    let image = bodyImage()
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let first = stabilizer.points(mask: mask, image: image, at: 0)
    XCTAssertFalse(first.isEmpty)

    let kept = stabilizer.points(mask: nil, image: image, at: CloudStabilizer.maxAge * 0.8)
    XCTAssertEqual(kept.count, first.count, "a single missing frame must not blank the cloud")

    let expired = stabilizer.points(mask: nil, image: image, at: CloudStabilizer.maxAge * 1.5)
    XCTAssertTrue(expired.isEmpty, "after maxAge without a reading the slots expire")
  }

  func testTheCloudBudgetIsRespected() throws {
    var stabilizer = CloudStabilizer()
    let image = bodyImage(headRadius: 20, torsoHalfWidth: 70)
    let mask = try XCTUnwrap(DepthSegmentation.segment(image))
    let cloud = stabilizer.points(mask: mask, image: image, at: 0)
    XCTAssertLessThanOrEqual(cloud.count, CloudStabilizer.pointBudget)
    XCTAssertGreaterThan(cloud.count, 40)
  }

  func testTheStabilizedCloudIsDeterministic() throws {
    func cloud() throws -> [BodyPoint] {
      var stabilizer = CloudStabilizer()
      let image = bodyImage()
      let mask = try XCTUnwrap(DepthSegmentation.segment(image))
      return stabilizer.points(mask: mask, image: image, at: 1)
    }
    XCTAssertEqual(try cloud(), try cloud())
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
