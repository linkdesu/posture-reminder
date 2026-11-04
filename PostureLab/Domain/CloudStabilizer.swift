import Foundation

/// 把逐帧深度变成一张**位置稳定**的点云：格点固定在画面上，每帧只更新每个格点的距离。
///
/// 为什么不再用「遮罩大小推步长」的采样（0.6.8 (14) 的做法）：那种采样每帧从遮罩包围盒的左上角起步，
/// 步长随 `mask.count` 变化——孩子前后移动十几厘米，步长就从 5 跳到 6、7，整张点云换一套位置；再叠上
/// 「先边界后内部」的顺序变化，按下标插值的 `CloudMotion` 会把身体这一处连到另一处，画面就是跳动与
/// 闪烁。真机日志里 `mask_cells` 在 6 263–24 871 之间变化，同一台设备不同轮次用到过 4/5/6/7 四种步长。
///
/// 现在：格点是**固定的 40×30 网格**（`columns × rows`），一个格点永远对应画面同一处（`slot`），距离取
/// 该格点所在的像素块内属于人体的有效深度中位数，再按时间常数 `smoothingTau` 做指数平滑。位置不随
/// 遮罩大小改变，平滑只作用在距离上，所以点云不再重采样，也不再抖。
///
/// 掉出的人体格点不会立刻消失：保留 `maxAge` 秒（一帧遮挡不会让身体缺一块），之后才移除。没有人体时
/// 整张点云在 `maxAge` 内淡出为空，交给界面画轮廓。
struct CloudStabilizer {
  /// 固定格点的列数与行数：40×30 = 1200 个槽位，160×120 的深度帧下每个槽位约 4×4 像素。
  static let columns = 40
  static let rows = 30
  /// 一帧最多输出多少个点。多于预算时按槽位顺序均匀抽取（位置不变，只是密度降低）。
  static let pointBudget = 600
  /// 距离平滑的时间常数，秒。0.2 s 下，一次 5 cm 的深度噪声在约三帧内衰减到 1 cm 以内。
  static let smoothingTau: TimeInterval = 0.2
  /// 一个槽位在没有新读数后还能被画多久，秒。
  static let maxAge: TimeInterval = 0.5

  private struct Slot {
    var z: Double
    var at: TimeInterval
  }

  private var slots: [Int: Slot] = [:]

  /// 这一帧的点云。`slot` 与画布位置一一对应，`z` 已做过时间平滑。
  mutating func points(mask: BodyMask?, image: DepthImage, at t: TimeInterval) -> [BodyPoint] {
    if let mask, mask.count > 0 {
      update(mask: mask, image: image, at: t)
    }
    expire(at: t)
    return snapshot()
  }

  /// 清空全部槽位（停止采集时用，避免下一次会话继承上一轮的距离）。
  mutating func reset() {
    slots.removeAll()
  }

  // MARK: - Slots

  /// 槽位的像素块。行数与列数固定，所以同一槽位在任何一帧里都落在同一块像素上。
  static func block(slot: Int, width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
    let column = slot % columns
    let row = slot / columns
    let minX = column * width / columns
    let maxX = max(minX, (column + 1) * width / columns - 1)
    let minY = row * height / rows
    let maxY = max(minY, (row + 1) * height / rows - 1)
    return (minX, minY, maxX, maxY)
  }

  /// 槽位的归一化中心，与深度帧的归一化坐标同一套空间（0...1，y 向下）。
  static func centre(slot: Int, width: Int, height: Int) -> (x: Double, y: Double) {
    let block = block(slot: slot, width: width, height: height)
    return ((Double(block.minX + block.maxX) / 2 + 0.5) / Double(width),
            (Double(block.minY + block.maxY) / 2 + 0.5) / Double(height))
  }

  private mutating func update(mask: BodyMask, image: DepthImage, at t: TimeInterval) {
    for slot in 0..<(Self.columns * Self.rows) {
      let block = Self.block(slot: slot, width: image.width, height: image.height)
      var depths: [Float] = []
      for y in block.minY...block.maxY {
        for x in block.minX...block.maxX
        where mask.contains(x: x, y: y) && image.isValid(x: x, y: y) {
          depths.append(image.value(x: x, y: y))
        }
      }
      guard !depths.isEmpty else { continue }
      depths.sort()
      let reading = Double(depths[depths.count / 2])
      if let previous = slots[slot] {
        let dt = max(0, t - previous.at)
        // 指数平滑：一帧的权重是 1 - e^(-dt/τ)，帧间隔越长权重越大，抖动不会被永久带在点云里。
        let alpha = 1 - exp(-dt / Self.smoothingTau)
        slots[slot] = Slot(z: previous.z + (reading - previous.z) * alpha, at: t)
      } else {
        slots[slot] = Slot(z: reading, at: t)
      }
    }
  }

  private mutating func expire(at t: TimeInterval) {
    guard !slots.isEmpty else { return }
    for (slot, value) in slots where t - value.at > Self.maxAge {
      slots.removeValue(forKey: slot)
    }
  }

  private func snapshot() -> [BodyPoint] {
    guard !slots.isEmpty else { return [] }
    let ids = slots.keys.sorted()
    let stride = max(1, Int((Double(ids.count) / Double(Self.pointBudget)).rounded(.up)))
    var points: [BodyPoint] = []
    points.reserveCapacity(min(ids.count, Self.pointBudget))
    // 固定顺序（槽位升序）+ 固定步长：同一个人体在相邻两帧里拿到的是同一批槽位，位置不跳。
    var index = 0
    while index < ids.count {
      let slot = ids[index]
      let value = slots[slot]!
      // 归一化位置需要帧的尺寸；槽位本身不存尺寸，所以用固定网格的等比坐标。
      let column = slot % Self.columns
      let row = slot / Self.columns
      points.append(BodyPoint(x: (Double(column) + 0.5) / Double(Self.columns),
                              y: (Double(row) + 0.5) / Double(Self.rows),
                              z: value.z,
                              slot: slot))
      index += stride
    }
    return points
  }
}
