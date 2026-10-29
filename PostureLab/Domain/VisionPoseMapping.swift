import Foundation

/// One joint as a pose model reported it, in the app's joint space: `x`/`y` normalized 0...1 with the
/// origin at the image's upper left, `confidence` the model's own score.
///
/// The Vision observation itself lives in `VisionJointSource`; this type is the plain seam the
/// mapping is tested through, so a unit test can construct a pose without a camera or a photo.
struct VisionPosePoint: Equatable {
  var joint: JointID
  var x: Double
  var y: Double
  var confidence: Double
}

/// Turns a model's 2D joints plus the depth frame captured with them into a `JointEstimate`.
///
/// The depth frame is used exactly as the depth build uses it, and for the same two things: the body
/// mask (which is what the point cloud is sampled from) and each joint's distance. The joints own
/// the 2D geometry; the depth map only answers "how far away is that pixel". No colour pixel is read
/// here at all — the caller has already turned the model's output into `VisionPosePoint`s and dropped
/// the frame.
enum VisionPoseMapping {
  /// Below this score the model is guessing; the joint is reported unavailable instead.
  static let minimumConfidence = 0.3

  /// The band around the nose the depth plane is fitted over, as a fraction of the image height.
  /// Wide enough for the forehead and chin, narrow enough that shoulders do not enter the fit.
  private static let pitchBandAbove = 0.10
  private static let pitchBandBelow = 0.08

  static func estimate(points: [VisionPosePoint], depth: DepthImage) -> JointEstimate {
    let mask = DepthSegmentation.segment(depth)
    let cloud = mask.map { DepthCloud.points(mask: $0, image: depth) } ?? []

    // One joint per name, keeping the model's more confident reading if it reports two.
    var byJoint: [JointID: VisionPosePoint] = [:]
    for point in points where point.confidence >= minimumConfidence {
      if let existing = byJoint[point.joint], existing.confidence >= point.confidence { continue }
      byJoint[point.joint] = point
    }

    var joints: [JointID: JointSample] = [:]
    for (id, point) in byJoint {
      joints[id] = JointSample(x: point.x,
                               y: point.y,
                               depthM: jointDepth(depth, mask: mask, x: point.x, y: point.y),
                               confidence: point.confidence)
    }

    let faceDepths = [JointID.nose, .leftEye, .rightEye, .leftEar, .rightEar]
      .compactMap { joints[$0]?.depthM }
    let distanceCM = (joints[.nose]?.depthM ?? median(faceDepths)).map { $0 * 100 }

    let orientation = orientation(joints: joints, depth: depth, mask: mask)

    return JointEstimate(joints: joints,
                         unavailable: Set(JointID.allCases).subtracting(joints.keys),
                         cloud: cloud,
                         distanceCM: distanceCM,
                         pitchDeg: orientation?.pitchDeg,
                         rollDeg: orientation?.rollDeg,
                         mask: mask)
  }

  /// Converts a Vision joint — normalized, origin at the lower left — into the app's joint space.
  ///
  /// `portrait` describes the buffer the model saw. The capture graph asks for portrait buffers; a
  /// device that refuses the rotation hands over a landscape buffer whose upright view is a quarter
  /// turn away, and Vision is told `.right` for that case, so its normalized `x` runs along the
  /// portrait vertical.
  static func imagePoint(x: Double, y: Double, portrait: Bool) -> CGPointLike {
    if portrait {
      return CGPointLike(x: x, y: 1 - y)
    }
    return CGPointLike(x: y, y: x)
  }

  // MARK: - Depth under a joint

  /// Median distance of the body's depth cells around a joint, or nil when the joint sits off the
  /// body mask. Mask cells only: without a body in the depth frame there is no distance to report,
  /// and a limb the segmentation left out gets no depth rather than the background's. `hand_to_face`
  /// and the 2D metrics do not need it; `distance` and `head_forward` correctly stay missing.
  private static func jointDepth(_ depth: DepthImage, mask: BodyMask?, x: Double, y: Double) -> Double? {
    guard let mask else { return nil }
    let px = min(depth.width - 1, max(0, Int(x * Double(depth.width))))
    let py = min(depth.height - 1, max(0, Int(y * Double(depth.height))))
    let radius = max(1, min(3, depth.width / 80))

    var values: [Float] = []
    for yy in (py - radius)...(py + radius) {
      for xx in (px - radius)...(px + radius)
      where mask.contains(x: xx, y: yy) && depth.isValid(x: xx, y: yy) {
        values.append(depth.value(x: xx, y: yy))
      }
    }
    guard !values.isEmpty else { return nil }
    values.sort()
    return Double(values[values.count / 2])
  }

  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }

  // MARK: - Head orientation

  /// Roll from the eye line when both eyes are measured — a 2D reading a depth map cannot give — and
  /// pitch from a least-squares plane through the depth band around the nose, the same estimator the
  /// depth build uses. A frame with the depth plane unavailable still reports its roll, and a frame
  /// with no eyes still reports its pitch.
  private static func orientation(joints: [JointID: JointSample],
                                  depth: DepthImage,
                                  mask: BodyMask?) -> (pitchDeg: Double?, rollDeg: Double?)? {
    var pitchDeg: Double?
    if let nose = joints[.nose] {
      let centre = Int(nose.y * Double(depth.height))
      let band = Int(Double(depth.height) * pitchBandAbove)
      let below = Int(Double(depth.height) * pitchBandBelow)
      pitchDeg = HeadOrientation.plane(in: depth,
                                      band: centre - band,
                                      centre + below,
                                      mask: mask)?.pitchDeg
    }

    var rollDeg: Double?
    if let left = joints[.leftEye], let right = joints[.rightEye],
       hypot(right.x - left.x, right.y - left.y) > 0.01 {
      rollDeg = atan2(right.y - left.y, right.x - left.x) * 180 / .pi
    } else if let nose = joints[.nose] {
      let centre = Int(nose.y * Double(depth.height))
      let band = Int(Double(depth.height) * pitchBandAbove)
      let below = Int(Double(depth.height) * pitchBandBelow)
      rollDeg = HeadOrientation.plane(in: depth,
                                     band: centre - band,
                                     centre + below,
                                     mask: mask)?.rollDeg
    }

    guard pitchDeg != nil || rollDeg != nil else { return nil }
    return (pitchDeg, rollDeg)
  }
}
