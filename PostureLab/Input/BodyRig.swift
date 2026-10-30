import Foundation

/// The pose the fake body strikes. One per `PostureKind`, plus the neutral `upright`, the empty
/// `absent` frame, and a "just short of the threshold" twin for the postures that need a
/// counter-example.
enum BodyPose: String, CaseIterable, Equatable {
  case upright
  case near
  case headDown
  case headTilt
  case shoulderTilt
  case deskLean
  case chinRest
  case headForward
  case slouch
  case absent

  /// The "just short of the threshold" version of a posture, for AC17's counter-examples.
  case nearMissDistance
  case nearMissHeadDown
  case nearMissHeadTilt
  case nearMissShoulderTilt
  case nearMissDeskLean
  case nearMissChinRest
  case nearMissHeadForward
  case nearMissSlouch
}

/// Poses a `BodyPose` into joints plus one coarse depth frame. Pure and deterministic: the same pose
/// and the same distance always give the same geometry, so a scripted scenario replays exactly.
///
/// Every pose is built from two hard-coded anchors, and both come from the *medium* sensitivity
/// table — the table QA replays and the one the classifier tests measure against:
///
/// - a counter-example (`nearMiss…`) sits at 0.8x a medium threshold, so it stays just inside it;
/// - a positive pose clears the medium threshold.
///
/// Pinning the anchors to medium does not make them a medium-only artefact, because
/// `PostureThresholds.forSensitivity` reads the level into exactly two thresholds, `distanceCM` and
/// pitchDeg`, and leaves the other six constant at all three levels. None of the six
/// counter-examples AC17 runs — `headTilt`, `shoulderTilt`, `deskLean`, `chinRest`, `headForward`,
/// `slouch` — reaches its own posture's threshold at `low` or `high` either, and the desk-lean one
/// never even consults the pitch half of its rule: it stops at the fixed 0.10 head-height drop. The
/// corollary is the part worth remembering: the three-level setting changes nothing for six of the
/// eight postures, whose deciding threshold is constant, and only reaches `near` (distance),
/// `headDown` (pitch) and the `2 x pitchDeg` deep-dip gate inside the desk-lean rule. Whether the
/// other six thresholds should scale with the level too is an open question in
/// `tmp/handoff/omp-questions.md`.
enum BodyRig {

  /// Normalized image coordinates (0...1, y downwards) and metres to the camera. `distanceCM` is the
  /// face-to-screen distance the script reports; it is deliberately *not* folded into the geometry.
  /// The classifier reads `headForward` off head depth, so pulling a `near` frame's head towards the
  /// camera would report head-forward on every close frame. Proximity travels in the sample's
  /// `distanceCM`; only `.headForward` and `.deskLean` move the head's depth.
  static func geometry(_ pose: BodyPose, distanceCM: Double?) -> PoseGeometry {
    guard pose != .absent else { return PoseGeometry(joints: [:], depth: nil) }

    var posed = uprightSkeleton()
    apply(pose, to: &posed)

    var joints: [JointID: JointSample] = [:]
    for id in JointID.allCases {
      guard let placement = posed[id] else { continue }
      joints[id] = JointSample(x: placement.x,
                               y: placement.y,
                               depthM: placement.depthM,
                               confidence: 1)
    }
    return PoseGeometry(joints: joints, depth: depthFrame(joints))
  }

  // MARK: - The reference layout

  /// One joint while a pose is being applied. Every rig joint carries a depth, so the posing helpers
  /// never have to deal with a missing one.
  private struct Placement {
    var x: Double
    var y: Double
    var depthM: Double
  }

  private static let centreX = 0.50
  private static let neckY = 0.40
  private static let shoulderY = 0.42

  private static let head: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
  private static let shoulders: [JointID] = [.leftShoulder, .rightShoulder]

