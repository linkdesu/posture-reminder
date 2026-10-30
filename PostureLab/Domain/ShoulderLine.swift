import Foundation

/// 一条肩线的读数（只用 Vision 肩点；0.6.8 (17) 起不再用深度遮罩估肩线）。
///
/// 端点、角度与「是否高于头部」都进 `joints-*.jsonl`，供 QA 核对肩线是否落在身上。
struct ShoulderLine: Equatable {
  var left: CGPointLike?
  var right: CGPointLike?
  /// 肩线与水平线的夹角，折进 (−90°, 90°]；端点不足时 nil。
  var angleDeg: Double?
  /// 肩线是否高于鼻点（y 更小 = 更高）；缺端点或缺鼻点时 nil。
  var aboveHead: Bool?
  var available: Bool

  static var unavailable: ShoulderLine {
    ShoulderLine(left: nil, right: nil, angleDeg: nil, aboveHead: nil, available: false)
  }

  /// 由两个肩点与鼻点算出整条读数。
  static func make(left: JointSample?, right: JointSample?, nose: JointSample?) -> ShoulderLine {
    guard let left, let right else { return .unavailable }
    let from = CGPointLike(x: left.x, y: left.y)
    let to = CGPointLike(x: right.x, y: right.y)
    var angle: Double?
    if hypot(to.x - from.x, to.y - from.y) > 0.01 {
      var raw = atan2(to.y - from.y, to.x - from.x) * 180 / .pi
      if raw > 90 { raw = 180 - raw }
      if raw < -90 { raw = -180 - raw }
      angle = raw
    }
    let above = nose.map { (left.y + right.y) / 2 < $0.y }
    return ShoulderLine(left: from, right: to, angleDeg: angle, aboveHead: above, available: true)
  }
}
