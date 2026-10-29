import Foundation

/// Head pitch and roll read off a band of depth cells: `z = a·x + b·y + c` with x/y in normalized
/// image units.
///
/// This is the only orientation signal a depth map carries without a face model, so both joint
/// sources that need a pitch share it — `DepthJointSource` over its mask's top band, and the Vision
/// source over a band centred on the nose Vision measured. The vision source prefers its own eye-line
/// roll when both eyes are visible; the plane is the fallback.
struct HeadOrientation: Equatable {
  /// Positive when the bottom of the band sits farther from the camera than its top.
  var pitchDeg: Double
  /// Positive when the right side of the band is farther than its left.
  var rollDeg: Double

  /// A band whose own depth range is wider than `maximumSpread` is not a head (a sleeve, a chair
  /// back) and gives no orientation at all. Fewer than `minimumPoints` cells is noise.
  static func plane(in image: DepthImage,
                    band minY: Int,
                    _ maxY: Int,
                    mask: BodyMask?,
                    minimumPoints: Int = 24,
                    maximumSpread: Double = 0.35) -> HeadOrientation? {
    let minY = max(0, min(image.height - 1, minY))
    let maxY = max(minY, min(image.height - 1, maxY))
    guard image.width > 0, image.height > 0 else { return nil }

    var points: [(x: Double, y: Double, z: Double)] = []
    var zMin = Double.greatestFiniteMagnitude
    var zMax = -Double.greatestFiniteMagnitude
    for y in minY...maxY {
      for x in 0..<image.width where image.isValid(x: x, y: y) {
        if let mask, !mask.contains(x: x, y: y) { continue }
        let z = Double(image.value(x: x, y: y))
        points.append((Double(x) / Double(image.width), Double(y) / Double(image.height), z))
        zMin = min(zMin, z)
        zMax = max(zMax, z)
      }
    }
    guard points.count >= minimumPoints, zMax - zMin <= maximumSpread else { return nil }

    let count = Double(points.count)
    let meanX = points.map(\.x).reduce(0, +) / count
    let meanY = points.map(\.y).reduce(0, +) / count
    let meanZ = points.map(\.z).reduce(0, +) / count

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
    guard abs(determinant) > 1e-9 else { return nil }
    let a = (sxz * syy - syz * sxy) / determinant
    let b = (syz * sxx - sxz * sxy) / determinant

    let degrees = 180 / Double.pi
    return HeadOrientation(pitchDeg: atan(b) * degrees, rollDeg: atan(a) * degrees)
  }
}