  /// The neutral skeleton the classifier's reference baseline is built from: nose at y 0.30, head
  /// 0.35 m out, shoulder line 0.20 wide, neck to root 0.20. Those four are read from
  /// `PostureBaseline` itself, so the rig and the baseline cannot drift apart.
  private static func uprightSkeleton() -> [JointID: Placement] {
    let headY = PostureBaseline.uprightHeadHeight
    let headDepth = PostureBaseline.uprightHeadDepthM
    let halfShoulder = PostureBaseline.uprightShoulderWidth / 2
    let rootY = neckY + PostureBaseline.uprightNeckToRoot

    return [
      .nose: Placement(x: centreX, y: headY, depthM: headDepth),
      .leftEye: Placement(x: centreX - 0.03, y: headY - 0.01, depthM: headDepth),
      .rightEye: Placement(x: centreX + 0.03, y: headY - 0.01, depthM: headDepth),
      .leftEar: Placement(x: centreX - 0.06, y: headY, depthM: headDepth),
      .rightEar: Placement(x: centreX + 0.06, y: headY, depthM: headDepth),
      .neck: Placement(x: centreX, y: neckY, depthM: 0.38),
      .leftShoulder: Placement(x: centreX - halfShoulder, y: shoulderY, depthM: 0.42),
      .rightShoulder: Placement(x: centreX + halfShoulder, y: shoulderY, depthM: 0.42),
      .leftElbow: Placement(x: 0.36, y: 0.55, depthM: 0.48),
      .rightElbow: Placement(x: 0.64, y: 0.55, depthM: 0.48),
      .leftWrist: Placement(x: 0.34, y: 0.66, depthM: 0.50),
      .rightWrist: Placement(x: 0.66, y: 0.66, depthM: 0.50),
      .root: Placement(x: centreX, y: rootY, depthM: 0.58),
      .leftHip: Placement(x: 0.43, y: 0.72, depthM: 0.60),
      .rightHip: Placement(x: 0.57, y: 0.72, depthM: 0.60),
    ]
  }

  // MARK: - Poses

  /// The medium threshold table the pose deltas are measured against.
  private static let medium = PostureThresholds.forSensitivity(.medium)
  private static let nearMissFactor = 0.8
  private static let positiveFactor = 1.5

  /// The positive deltas the layout table states outright: one hand rests 0.06 from the nose, the
  /// head comes 0.06 m closer than the baseline, a slouch narrows both torso proxies by 15%, and the
  /// desk-lean head ends up 0.42 below the baseline and 0.18 m from the camera.
  private static let chinRestGap = 0.06
  private static let chinRestWristDepthM = 0.33
  private static let headForwardM = 0.06
  private static let slouchRatio = 0.15
  /// Metres of forward travel per unit of the slouch ratio.
  private static let slouchShoulderForward = 0.15
  private static let deskLeanHeadDrop = 0.42
  private static let deskLeanHeadDepthM = 0.18
  private static let deskLeanShoulderDrop = 0.10
  private static let deskLeanShoulderDepthM = 0.30
  private static let nearMissDeskLeanShoulderDrop = 0.02
  private static let nearMissDeskLeanShoulderDepthM = 0.32

