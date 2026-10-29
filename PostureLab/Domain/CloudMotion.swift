import Foundation

/// 两个样本之间的点云过渡，用来把 10 Hz 的样本画成 30 fps 的连续动作。
///
/// 每个样本的点云是同一张格点上的采样，所以索引相同的两点就是身体上同一处表面：把前一个样本
/// 的点线性推到当前样本的点，画布按显示时钟取中间值，身体就从「每 100 ms 跳一下」变成连续移动。
/// 两个样本的点数不同（轮廓变了形）时直接切到新样本，因为那正是插值会把点拉过轮廓的时刻。
///
/// 纯函数、无副作用：同一个 `now` 永远给出同一份点。
struct CloudMotion: Equatable {
  /// 过渡时长，略长于一个样本间隔，让下一个样本到达时前一段正好走完。
  static let duration: TimeInterval = 0.12

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
