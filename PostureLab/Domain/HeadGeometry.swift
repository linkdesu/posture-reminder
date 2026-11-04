import Foundation

/// 深度图能给出的头部几何：头到相机的距离、俯仰、横滚。
///
/// 俯仰与横滚来自头部深度带上的一次最小二乘平面拟合 `z = a·x + b·y + c`（x/y 为归一化图像坐标）：
/// `b` 是头部下沿比上沿远多少，点头让 `b` 变负、俯仰为负；`a` 是左右坡度，就是横滚。两者都是粗测，
/// 脸不是平面；深度跨度超过 `maximumSpread` 的那一带不是头（袖口、椅背），宁可不给读数。
///
/// 彩色一侧的眼线/耳线更准，但只有 Vision 有；这里的读数是每一帧都有的兜底，也是「人还在不在」
/// 的依据——它不依赖关节是否新鲜。
enum HeadGeometry {
  struct Reading: Equatable {
    /// 头到相机的距离，厘米。
    var distanceCM: Double?
    /// 相对水平面的俯仰角，度；正数表示下巴上扬。
    var pitchDeg: Double?
    /// 相对水平面的横滚角，度。
    var rollDeg: Double?
  }

  struct Orientation: Equatable {
    var pitchDeg: Double
    var rollDeg: Double
  }

  /// 头部在轮廓里占的高度比例：头是分割结果最上面那一带，20% 足够容下头顶到下巴，又不会把肩带进来。
  static let headBandFraction = 0.20
  /// 平面拟合至少需要这么多格点，否则退化成一个点或一条线。
  static let minimumPoints = 24
  /// 一带深度自己跨过的距离上限，米。超过它说明这一带不是一张脸。
  static let maximumSpread: Float = 0.35

  static func measure(depth: DepthImage, mask: BodyMask?) -> Reading {
    guard let mask, mask.count > 0 else { return Reading(distanceCM: nil, pitchDeg: nil, rollDeg: nil) }
    let band = headBand(mask)
    let orientation = plane(in: depth, mask: mask, rows: band)
    let distance = bandMedian(depth, mask: mask, rows: band)
    return Reading(distanceCM: distance.map { Double($0) * 100 },
                   pitchDeg: orientation?.pitchDeg,
                   rollDeg: orientation?.rollDeg)
  }

  /// 头部深度带里属于人的深度中位数，米。只数遮罩内的格子：背景的 2 米墙不能参与，否则距离会被
  /// 拉远，`near` 与 `head_forward` 都会跟着错。
  static func bandMedian(_ depth: DepthImage, mask: BodyMask, rows: ClosedRange<Int>) -> Float? {
    let minRow = max(0, rows.lowerBound)
    let maxRow = min(depth.height - 1, rows.upperBound)
    guard minRow <= maxRow else { return nil }
    var values: [Float] = []
    values.reserveCapacity((maxRow - minRow + 1) * 16)
    for y in minRow...maxRow where y >= mask.minY && y <= mask.maxY {
      for x in mask.minX...mask.maxX where mask.contains(x: x, y: y) && depth.isValid(x: x, y: y) {
        values.append(depth.value(x: x, y: y))
      }
    }
    guard !values.isEmpty else { return nil }
    values.sort()
    return values[values.count / 2]
  }

  /// 头部深度带的行区间（像素行）。轮廓太矮时整块都算头。
  static func headBand(_ mask: BodyMask) -> ClosedRange<Int> {
    let height = mask.maxY - mask.minY
    let bottom = mask.minY + Int((headBandFraction * Double(max(0, height))).rounded())
    return min(mask.maxY, max(mask.minY, bottom)) >= mask.minY
      ? mask.minY...min(mask.maxY, max(mask.minY, bottom))
      : mask.minY...mask.minY
  }

  /// 行区间内所有属于人（有遮罩且深度有效）的格点的最小二乘平面。点太少或深度跨度太大时返回 nil。
  static func plane(in depth: DepthImage, mask: BodyMask?, rows: ClosedRange<Int>) -> Orientation? {
    let minRow = max(0, rows.lowerBound)
    let maxRow = min(depth.height - 1, rows.upperBound)
    guard minRow <= maxRow else { return nil }

    var points: [(x: Double, y: Double, z: Double)] = []
    var zMin = Double.greatestFiniteMagnitude
    var zMax = -Double.greatestFiniteMagnitude
    for y in minRow...maxRow {
      for x in 0..<depth.width {
        if let mask, !mask.contains(x: x, y: y) { continue }
        guard depth.isValid(x: x, y: y) else { continue }
        let z = Double(depth.value(x: x, y: y))
        points.append((Double(x) / Double(depth.width), Double(y) / Double(depth.height), z))
        zMin = min(zMin, z)
        zMax = max(zMax, z)
      }
    }
    guard points.count >= minimumPoints, Float(zMax - zMin) <= maximumSpread else { return nil }

    let count = Double(points.count)
    let meanX = points.reduce(0) { $0 + $1.x } / count
    let meanY = points.reduce(0) { $0 + $1.y } / count
    let meanZ = points.reduce(0) { $0 + $1.z } / count

    var sxx = 0.0
    var sxy = 0.0
    var syy = 0.0
    var sxz = 0.0
    var syz = 0.0
    for point in points {
      let dx = point.x - meanX
      let dy = point.y - meanY
      let dz = point.z - meanZ
      sxx += dx * dx
      sxy += dx * dy
      syy += dy * dy
      sxz += dx * dz
      syz += dy * dz
    }
    let determinant = sxx * syy - sxy * sxy
    guard abs(determinant) > 1e-12 else { return nil }
    let a = (sxz * syy - syz * sxy) / determinant
    let b = (syz * sxx - sxz * sxy) / determinant

    let degrees = 180 / Double.pi
    return Orientation(pitchDeg: atan(b) * degrees, rollDeg: atan(a) * degrees)
  }
}