  private static func apply(_ pose: BodyPose, to posed: inout [JointID: Placement]) {
    switch pose {
    // The neutral poses and the proximity ones. A `near` body looks like an upright body — its
    // closeness lives in the sample's `distanceCM` — and `nearMissDistance` is that same pose, its
    // counter-example being the 37.5 cm the scenario reports.
    case .upright, .near, .nearMissDistance, .absent:
      return

    case .headDown:
      move(head, dy: positiveFactor * medium.headHeightDrop, in: &posed)
    case .nearMissHeadDown:
      move(head, dy: nearMissFactor * medium.headHeightDrop, in: &posed)

    case .headTilt:
      tiltHead(rollDeg: positiveFactor * medium.rollDeg, in: &posed)
    case .nearMissHeadTilt:
      tiltHead(rollDeg: nearMissFactor * medium.rollDeg, in: &posed)

    case .shoulderTilt:
      tiltShoulders(degrees: positiveFactor * medium.shoulderTiltDeg, in: &posed)
    case .nearMissShoulderTilt:
      tiltShoulders(degrees: nearMissFactor * medium.shoulderTiltDeg, in: &posed)

    case .deskLean:
      // Face down on the desk: the head group drops the whole way and comes much closer to the
      // camera, the shoulders follow it down, and the elbows spread out to both sides.
      move(head, dy: deskLeanHeadDrop, in: &posed)
      setDepth(deskLeanHeadDepthM, of: head, in: &posed)
      move(shoulders, dy: deskLeanShoulderDrop, in: &posed)
      setDepth(deskLeanShoulderDepthM, of: shoulders, in: &posed)
      place(.leftElbow, x: 0.26, y: 0.60, in: &posed)
      place(.rightElbow, x: 0.74, y: 0.60, in: &posed)
      place(.leftWrist, x: 0.24, y: 0.68, in: &posed)
      place(.rightWrist, x: 0.76, y: 0.68, in: &posed)

    case .nearMissDeskLean:
      // The same lean, stopped short: the head is 0.08 below the baseline against a 0.10 threshold,
      // and 0.04 m closer than the baseline head depth against headForward's 0.05.
      move(head, dy: nearMissFactor * medium.headHeightDrop, in: &posed)
      setDepth(PostureBaseline.uprightHeadDepthM - nearMissFactor * medium.headForwardM,
               of: head, in: &posed)
      move(shoulders, dy: nearMissDeskLeanShoulderDrop, in: &posed)
      setDepth(nearMissDeskLeanShoulderDepthM, of: shoulders, in: &posed)
      place(.leftElbow, x: 0.31, y: 0.565, in: &posed)
      place(.rightElbow, x: 0.69, y: 0.565, in: &posed)
      place(.leftWrist, x: 0.29, y: 0.67, in: &posed)
      place(.rightWrist, x: 0.71, y: 0.67, in: &posed)

    case .chinRest, .nearMissChinRest:
      // One wrist comes up under the nose: 0.06 away for the positive, 0.10 / 0.8 = 0.125 for the
      // counter-example, which is just outside the 0.10 hand-to-face threshold. The forearm follows
      // so the overlay's skeleton stays plausible; no feature reads the elbow.
      let gap = pose == .chinRest ? chinRestGap : medium.handToFace / nearMissFactor
      guard let nose = posed[.nose] else { return }
      place(.rightWrist, x: nose.x, y: nose.y + gap, in: &posed)
      setDepth(chinRestWristDepthM, of: [.rightWrist], in: &posed)
      place(.rightElbow, x: 0.56, y: 0.50, in: &posed)

    case .headForward:
      setDepth(PostureBaseline.uprightHeadDepthM - headForwardM, of: head, in: &posed)
    case .nearMissHeadForward:
      setDepth(PostureBaseline.uprightHeadDepthM - nearMissFactor * medium.headForwardM,
               of: head, in: &posed)

    case .slouch, .nearMissSlouch:
      // Narrower shoulders and a shorter neck-to-root, both by the same ratio. The classifier takes
      // the larger of the two proxies, so pinning both to `r` makes its reading exactly `r`.
      let r = pose == .slouch ? slouchRatio : nearMissFactor * medium.slouchRatio
      let halfShoulder = PostureBaseline.uprightShoulderWidth / 2
      let sink = PostureBaseline.uprightNeckToRoot * r
      let forward = slouchShoulderForward * r
      move([.leftShoulder], dx: halfShoulder * r, dy: sink, depth: -forward, in: &posed)
      move([.rightShoulder], dx: -halfShoulder * r, dy: sink, depth: -forward, in: &posed)
      move([.neck], dy: sink, in: &posed)
    }
  }

