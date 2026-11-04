import Foundation

/// 横滚基线的静默校准：专注开头 3 秒里，把 Vision 眼线/耳线给出的角度取中位数，作为这个孩子
/// 「坐正时头有多歪」的个人基线。
///
/// r20 诊断：`PostureBaseline.from` 把 roll 基线写死为 0，而每个孩子坐正时的头部横滚并不相同，
/// 于是「abs(当前 − 0) > 15°」对一些人永远成立。校准只作用于横滚；距离与俯仰的基线仍来自设置。
///
/// 纯值类型、时间由调用方注入：3 秒里少于 `minimumSamples` 个样本时不产出基线（返回 nil），
/// 后续样本继续以未校准的角度参与判定，绝不假装校准过。
struct RollCalibrator: Equatable {
  /// 校准窗口。
  static let duration: TimeInterval = 3
  /// 至少这么多个有效角度才取中位数。
  static let minimumSamples = 10

  private var start: TimeInterval?
  private var samples: [Double] = []
  private(set) var baseline: Double?
  /// 校准是否已经有结论：要么得到了基线，要么样本不够而放弃（此时 `baseline` 仍为 nil）。
  private(set) var isSettled = false

  /// 收一个角度；返回是否应当把它记入校准（false = 校准已结束）。
  mutating func observe(_ angle: Double, at t: TimeInterval) -> Bool {
    guard !isSettled else { return false }
    if start == nil { start = t }
    samples.append(angle)
    guard let start, t - start >= Self.duration else { return true }
    isSettled = true
    guard samples.count >= Self.minimumSamples else { return true }
    let sorted = samples.sorted()
    baseline = sorted[sorted.count / 2]
    return true
  }

  /// 把实测角度换成相对基线的角度；没有基线时原样返回。
  func relative(_ angle: Double?) -> Double? {
    guard let angle else { return nil }
    return angle - (baseline ?? 0)
  }
}
