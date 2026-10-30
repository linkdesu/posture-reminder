import XCTest
@testable import PostureLab

/// 4 个关键点的平滑与出现/消失过渡：静止时位移远小于屏宽 2%，缺失时保持 300 ms 再 200 ms 淡出。
final class KeyPointOverlayMotionTests: XCTestCase {
  private let full: [JointID: CGPoint] = [
    .nose: CGPoint(x: 0.50, y: 0.30),
    .neck: CGPoint(x: 0.50, y: 0.42),
    .leftShoulder: CGPoint(x: 0.28, y: 0.52),
    .rightShoulder: CGPoint(x: 0.72, y: 0.52),
  ]

  func testAStaticBodyMovesLessThanTwoPercentOfTheWidth() {
    var motion = KeyPointOverlayMotion()
    var previous: [JointID: CGPoint] = [:]
    var displacements: [CGFloat] = []
    // 30 fps、静坐 10 秒：位置不变，只测试平滑本身不引入漂移。
    for frame in 0..<300 {
      motion.update(full, at: Double(frame) / 30)
      let now = motion.displayed(at: Double(frame) / 30).points
      for (id, point) in now {
        if let old = previous[id] {
          displacements.append(hypot(point.x - old.x, point.y - old.y))
        }
      }
      previous = now
    }
    XCTAssertEqual(displacements.max() ?? 1, 0, accuracy: 1e-9,
                   "an unchanged pose must not drift")
  }

  func testTheSmoothedPointFollowsAStepWithoutJumping() throws {
    var motion = KeyPointOverlayMotion()
    for frame in 0..<10 { motion.update(full, at: Double(frame) / 30) }
    var moved = full
    moved[.leftShoulder] = CGPoint(x: 0.48, y: 0.52)
    motion.update(moved, at: 10.0 / 30)
    let firstStep = try XCTUnwrap(motion.displayed(at: 10.0 / 30).points[.leftShoulder])
    // 一帧走完的时间常数 0.15 s：单帧只应该走一小部分，而不是瞬移。
    XCTAssertLessThan(abs(Double(firstStep.x) - 0.28), 0.2)
  }

  func testAMissingKeyPointHoldsForThreeHundredMillisecondsThenFades() {
    var motion = KeyPointOverlayMotion()
    for frame in 0..<10 { motion.update(full, at: Double(frame) / 30) }
    XCTAssertEqual(motion.alpha(at: 0.3), 1, accuracy: 0.01)

    // 关键点从 t = 0.5 起缺失：0.5…0.8 保持不透明，0.8…1.0 淡出。
    motion.update([:], at: 0.5)
    XCTAssertEqual(motion.alpha(at: 0.79), 1, accuracy: 0.01)
    XCTAssertEqual(motion.alpha(at: 0.90), 0.5, accuracy: 0.05)
    XCTAssertEqual(motion.alpha(at: 1.10), 0, accuracy: 0.01)
    // 保持期间仍然画最后已知位置，不是空数组。
    XCTAssertEqual(motion.displayed(at: 0.7).points.count, 4)
  }

  func testRecoveryFadesInRatherThanSnapping() {
    var motion = KeyPointOverlayMotion()
    motion.update(full, at: 0)
    motion.update([:], at: 0.1)
    XCTAssertEqual(motion.alpha(at: 1.0), 0, accuracy: 0.01, "fully faded out")

    motion.update(full, at: 2.0)
    XCTAssertEqual(motion.alpha(at: 2.0), 0, accuracy: 0.01)
    XCTAssertEqual(motion.alpha(at: 2.1), 0.5, accuracy: 0.05)
    XCTAssertEqual(motion.alpha(at: 2.25), 1, accuracy: 0.01)
  }
}
