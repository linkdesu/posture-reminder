import Foundation

/// 两个样本之间的点云过渡，用来把 30 Hz 的深度帧画成连续的移动。
///
/// 每个样本的点云是同一张格点上的采样，点数固定（`DepthCloud.pointBudget`），所以索引相同的两点
/// 就是身体上同一处表面：把前一帧的点线性推到当前帧的点，画布按显示时钟取中间值，身体就从「每帧
/// 跳一下」变成连续移动。点数不同（只可能是脚本源）时直接切到新样本，因为那正是插值会把点拉过轮廓
/// 的时刻。
///
/// 纯函数、无副作用：同一个 `now` 永远给出同一份点。
struct CloudMotion: Equatable {
  /// 过渡时长取一个深度帧间隔（30 Hz 约 33 ms）：下一帧到达时前一段正好走完，画面不再落后。
  static let duration: TimeInterval = 1.0 / 30.0

  private(set) var from: [BodyPoint] = []
  private(set) var to: [BodyPoint] = []
  private(set) var start: TimeInterval = 0
  private(set) var end: TimeInterval = 0

  init() {}

  /// 收下一个样本。起点是「此刻屏幕上正在显示的那一帧」，所以连续两个样本之间不会跳。
  mutating func push(_ points: [BodyPoint], at now: TimeInterval) {
    from = displayed(at: now)
    to = points
    start = now
    end = now + Self.duration
  }

  /// 显示时钟 `now` 上的那一帧。`from`/`to` 点数不同、或过渡已经走完时返回当前样本本身。
  func displayed(at now: TimeInterval) -> [BodyPoint] {
    guard !to.isEmpty else { return to }
    guard from.count == to.count, end > start else { return to }
    let progress = (now - start) / (end - start)
    guard progress < 1 else { return to }
    let t = max(0, progress)
    var result = to
    for index in to.indices {
      let a = from[index]
      let b = to[index]
      result[index] = BodyPoint(x: a.x + (b.x - a.x) * t,
                                y: a.y + (b.y - a.y) * t,
                                z: a.z + (b.z - a.z) * t)
    }
    return result
  }
}
