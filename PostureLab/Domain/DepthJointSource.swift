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
    static let neck = 0.25
    static let shoulder = 0.29
    static let root = 0.47
    static let hip = 0.68
  }

  init(options: DepthSegmentation.Options = DepthSegmentation.Options(), processingWidth: Int = 160) {
    self.options = options
    self.processingWidth = processingWidth
  }

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

    let neckY = row(Landmark.neck)
    let neckX = centreX(mask, y: neckY, fallback: headCentreX)
    joints[.neck] = joint(mask.normalized(x: neckX, y: neckY),
                          depth: medianDepth(image, mask: mask, x: neckX, y: neckY, radius: 2),
                          confidence: 0.85)

    let shoulderY = row(Landmark.shoulder)
    if let extent = mask.rowExtent(y: shoulderY), extent.maxX - extent.minX >= 2 {
      let leftDepth = medianDepth(image, mask: mask, x: extent.minX, y: shoulderY, radius: 1)
      let rightDepth = medianDepth(image, mask: mask, x: extent.maxX, y: shoulderY, radius: 1)
      joints[.leftShoulder] = joint(mask.normalized(x: extent.minX, y: shoulderY),
                                    depth: leftDepth, confidence: 0.8)
      joints[.rightShoulder] = joint(mask.normalized(x: extent.maxX, y: shoulderY),
                                     depth: rightDepth, confidence: 0.8)
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
    let orientation = HeadOrientation.plane(in: image,
                                            band: row(Landmark.headTop),
                                            row(Landmark.headBottom),
                                            mask: mask)

    return JointEstimate(joints: joints,
                         unavailable: unavailable,
                         cloud: cloud,
                         distanceCM: distanceCM,
                         pitchDeg: orientation?.pitchDeg,
                         rollDeg: orientation?.rollDeg,
                         mask: mask)
  }

  // MARK: - Landmark helpers

  private func joint(_ point: CGPointLike, depth: Float?, confidence: Double) -> JointSample {
    JointSample(x: point.x,
                y: point.y,
                depthM: depth.map { Double($0) },
                confidence: confidence)
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
}
