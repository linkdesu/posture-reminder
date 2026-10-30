import Foundation

/// 用 TrueDepth 人体遮罩的轮廓估出第二条肩线，与 Vision 肩线并排进日志供对比（原型）。
///
/// 真机上 Vision 的肩点原始置信度中位数只有 0.37–0.47，被 0.5 门槛全部滤掉（r20 诊断），
/// 所以这里从深度遮罩里再量一条肩线。**只进日志、不进判定**：`PostureClassifier` 仍只看
/// Vision 肩点，Vision 的 0.5 门槛也不动。
///
/// 算法（可解释、可单测）：取遮罩下半部（`minY + 0.35 * height` 到 `maxY`），行宽首次达到
/// 「该区域最大行宽 85%」的那一行就是肩线行；左右端点取该行遮罩的左右边界（`rowExtent`）；
/// 角度用两端点 `atan2` 后折进 (−90°, 90°]（与 `VisionPoseMapping.lineDegrees` 同一口径）。
/// 遮罩行不够、或行宽 < 3 格时没有肩线。
enum MaskShoulderLine {
  /// 一条遮罩肩线的读数。坐标是屏幕归一化（0...1，y 向下）。
  struct Estimate: Equatable {
    /// 左肩端点（该行遮罩的左边界）。
    var left: CGPointLike?
    /// 右肩端点（该行遮罩的右边界）。
    var right: CGPointLike?
    /// 肩线相对水平线的角度，折进 (−90°, 90°]；端点不足时 nil。
    var angleDeg: Double?
    /// 肩线是否高于头部参考（鼻点，没有鼻点时遮罩头带中点）；没有头部参考时 nil。
    var aboveHead: Bool?
    /// 这一帧有没有测出肩线。
    var available: Bool

    /// 没有肩线时的读数（端点与角度全是 nil）。
    static var unavailable: Estimate {
      Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
    }
  }

  /// 没有肩线时的读数：端点、角度、头部比较全部为 nil，`available = false`。
  static var unavailable: Estimate {
    Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
  }

  /// 肩线是否高于头部关键点：比较肩线两端的较小 y（更高的一端）与鼻点 y。没有端点时 nil。
  static func aboveHead(_ shoulders: Estimate, noseY: Double?) -> Bool? {
    guard let noseY, let left = shoulders.left, let right = shoulders.right else { return nil }
    return min(left.y, right.y) < noseY
  }

  /// 肩线（或任意连线）相对水平线的角度，折进 (−90°, 90°]；两端点太近时 nil。
  /// 与 `VisionPoseMapping.lineDegrees` 同一口径。
  static func lineAngleDeg(from left: CGPointLike, to right: CGPointLike) -> Double? {
    guard hypot(right.x - left.x, right.y - left.y) > 0.01 else { return nil }
    var raw = atan2(right.y - left.y, right.x - left.x) * 180 / .pi
    if raw > 90 { raw = 180 - raw }
    if raw < -90 { raw = -180 - raw }
    return raw
  }

  /// `head` 传鼻点（`JointSample`，y 是屏幕归一化坐标）；nil 时用遮罩头带中点，再没有就不下结论。
  /// 肩线行必须比头带最宽处宽出这一倍，否则「只有头」的遮罩也会在自己的最宽行上造出一条肩线。
  static let headToShoulderRatio = 1.6

  static func estimate(mask: BodyMask, head: JointSample?) -> Estimate {
    let height = max(1, mask.maxY - mask.minY)
    let topY = max(mask.minY, mask.minY + Int(Double(height) * 0.35))
    guard topY <= mask.maxY else {
      return Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
    }

    // 该区域的最大行宽，顺数有身体的行数。
    var maxWidth = 0
    var rowCount = 0
    for y in topY...mask.maxY {
      if let extent = mask.rowExtent(y: y) {
        rowCount += 1
        maxWidth = max(maxWidth, extent.maxX - extent.minX + 1)
      }
    }
    guard rowCount >= 3, maxWidth >= 3 else {
      return Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
    }
    // 行宽首次够到最大行宽 85% 的那一行就是肩线行。
    let threshold = (maxWidth * 85) / 100
    var shoulderY: Int?
    for y in topY...mask.maxY {
      if let extent = mask.rowExtent(y: y), extent.maxX - extent.minX + 1 >= max(3, threshold) {
        shoulderY = y
        break
      }
    }
    guard let y = shoulderY, let extent = mask.rowExtent(y: y) else {
      return Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
    }

    // 「只有头」的遮罩在自己的最宽行上也满足 85% 规则，所以再要求肩线明显宽于头带：孩子的肩宽
    // 通常是头宽的 1.5–2.5 倍，取 1.6 倍做下限，低于它的不是肩线。
    let headBottom = min(mask.maxY, mask.minY + Int(Double(height) * 0.20))
    var headWidth = 0
    if headBottom >= mask.minY {
      for y in mask.minY...headBottom {
        guard let row = mask.rowExtent(y: y) else { continue }
        headWidth = max(headWidth, row.maxX - row.minX + 1)
      }
    }
    let width = extent.maxX - extent.minX + 1
    guard Double(width) >= Double(headWidth) * headToShoulderRatio else {
      return Estimate(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
    }

    // 端点取该行遮罩的左右边界：左端点 = 该行第一个遮罩格，右端点 = 该行最后一个。
    let left = mask.normalized(x: extent.minX, y: y)
    let right = mask.normalized(x: extent.maxX, y: y)

    let angle = lineAngleDeg(from: left, to: right)

    // 头部参考：优先鼻点；没有鼻点用遮罩头带（minY 到 0.35 * height）中点的 y。
    var headY: Double?
    if let head {
      headY = head.y
    } else {
      let headBottom = mask.minY + Int(Double(height) * 0.35) - 1
      guard headBottom >= mask.minY else {
        return Estimate(left: left, right: right, angleDeg: angle, aboveHead: nil, available: true)
      }
      headY = (Double((mask.minY + headBottom) / 2) + 0.5) / Double(mask.height)
    }
    // y 向下：肩线 y 更小 = 更高。
    let aboveHead = headY.map { left.y < $0 }

    return Estimate(left: left, right: right, angleDeg: angle, aboveHead: aboveHead, available: true)
  }
}