  /// Rotates the head about the neck, leaving the shoulder line level. The head roll feature itself
  /// comes from the sample's reported `rollDeg`; this keeps the drawn skeleton agreeing with it
  /// without tripping the separate shoulder-tilt feature.
  private static func tiltHead(rollDeg: Double, in posed: inout [JointID: Placement]) {
    guard let neck = posed[.neck] else { return }
    let roll = rollDeg * .pi / 180
    let sinRoll = sin(roll)
    let cosRoll = cos(roll)
    for id in head {
      guard var joint = posed[id] else { continue }
      let dx = joint.x - neck.x
      let dy = joint.y - neck.y
      joint.x = neck.x + dx * cosRoll - dy * sinRoll
      joint.y = neck.y + dx * sinRoll + dy * cosRoll
      posed[id] = joint
    }
  }

  /// Rotates the shoulder line about its centre, leaving the head square. Half the line moves down
  /// and half up by `halfWidth * sin(angle)`, which leaves the width alone (so no other proxy that
  /// reads the shoulder span moves) and puts the line `atan(sin angle)` off horizontal — 14.51° for
  /// the positive's 15° and 7.92° for the counter-example's 8°, both still on the right side of the
  /// 10° medium threshold.
  private static func tiltShoulders(degrees: Double, in posed: inout [JointID: Placement]) {
    let drop = (PostureBaseline.uprightShoulderWidth / 2) * sin(degrees * .pi / 180)
    move([.rightShoulder], dy: drop, in: &posed)
    move([.leftShoulder], dy: -drop, in: &posed)
  }

  private static func move(_ ids: [JointID],
                           dx: Double = 0,
                           dy: Double = 0,
                           depth: Double = 0,
                           in posed: inout [JointID: Placement]) {
    for id in ids {
      guard var joint = posed[id] else { continue }
      joint.x += dx
      joint.y += dy
      joint.depthM += depth
      posed[id] = joint
    }
  }

  /// Places a joint, leaving its depth alone.
  private static func place(_ id: JointID,
                            x: Double,
                            y: Double,
                            in posed: inout [JointID: Placement]) {
    guard var joint = posed[id] else { return }
    joint.x = x
    joint.y = y
    posed[id] = joint
  }

  private static func setDepth(_ depthM: Double,
                              of ids: [JointID],
                              in posed: inout [JointID: Placement]) {
    for id in ids {
      guard var joint = posed[id] else { continue }
      joint.depthM = depthM
      posed[id] = joint
    }
  }

  // MARK: - Depth

  /// Wide enough for a joint to reach its neighbours on a 24 by 32 grid, narrow enough to keep the
  /// wells apart.
  private static let wellSigma = 0.06

  /// One depth frame from the posed joints: a gaussian well per joint, centred on the joint's
  /// normalized position with that joint's depth at the middle of the well, and a window that fades
  /// to 0 — "no reading" — at the frame's edges.
  private static func depthFrame(_ joints: [JointID: JointSample]) -> DepthFrame {
    var metres = [Float](repeating: 0, count: DepthFrame.width * DepthFrame.height)

    for y in 0..<DepthFrame.height {
      let cy = (Double(y) + 0.5) / Double(DepthFrame.height)
      for x in 0..<DepthFrame.width {
        let cx = (Double(x) + 0.5) / Double(DepthFrame.width)
        var weightedDepth = 0.0
        var totalWeight = 0.0
        // `allCases` order rather than dictionary order: a dictionary's own order is not stable, and
        // the same pose has to produce the same bits every time.
        for id in JointID.allCases {
          guard let joint = joints[id], let depth = joint.depthM else { continue }
          let dx = cx - joint.x
          let dy = cy - joint.y
          let weight = exp(-(dx * dx + dy * dy) / (2 * wellSigma * wellSigma))
          weightedDepth += weight * depth
          totalWeight += weight
        }
        guard totalWeight > 0 else { continue }
        let edge = sin(.pi * cx) * sin(.pi * cy)
        metres[y * DepthFrame.width + x] = Float(edge * weightedDepth / totalWeight)
      }
    }

    return DepthFrame(metres: metres)
  }
}
