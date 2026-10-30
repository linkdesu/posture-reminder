import CoreGraphics
import Foundation

/// 帧间配对：判断「同一处」的位移。
///
/// 点云按固定网格的 `slot` 配对（槽位与画面位置一一对应，见 `BodyPoint`），关键点按关节 ID 配对。
/// 只有**两帧都出现**的对象才成对——上一帧有点、这一帧没有，是身体进出画面，不是抖动；把这种跳变
/// 当成抖动会把 p95 一路推高，然后错误地判掉点云。
enum JitterPairing {
  /// 点云里成对槽位的位移（归一化坐标的欧氏距离）。
  static func pairedDisplacements(from previous: [BodyPoint],
                                  to current: [BodyPoint]) -> [Double] {
    guard !previous.isEmpty, !current.isEmpty else { return [] }
    var bySlot: [Int: BodyPoint] = [:]
    bySlot.reserveCapacity(previous.count)
    for point in previous where point.slot >= 0 { bySlot[point.slot] = point }
    var displacements: [Double] = []
    displacements.reserveCapacity(current.count)
    for point in current where point.slot >= 0 {
      guard let old = bySlot[point.slot] else { continue }
      displacements.append(hypot(point.x - old.x, point.y - old.y))
    }
    return displacements
  }

  /// 点云成对槽位的平均位移；没有成对的点时为 0。
  static func meanShift(from previous: [BodyPoint], to current: [BodyPoint]) -> Double {
    let displacements = pairedDisplacements(from: previous, to: current)
    guard !displacements.isEmpty else { return 0 }
    return displacements.reduce(0, +) / Double(displacements.count)
  }

  /// 关键点里两帧都有的关节的位移。
  static func pairedDisplacements(previous: [JointID: CGPoint],
                                  current: [JointID: CGPoint]) -> [Double] {
    guard !previous.isEmpty, !current.isEmpty else { return [] }
    var displacements: [Double] = []
    displacements.reserveCapacity(current.count)
    for (id, point) in current {
      guard let old = previous[id] else { continue }
      displacements.append(hypot(Double(point.x - old.x), Double(point.y - old.y)))
    }
    return displacements
  }

  /// 关键点里两帧都有的关节中最大的一步：判「这一帧孩子是不是静止」。
  static func maxShift(previous: [JointID: CGPoint], current: [JointID: CGPoint]) -> Double {
    pairedDisplacements(previous: previous, current: current).max() ?? 0
  }
}
