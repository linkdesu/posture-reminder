import Foundation

/// Joints measured from one TrueDepth frame, and nothing else.
///
/// The body is the largest near component of the depth frame (`DepthSegmentation`); the landmarks
/// are read off that mask's own geometry — its top, its shoulder line, its row widths — and each
/// joint's depth is the median depth under it. The head's pitch and roll come from a least-squares
/// plane through the head's depth cells, which is the only orientation signal a depth map carries
/// without a face model.
///
/// What is deliberately absent: eyes, ears, elbows and wrists. A depth map of a seated child does
/// not separate a wrist from a forearm or an eye from a brow, and inventing those joints would put
/// numbers on screen that no sensor measured. They are listed in `unavailable` instead.
final class DepthJointSource: JointSource {
  let identifier = "depth"

  private let options: DepthSegmentation.Options
  /// The width the segmentation runs at. TrueDepth hands over 320x240 (or larger); the body is large
  /// enough at 160 px that halving the work costs no landmark accuracy, and it keeps the 10 Hz
  /// pipeline comfortably inside a frame.
  private let processingWidth: Int

  /// Where each landmark sits vertically, as a fraction of the mask's own height. A seated child's
  /// head-to-hip span is what the mask covers, so these are fractions of the visible upper body, not
  /// of a standing figure.
  private enum Landmark {
    static let headCentre = 0.09
    static let headTop = 0.00
    static let headBottom = 0.20
    static let root = 0.47
    static let hip = 0.68
  }

  /// 肩线的判定约束。三条都要过，任何一条不过就说明这一帧的轮廓里没有可信的肩，双肩记为不可用，
  /// 而不是拿一个固定比例的行凑两个点出来。
  private enum Shoulder {
    /// 肩线要比颈部最窄处宽这么多倍，才算「脖子张开成肩膀」。
    static let widthJump = 1.6
    /// 肩宽 / 头宽 的合理区间。儿童肩宽约为头宽的 1.5–2.5 倍，留到 1.2–3.2 以容下轮廓误差。
    static let toHeadRange = 1.2...3.2
    /// 两肩三维距离的合理区间，米。超出这个范围的点落在耳朵或背景上，不是肩。
    static let spanRange = 0.20...0.45
  }

  init(options: DepthSegmentation.Options = DepthSegmentation.Options(), processingWidth: Int = 160) {
    self.options = options
    self.processingWidth = processingWidth
  }

  #if DEBUG
  /// 每个样本的肩部快照出口。只在 DEBUG 构建里存在，由 `DepthCaptureSource` 装上、测试与发布
  /// 构建都不装，所以领域层自己不做任何 I/O。
  var onDebugSample: ((JointDebugSample) -> Void)?
  #endif

  func estimate(from depth: DepthImage) -> JointEstimate {
    let image = depth.resampled(maxWidth: processingWidth)
    guard let mask = DepthSegmentation.segment(image, options: options) else {
      return .empty
    }

    let cloud = DepthCloud.points(mask: mask, image: image)
    var joints: [JointID: JointSample] = [:]
    let height = mask.maxY - mask.minY + 1
    let width = mask.maxX - mask.minX + 1
    guard height >= 8, width >= 3 else {
      return JointEstimate(joints: [:],
                           unavailable: Set(JointID.allCases),
                           cloud: cloud,
                           distanceCM: nil,
                           pitchDeg: nil,
                           rollDeg: nil,
                           mask: mask)
    }

    func row(_ fraction: Double) -> Int {
      min(mask.maxY, mask.minY + Int((fraction * Double(height - 1)).rounded()))
    }

    // The head is the mask's top band; its centre is the row's midpoint, so a turned head moves the
    // landmark without widening the box.
    let headY = row(Landmark.headCentre)
    let headExtent = mask.rowExtent(y: headY) ?? (mask.minX, mask.maxX)
    let headCentreX = (headExtent.minX + headExtent.maxX) / 2
    let headCentre = mask.normalized(x: headCentreX, y: headY)
    let headDepth = medianDepth(image, mask: mask, x: headCentreX, y: headY, radius: 2)
    joints[.nose] = joint(headCentre, depth: headDepth, confidence: 0.9)

    let headTop = row(Landmark.headTop)
    let headBottom = row(Landmark.headBottom)
    let headWidth = widestRow(mask: mask, from: headTop, through: headBottom)

    // The neck is the narrowest row between the head's bottom and 40% of the mask: the waist between
    // head and shoulders. A fixed fraction of the mask height drifts onto the ears as soon as the
    // child leans in and the mask is cut off at the chest; the narrowest row does not.
    let neck = neckRow(mask: mask, headBottom: headBottom)
    let neckX = centreX(mask, y: neck.row, fallback: headCentreX)
    joints[.neck] = joint(mask.normalized(x: neckX, y: neck.row),
                          depth: medianDepth(image, mask: mask, x: neckX, y: neck.row, radius: 2),
                          confidence: 0.85)

    // The shoulders are the first row below the neck whose width jumps — that jump is the neck
    // opening into the shoulder line. Both shoulder points must sit below the neck, the width must
    // stay plausible against the head, and the two points must be 20–45 cm apart in depth. Anything
    // else is left unavailable.
    if let shoulders = shoulderPoints(mask: mask,
                                      image: image,
                                      neck: neck,
                                      headWidth: headWidth,
                                      neckY: joints[.neck]?.y) {
      joints[.leftShoulder] = shoulders.left
      joints[.rightShoulder] = shoulders.right
    }

    let rootY = row(Landmark.root)
    let rootX = centreX(mask, y: rootY, fallback: headCentreX)
    joints[.root] = joint(mask.normalized(x: rootX, y: rootY),
                          depth: medianDepth(image, mask: mask, x: rootX, y: rootY, radius: 3),
                          confidence: 0.8)

    let hipY = row(Landmark.hip)
    if let extent = mask.rowExtent(y: hipY), extent.maxX - extent.minX >= 2,
       let neckToHip = joints[.neck]?.y, Double(hipY) / Double(image.height) > neckToHip {
      let y = mask.normalized(x: 0, y: hipY).y
      joints[.leftHip] = joint(CGPointLike(x: mask.normalized(x: extent.minX, y: hipY).x, y: y),
                               depth: medianDepth(image, mask: mask, x: extent.minX, y: hipY, radius: 1),
                               confidence: 0.6)
      joints[.rightHip] = joint(CGPointLike(x: mask.normalized(x: extent.maxX, y: hipY).x, y: y),
                                depth: medianDepth(image, mask: mask, x: extent.maxX, y: hipY, radius: 1),
                                confidence: 0.6)
    }

    let unavailable = Set(JointID.allCases).subtracting(joints.keys)

    let distanceCM = headDepth.map { Double($0) * 100 }
    let orientation = headOrientation(image, mask: mask,
                                      minY: row(Landmark.headTop),
                                      maxY: row(Landmark.headBottom))

    #if DEBUG
    emitDebugSample(image: image,
                    mask: mask,
                    joints: joints,
                    headWidth: headWidth)
    #endif

    return JointEstimate(joints: joints,
                         unavailable: unavailable,
                         cloud: cloud,
                         distanceCM: distanceCM,
                         pitchDeg: orientation?.pitchDeg,
                         rollDeg: orientation?.rollDeg,
                         mask: mask)
  }

