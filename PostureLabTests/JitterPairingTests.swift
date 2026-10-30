import XCTest
@testable import PostureLab

/// 帧间配对的纯函数：点云按固定网格的槽位、关键点按关节 ID。只有两帧都出现的对象才成对——上一帧
/// 有、这一帧没有的点是「进出画面」，不是抖动。
final class JitterPairingTests: XCTestCase {
  private func point(_ x: Double, _ y: Double, slot: Int, z: Double = 0.6) -> BodyPoint {
    BodyPoint(x: x, y: y, z: z, slot: slot)
  }

  func testOnlySlotsPresentInBothFramesArePaired() {
    let previous = [point(0.10, 0.10, slot: 1), point(0.20, 0.20, slot: 2)]
    let current = [point(0.11, 0.10, slot: 1), point(0.50, 0.50, slot: 3)]
    let displacements = JitterPairing.pairedDisplacements(from: previous, to: current)
    XCTAssertEqual(displacements.count, 1)
    XCTAssertEqual(displacements[0], 0.01, accuracy: 1e-9)
  }

  func testTheMeanShiftAveragesThePairedSlots() {
    let previous = [point(0.10, 0.10, slot: 1), point(0.20, 0.20, slot: 2)]
    let current = [point(0.13, 0.14, slot: 1), point(0.20, 0.20, slot: 2)]
    // 两个槽位：0.05 与 0，平均 0.025。
    XCTAssertEqual(JitterPairing.meanShift(from: previous, to: current), 0.025, accuracy: 1e-9)
    XCTAssertEqual(JitterPairing.meanShift(from: [], to: current), 0, accuracy: 1e-9)
    XCTAssertEqual(JitterPairing.meanShift(from: previous, to: []), 0, accuracy: 1e-9)
  }

  func testKeyPointDisplacementsOnlyUseJointsInBothFrames() {
    let previous: [JointID: CGPoint] = [.nose: CGPoint(x: 0.5, y: 0.3),
                                        .neck: CGPoint(x: 0.5, y: 0.4)]
    let current: [JointID: CGPoint] = [.nose: CGPoint(x: 0.52, y: 0.3),
                                       .leftEye: CGPoint(x: 0.4, y: 0.28)]
    let displacements = JitterPairing.pairedDisplacements(previous: previous, current: current)
    XCTAssertEqual(displacements.count, 1, "颈这一帧缺失、左眼这一帧新出现：两者都不成对")
    XCTAssertEqual(displacements[0], 0.02, accuracy: 1e-9)
  }

  func testTheLargestRawShiftDecidesWhetherTheFrameIsStill() {
    let previous: [JointID: CGPoint] = [.nose: CGPoint(x: 0.5, y: 0.3)]
    let current: [JointID: CGPoint] = [.nose: CGPoint(x: 0.503, y: 0.304)]
    XCTAssertEqual(JitterPairing.maxShift(previous: previous, current: current), 0.005, accuracy: 1e-9)
    XCTAssertEqual(JitterPairing.maxShift(previous: [:], current: current), 0)
  }
}
