import Foundation

/// 一帧位移的滚动 p95：抖动的量化口径。
///
/// **什么算抖动。** 只有「静止帧」进直方图：这一帧的原始输入位移（关键点取 8 个关节里最大的一步，
/// 点云取按槽位配对的平均位移）不超过 `stillLimit`（0.5% 屏宽）。孩子真的在扭头、起身的那一帧是
/// 动作，不是抖动，混进来会把 p95 变成「孩子多久动一次」。
///
/// **窗口。** 直方图按秒分箱，只保留最近 `windowSeconds`（10）秒；p95 是窗口内所有样本合并后的
/// 分位，不是「每秒 p95 的平均」。样本少于 `minimumSamples` 时没有答案（nil），不发一个假数字。
///
/// **单位。** 归一化坐标下的欧氏位移。点云与关键点共用同一套归一化空间（0...1 横跨画面矩形），
/// 在 iPhone 13 竖屏上画面矩形宽就是屏宽，所以 0.01 就是 1% 屏宽。
///
/// 纯值类型，单测直接推进时间。应用侧在 DEBUG 构建里由 `PerfMonitor` 每秒把 p95 写进 `perf-*.jsonl`。
struct JitterMeter {
  /// 判「静止帧」的原始输入位移上限。
  static let stillLimit = 0.005
  /// 直方图分档宽度（0.05% 屏宽）。
  static let binWidth = 0.0005
  /// 分档数：0–4% 屏宽；更大的位移并入最后一档。
  static let binCount = 80
  /// 滚动窗口长度，秒。
  static let windowSeconds = 10
  /// 少于这么多样本就不给 p95。
  static let minimumSamples = 100

  private struct Second: Equatable {
    var index: Int
    var bins: [Int]
  }

  private var current: Second?
  private var history: [Second] = []

  /// 收一帧。`displacements` 是这个静止帧里各点的位移；`rawShift` 是这一帧的原始输入位移。
  /// 返回这一帧有没有被计入。
  @discardableResult
  mutating func record(displacements: [Double], rawShift: Double, at t: TimeInterval) -> Bool {
    guard rawShift.isFinite, rawShift <= Self.stillLimit else { return false }
    guard !displacements.isEmpty else { return false }
    let second = Int(t.rounded(.down))
    if let now = current, second > now.index {
      history.append(now)
      current = Second(index: second, bins: [Int](repeating: 0, count: Self.binCount))
    } else if current == nil || second < (current?.index ?? second) {
      current = Second(index: second, bins: [Int](repeating: 0, count: Self.binCount))
      history.removeAll()
    }
    for displacement in displacements where displacement.isFinite && displacement >= 0 {
      let index = min(Self.binCount - 1, Int(displacement / Self.binWidth))
      current?.bins[index] += 1
    }
    prune()
    return true
  }

  /// 窗口里的样本数；`t` 用来判哪些秒箱还在窗口内。
  func sampleCount(at t: TimeInterval) -> Int {
    window(at: t).reduce(0) { $0 + $1.bins.reduce(0, +) }
  }

  /// 窗口内位移的 p95（屏宽比例）；样本不足时 nil。返回的是所在档的上沿，所以不会低估。
  func p95(at t: TimeInterval) -> Double? {
    let seconds = window(at: t)
    let total = seconds.reduce(0) { $0 + $1.bins.reduce(0, +) }
    guard total >= Self.minimumSamples else { return nil }
    let target = Int((0.95 * Double(total - 1)).rounded())
    var cumulative = 0
    for index in 0..<Self.binCount {
      cumulative += seconds.reduce(0) { $0 + $1.bins[index] }
      if cumulative > target {
        return Double(index + 1) * Self.binWidth
      }
    }
    return Double(Self.binCount) * Self.binWidth
  }

  private func window(at t: TimeInterval) -> [Second] {
    let last = Int(t.rounded(.down))
    let first = last - Self.windowSeconds + 1
    var seconds = history.filter { $0.index >= first && $0.index <= last }
    if let current, current.index >= first, current.index <= last {
      seconds.append(current)
    }
    return seconds
  }

  private mutating func prune() {
    let latest = current?.index ?? 0
    let first = latest - Self.windowSeconds + 1
    history.removeAll { $0.index < first }
  }
}