  // MARK: - Landmark helpers

  #if DEBUG
  /// 把这一帧的颈部、双肩、肩距与头部范围交给调试日志。肩距用 `DepthCamera` 的假设内参换算成厘米。
  private func emitDebugSample(image: DepthImage,
                               mask: BodyMask,
                               joints: [JointID: JointSample],
                               headWidth: Int) {
    guard let onDebugSample else { return }
    let left = joints[.leftShoulder]
    let right = joints[.rightShoulder]
    let camera = DepthCamera()
    let span = left.flatMap { left in right.flatMap { right in camera.distance(left, right) } }

    onDebugSample(JointDebugSample(
      neck: joints[.neck],
      leftShoulder: left,
      rightShoulder: right,
      shoulderSpanCM: span.map { $0 * 100 },
      shouldersAvailable: left != nil && right != nil,
      headWidth: Double(headWidth) / Double(image.width),
      headTopY: mask.normalized(x: 0, y: mask.minY).y,
      headBottomY: mask.normalized(x: 0, y: min(mask.maxY, mask.minY + Int(0.20 * Double(mask.maxY - mask.minY)))).y,
      shoulderRowY: left?.y))
  }
  #endif

  private func joint(_ point: CGPointLike, depth: Float?, confidence: Double) -> JointSample {
    JointSample(x: point.x,
                y: point.y,
                depthM: depth.map { Double($0) },
                confidence: confidence)
  }

  /// The widest row between two rows of the mask, in pixels; 0 when neither row has a body pixel.
  private func widestRow(mask: BodyMask, from top: Int, through bottom: Int) -> Int {
    var widest = 0
    for y in min(top, bottom)...max(top, bottom) {
      guard let extent = mask.rowExtent(y: y) else { continue }
      widest = max(widest, extent.maxX - extent.minX + 1)
    }
    return widest
  }

  /// 颈部：头部下沿到轮廓 40% 高度之间最窄的一行。脖子是头与肩之间最细的地方，这个最窄处不会
  /// 随着孩子离镜头远近而漂到耳朵上。
  private func neckRow(mask: BodyMask, headBottom: Int) -> (row: Int, width: Int) {
    let height = mask.maxY - mask.minY
    let top = min(mask.maxY, max(headBottom, mask.minY))
    let bottom = min(mask.maxY, mask.minY + Int(0.40 * Double(height)))
    var best = (row: top, width: Int.max)
    for y in top...max(top, bottom) {
      guard let extent = mask.rowExtent(y: y) else { continue }
      let width = extent.maxX - extent.minX + 1
      if width < best.width { best = (y, width) }
    }
    return best.width == Int.max ? (top, 0) : best
  }

