import XCTest
@testable import PostureLab

/// 人形的 8 个关节各自的平滑与出现/消失：某个关节低于置信度门槛后保持 300 ms、再用 200 ms 淡出，
/// 其余关节不受影响；从缺失恢复时同样用 200 ms 淡入，不瞬亮。
///
/// 0.6.8 (18) 的真机缺口：过渡层沿用「头/颈/双肩四个齐全才显示整组」的旧规则，而人形交付 8 个关节、
/// 颈与右肩几乎从不过 0.5 门槛，于是整组永远不显示、只剩点云。这里用任意子集把这条曲线钉住。
final class KeyPointOverlayMotionTests: XCTestCase {
  private let body: [JointID: CGPoint] = [
    .nose: CGPoint(x: 0.50, y: 0.28),
    .leftEye: CGPoint(x: 0.46, y: 0.27),
    .rightEye: CGPoint(x: 0.54, y: 0.27),
    .leftEar: CGPoint(x: 0.42, y: 0.30),
    .rightEar: CGPoint(x: 0.58, y: 0.30),
    .neck: CGPoint(x: 0.50, y: 0.40),
    .leftShoulder: CGPoint(x: 0.30, y: 0.50),
    .rightShoulder: CGPoint(x: 0.70, y: 0.50),
  ]

  /// 30 Hz 显示、10 Hz 输入的静坐：位置不变，平滑本身不能引入漂移。
  func testAStaticPoseDoesNotDrift() {
    var motion = KeyPointOverlayMotion()
    var previous: [JointID: CGPoint] = [:]
    var displacements: [CGFloat] = []
    for frame in 0..<300 {
      let t = Double(frame) / 30
      motion.update(body, at: t)
      let now = motion.displayed(at: t).points
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

  /// 回归：只测到鼻与颈（真机常见）时这两个点也要显示，不能因为「不是四个齐全」整组隐藏。
  func testAnySubsetOfTheEightJointsIsDrawn() {
    var motion = KeyPointOverlayMotion()
    motion.update([.nose: body[.nose]!, .neck: body[.neck]!], at: 0)
    let shown = motion.displayed(at: 1)
    XCTAssertEqual(Set(shown.points.keys), [.nose, .neck])
    XCTAssertEqual(shown.points[.nose]?.x ?? -1, 0.50, accuracy: 1e-9)
  }

  /// 一个关节掉出画面：它自己保持 300 ms、再 200 ms 淡出；其它关节维持不透明。
  func testOneJointHoldsThenFadesWhileTheRestStayVisible() {
    var motion = KeyPointOverlayMotion()
    for frame in 0..<10 { motion.update(body, at: Double(frame) / 30) }
    XCTAssertEqual(motion.alpha(for: .rightShoulder, at: 0.3), 1, accuracy: 0.01)

    var partial = body
    partial[.rightShoulder] = nil
    motion.update(partial, at: 0.5)

    XCTAssertEqual(motion.alpha(for: .rightShoulder, at: 0.79), 1, accuracy: 0.01,
                   "the hold window keeps it fully opaque")
    XCTAssertEqual(motion.alpha(for: .rightShoulder, at: 0.90), 0.5, accuracy: 0.05)
    XCTAssertEqual(motion.alpha(for: .rightShoulder, at: 1.10), 0.0, accuracy: 0.01)
    XCTAssertEqual(motion.alpha(for: .nose, at: 1.10), 1, accuracy: 0.01,
                   "a lost shoulder must not fade the head")
  }

  /// 保持期间画的是最后已知位置，不是空点。
  func testALostJointKeepsItsLastKnownPosition() {
    var motion = KeyPointOverlayMotion()
    for frame in 0..<10 { motion.update(body, at: Double(frame) / 30) }
    var partial = body
    partial[.leftShoulder] = nil
    motion.update(partial, at: 0.5)
    let held = motion.displayed(at: 0.7)
    XCTAssertEqual(held.points[.leftShoulder]?.x ?? -1, 0.30, accuracy: 1e-9)
    XCTAssertEqual(held.points[.leftShoulder]?.y ?? -1, 0.50, accuracy: 1e-9)
  }

  /// 从缺失恢复：先 200 ms 淡入，不瞬亮。
  func testARecoveredJointFadesInOverTwoHundredMilliseconds() {
    var motion = KeyPointOverlayMotion()
    motion.update(body, at: 0)
    motion.update([:], at: 0.1)
    XCTAssertEqual(motion.alpha(for: .nose, at: 1.0), 0, accuracy: 0.01, "fully faded out")

    motion.update(body, at: 2.0)
    XCTAssertEqual(motion.alpha(for: .nose, at: 2.0), 0, accuracy: 0.01)
    XCTAssertEqual(motion.alpha(for: .nose, at: 2.1), 0.5, accuracy: 0.05)
    XCTAssertEqual(motion.alpha(for: .nose, at: 2.25), 1, accuracy: 0.01)
  }

  /// 一帧的真实移动被平滑摊开：单帧只走一小部分，不是瞬移。
  func testAStepIsSmoothedRatherThanSnapped() throws {
    var motion = KeyPointOverlayMotion()
    for frame in 0..<10 { motion.update(body, at: Double(frame) / 30) }
    var moved = body
    moved[.leftShoulder] = CGPoint(x: 0.48, y: 0.52)
    motion.update(moved, at: 10.0 / 30)
    let firstStep = try XCTUnwrap(motion.displayed(at: 10.0 / 30).points[.leftShoulder])
    let travelled = hypot(firstStep.x - 0.30, firstStep.y - 0.50)
    XCTAssertGreaterThan(travelled, 0, "it must move at all")
    XCTAssertLessThan(travelled, 0.2, "0.15 s time constant: one frame is a fraction, not a jump")
  }
}
