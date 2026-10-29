import XCTest
@testable import PostureLab

/// 两个样本之间的过渡：起点、终点、中间值和点数不一致时的退化。
final class CloudMotionTests: XCTestCase {
  private func point(_ x: Double) -> BodyPoint {
    BodyPoint(x: x, y: 0.5, z: 0.5)
  }

  func testBeforeTheFirstSampleNothingIsDisplayed() {
    let motion = CloudMotion()
    XCTAssertTrue(motion.displayed(at: 100).isEmpty)
  }

  func testTheTransitionStartsAtTheOldFrameAndEndsAtTheNewOne() {
    var motion = CloudMotion()
    motion.push([point(0)], at: 10)
    XCTAssertEqual(motion.displayed(at: 10), [point(0)])

    motion.push([point(1)], at: 10.1)
    XCTAssertEqual(motion.displayed(at: 10.1), [point(0)])
    XCTAssertEqual(motion.displayed(at: 10.1 + CloudMotion.duration), [point(1)])
    // 过渡走完之后一直停在新样本上。
    XCTAssertEqual(motion.displayed(at: 10.2 + CloudMotion.duration), [point(1)])
  }

  func testTheMidpointSitsBetweenTheTwoFrames() throws {
    var motion = CloudMotion()
    motion.push([point(0)], at: 0)
    motion.push([point(1)], at: 0)
    let middle = try XCTUnwrap(motion.displayed(at: CloudMotion.duration / 2).first)
    XCTAssertEqual(middle.x, 0.5, accuracy: 0.001)
  }

  func testADifferentPointCountSnapsToTheNewFrame() {
    var motion = CloudMotion()
    motion.push([point(0), point(0)], at: 0)
    motion.push([point(1)], at: 0)
    XCTAssertEqual(motion.displayed(at: 0), [point(1)])
  }

  func testAnEmptySampleClearsTheCloud() {
    var motion = CloudMotion()
    motion.push([point(0)], at: 0)
    motion.push([], at: 0.05)
    XCTAssertTrue(motion.displayed(at: 0.05).isEmpty)
  }
}
