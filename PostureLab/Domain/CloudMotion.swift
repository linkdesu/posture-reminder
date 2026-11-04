import Foundation

/// 两个样本之间的点云过渡，用来把 30 Hz 的深度帧画成连续的移动。
///
/// 每个样本的点云来自同一张**固定网格**（`CloudStabilizer`），所以 `slot` 相同的两点就是身体上同一
/// 处表面：按槽位配对、把前一帧的点线性推到当前帧的点，画布按显示时钟取中间值。只按数组下标配对的
/// 做法在 0.6.8 (14) 上会让点在不同位置之间来回拉——因为采样网格跟着遮罩变，下标对应的位置每帧都
/// 不一样。没有槽位的脚本 rig 退回按下标配对。
///
/// 纯函数、无副作用：同一个 `now` 永远给出同一份点。
struct CloudMotion: Equatable {
  /// 默认过渡时长，只给没有帧间隔信息的地方（脚本 rig、首帧）用。
  static let duration: TimeInterval = 1.0 / 30.0

  private(set) var from: [BodyPoint] = []
  private(set) var to: [BodyPoint] = []
  private(set) var start: TimeInterval = 0
  private(set) var end: TimeInterval = 0

  init() {}

  /// 收下一个样本。起点是「此刻屏幕上正在显示的那一帧」，所以连续两个样本之间不会跳。
  ///
  /// `interval` 是这一帧与上一帧的**实际间隔**（深度帧呈现时刻之差）。写死 33 ms 时，遇到 66 ms 的
  /// 掉帧（真机日志里 p95 就是 66 ms）插值会先走完再停 33 ms，看起来就是一顿一跳。
  mutating func push(_ points: [BodyPoint], at now: TimeInterval, interval: TimeInterval? = nil) {
    from = displayed(at: now)
    to = points
    start = now
    let span = interval.map { min(max($0, 0.008), 0.25) } ?? Self.duration
    end = now + span
  }

  /// 显示时钟 `now` 上的那一帧。过渡走完、或两帧之间没有可配对的点时返回当前样本本身。
  func displayed(at now: TimeInterval) -> [BodyPoint] {
    guard !to.isEmpty else { return to }
    guard end > start else { return to }
    let progress = (now - start) / (end - start)
    guard progress < 1 else { return to }
    let t = max(0, progress)

    if usesSlots {
      // 按槽位配对：只有槽位相同（= 画面同一处）才插值；新出现的槽位直接以当前值入场。
      var previous: [Int: BodyPoint] = [:]
      previous.reserveCapacity(from.count)
      for point in from where point.slot >= 0 { previous[point.slot] = point }
      var result = to
      for index in to.indices {
        let b = to[index]
        guard b.slot >= 0, let a = previous[b.slot] else { continue }
        result[index] = BodyPoint(x: a.x + (b.x - a.x) * t,
                                  y: a.y + (b.y - a.y) * t,
                                  z: a.z + (b.z - a.z) * t,
                                  slot: b.slot)
      }
      return result
    }

    guard from.count == to.count else { return to }
    var result = to
    for index in to.indices {
      let a = from[index]
      let b = to[index]
      result[index] = BodyPoint(x: a.x + (b.x - a.x) * t,
                                y: a.y + (b.y - a.y) * t,
                                z: a.z + (b.z - a.z) * t,
                                slot: b.slot)
    }
    return result
  }

  /// 两帧都带槽位时才按槽位配对；脚本 rig 的点没有槽位，仍按下标配对。
  private var usesSlots: Bool {
    to.contains { $0.slot >= 0 }
  }
}