  /// 肩线：颈部往下第一行，宽度跳到颈部宽度的 `Shoulder.widthJump` 倍以上、且不窄于头宽。宽度
  /// 跳变就是「脖子张开成肩膀」的那一行；找不到就说明这一帧的轮廓里没有可用的肩。
  private func shoulderRow(mask: BodyMask,
                           neck: (row: Int, width: Int),
                           headWidth: Int) -> (row: Int, extent: (minX: Int, maxX: Int))? {
    let height = mask.maxY - mask.minY
    let start = min(mask.maxY, neck.row + max(1, Int(0.02 * Double(height))))
    let end = min(mask.maxY, mask.minY + Int(0.60 * Double(height)))
    guard start <= end else { return nil }
    let minimumWidth = max(Double(neck.width) * Shoulder.widthJump, Double(headWidth))
    for y in start...end {
      guard let extent = mask.rowExtent(y: y) else { continue }
      if Double(extent.maxX - extent.minX + 1) >= minimumWidth {
        return (y, extent)
      }
    }
    return nil
  }

  /// 双肩的最终判定：候选行要过「肩宽 / 头宽」与「两肩三维距离」两条约束，两个点还必须在颈部
  /// 以下。任何一条不过就返回 nil，调用方据此把双肩记为不可用。
  private func shoulderPoints(mask: BodyMask,
                              image: DepthImage,
                              neck: (row: Int, width: Int),
                              headWidth: Int,
                              neckY: Double?) -> (left: JointSample, right: JointSample)? {
    guard headWidth > 0,
          let candidate = shoulderRow(mask: mask, neck: neck, headWidth: headWidth),
          candidate.extent.maxX - candidate.extent.minX >= 2
    else { return nil }

    let width = Double(candidate.extent.maxX - candidate.extent.minX + 1)
    let ratio = width / Double(headWidth)
    guard Shoulder.toHeadRange.contains(ratio) else { return nil }

    let left = joint(mask.normalized(x: candidate.extent.minX, y: candidate.row),
                     depth: medianDepth(image, mask: mask,
                                        x: candidate.extent.minX, y: candidate.row, radius: 1),
                     confidence: 0.8)
    let right = joint(mask.normalized(x: candidate.extent.maxX, y: candidate.row),
                      depth: medianDepth(image, mask: mask,
                                         x: candidate.extent.maxX, y: candidate.row, radius: 1),
                      confidence: 0.8)

    guard let neckY, left.y > neckY, right.y > neckY else { return nil }
    guard let span = DepthCamera().distance(left, right),
          Shoulder.spanRange.contains(span) else { return nil }
    return (left, right)
  }

  /// The midpoint of the mask on one row; the head's centre when the row is empty.
  private func centreX(_ mask: BodyMask, y: Int, fallback: Int) -> Int {
    guard let extent = mask.rowExtent(y: y) else { return fallback }
    return (extent.minX + extent.maxX) / 2
  }

  /// Median depth of the mask pixels within `radius` of a landmark. Only mask pixels count, so a
  /// hole in the silhouette cannot pull a joint onto the background.
  private func medianDepth(_ image: DepthImage,
                           mask: BodyMask,
                           x: Int,
                           y: Int,
                           radius: Int) -> Float? {
    var values: [Float] = []
    for yy in (y - radius)...(y + radius) {
      for xx in (x - radius)...(x + radius) {
        guard mask.contains(x: xx, y: yy), image.isValid(x: xx, y: yy) else { continue }
        values.append(image.value(x: xx, y: yy))
      }
    }
    guard !values.isEmpty else { return nil }
    values.sort()
    return values[values.count / 2]
  }

  // MARK: - Head orientation

  private struct Orientation {
    var pitchDeg: Double
    var rollDeg: Double
  }

  /// A least-squares plane through the head band's depth cells: `z = a·x + b·y + c` with x/y in
  /// normalized image units. `b` is how much farther the bottom of the head sits than its top, so a
  /// head nodding down makes `b` negative and the pitch negative; `a` is the left-right slope and
  /// becomes the roll. Both are coarse: a face is not a plane, and the caller treats them as
  /// estimates. A band whose own depth range is wider than `maximumSpread` is not a head (a sleeve,
  /// a chair back) and gives no orientation at all.
  private func headOrientation(_ image: DepthImage,
                               mask: BodyMask,
                               minY: Int,
                               maxY: Int) -> Orientation? {
    var points: [(x: Double, y: Double, z: Double)] = []
    var zMin = Double.greatestFiniteMagnitude
    var zMax = -Double.greatestFiniteMagnitude
    for y in minY...maxY {
      for x in 0..<image.width where mask.contains(x: x, y: y) && image.isValid(x: x, y: y) {
        let z = Double(image.value(x: x, y: y))
        let point = mask.normalized(x: x, y: y)
        points.append((point.x, point.y, z))
        zMin = min(zMin, z)
        zMax = max(zMax, z)
      }
    }
    guard points.count >= 24, zMax - zMin <= 0.35 else { return nil }

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
    return Orientation(pitchDeg: atan(b) * degrees, rollDeg: atan(a) * degrees)
  }
}
