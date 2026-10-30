import XCTest
@testable import PostureLab

/// 遮罩肩线原型：只用合成遮罩验证「能测出肩线、能算角度、能判是否高于头部」。它不进判定，
/// 只与 Vision 肩线并排写进 joints 日志，供后续定方案。
final class MaskShoulderLineTests: XCTestCase {
  private let width = 160
  private let height = 120

  /// 头（圆盘）+ 躯干（矩形）的深度帧，`lean` 让躯干左右边界不同高，用来造倾斜肩线。
  private func body(shift: Int = 0, lean: Int = 0, torsoTop: Int = 40) -> DepthImage {
    var metres = [Float](repeating: 2.0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let inHead = hypot(Double(x - 80 - shift), Double(y - 30)) <= 13
        let inTorso = y >= torsoTop && y <= 100 && abs(Double(x - 80 - shift)) <= 30 + Double(lean * (y - torsoTop) / 60)
        guard inHead || inTorso else { continue }
        metres[y * width + x] = 0.5
      }
    }
    return DepthImage(width: width, height: height, metres: metres)!
  }

  private func mask(_ image: DepthImage) throws -> BodyMask {
    try XCTUnwrap(DepthSegmentation.segment(image))
  }

  func testASeatedBodyGivesALevelShoulderLine() throws {
    let estimate = MaskShoulderLine.estimate(mask: try mask(body()), head: nil)

    XCTAssertTrue(estimate.available)
    let left = try XCTUnwrap(estimate.left)
    let right = try XCTUnwrap(estimate.right)
    XCTAssertLessThan(left.x, right.x)
    XCTAssertEqual(try XCTUnwrap(estimate.angleDeg), 0, accuracy: 5)
  }

  func testAHeadOnItsOwnHasNoShoulderLine() throws {
    var image = body()
    var metres = image.metres
    for y in 40..<height {
      for x in 0..<width { metres[y * width + x] = 2.0 }
    }
    image = try XCTUnwrap(DepthImage(width: width, height: height, metres: metres))

    let estimate = MaskShoulderLine.estimate(mask: try mask(image), head: nil)
    XCTAssertFalse(estimate.available)
    XCTAssertNil(estimate.left)
  }

  func testTheShoulderLineIsHigherThanTheNoseWhenItSitsAboveIt() throws {
    let estimate = MaskShoulderLine.estimate(mask: try mask(body()), head: nil)
    XCTAssertEqual(MaskShoulderLine.aboveHead(estimate, noseY: 0.5), true)
    XCTAssertEqual(MaskShoulderLine.aboveHead(estimate, noseY: 0.05), false)
  }

  func testALeanedBodyFoldsTheAngleIntoNinetyDegrees() throws {
    let estimate = MaskShoulderLine.estimate(mask: try mask(body(lean: 20)), head: nil)
    let angle = try XCTUnwrap(estimate.angleDeg)
    XCTAssertTrue((-90...90).contains(angle))
  }
}
