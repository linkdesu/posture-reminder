import Foundation

/// Builds a 3D point cloud that has the shape of the body the joints describe.
///
/// The points sit on three volumes derived from the joints — a head ellipsoid, a torso tube from the
/// neck to the hips that narrows at the waist, and one capsule per upper arm from the shoulder
/// through the elbow to the wrist — rather than on the depth frame, so the cloud covers the figure
/// instead of the whole screen.
///
/// `points(for:)` is pure and deterministic: every volume is sampled on a fixed grid, in a fixed
/// order, from the joints alone. The same joints always give the same points, and no joints give
/// none.
enum BodyCloud {
  /// Every point the available joints can place. A frame missing a limb loses that volume rather
  /// than inventing one; a frame with no joints at all gives an empty cloud.
  static func points(for joints: [JointID: JointSample]) -> [BodyPoint] {
    guard !joints.isEmpty else { return [] }

    var points: [BodyPoint] = []
    points.append(contentsOf: headPoints(joints))
    points.append(contentsOf: torsoPoints(joints))
    for chain in armChains {
      points.append(contentsOf: armPoints(joints, chain: chain))
    }
    return points
  }

  // MARK: - Space

  /// Normalized x spans the frame's width and y its height, and the grid is 3:4. The volumes are
  /// built in a space whose x is pre-multiplied by this ratio, so a circle in the maths is a circle
  /// on screen, and converted back on the way out.
  private static let aspect = Double(DepthFrame.width) / Double(DepthFrame.height)

  /// A point while a volume is being sampled: x in the aspect-corrected space, y normalized, z in
  /// metres.
  private struct Vector {
    var x: Double
    var y: Double
    var z: Double
  }

  private static func mixed(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * min(1, max(0, t))
  }

  /// A slow-in, slow-out ramp, so the torso swells instead of stepping between radii.
  private static func smoothstep(_ t: Double) -> Double {
    let clamped = min(1, max(0, t))
    return clamped * clamped * (3 - 2 * clamped)
  }

  private static func length(_ vector: Vector) -> Double {
    (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z).squareRoot()
  }

  private static func normalized(_ vector: Vector) -> Vector {
    let magnitude = length(vector)
    guard magnitude > 1e-9 else { return Vector(x: 0, y: 1, z: 0) }
    return Vector(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
  }

  private static func cross(_ a: Vector, _ b: Vector) -> Vector {
    Vector(x: a.y * b.z - a.z * b.y,
           y: a.z * b.x - a.x * b.z,
           z: a.x * b.y - a.y * b.x)
  }

  private static func averageDepth(_ samples: [JointSample], fallback: Double) -> Double {
    let depths = samples.compactMap(\.depthM)
    guard !depths.isEmpty else { return fallback }
    return depths.reduce(0, +) / Double(depths.count)
  }

  // MARK: - Head

  private static let headJoints: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
  private static let headLatitudes = 10
  private static let headLongitudes = 12
  /// The smallest head the face joints are allowed, in normalized x: a frame with a tight ear line
  /// still gets a head rather than a pea.
  private static let minimumHeadHalfWidth = 0.07

  /// An ellipsoid around the face joints. Its half-width follows how far apart they sit — the ear
  /// line is the widest part of a face — and its height is a little more than its width, so the head
  /// comes out a head on screen rather than a tall oval.
  private static func headPoints(_ joints: [JointID: JointSample]) -> [BodyPoint] {
    let samples = headJoints.compactMap { joints[$0] }
    guard !samples.isEmpty else { return [] }

    let centreX = samples.map(\.x).reduce(0, +) / Double(samples.count)
    let centreY = samples.map(\.y).reduce(0, +) / Double(samples.count)
    let halfWidth = max(minimumHeadHalfWidth,
                        (samples.map { abs($0.x - centreX) }.max() ?? 0) * 1.5)
    let centreZ = averageDepth(samples, fallback: 0.35)

    let rx = halfWidth * aspect
    let ry = rx * 1.15
    let rz = rx

    var points: [BodyPoint] = []
    points.reserveCapacity(headLatitudes * headLongitudes + 2)
    for latitude in 0..<headLatitudes {
      // The latitudinal rings stop just short of the poles; the two pole points below close them.
      let phi = -Double.pi / 2 + (Double(latitude) + 0.5) / Double(headLatitudes) * Double.pi
      let ring = cos(phi)
      for longitude in 0..<headLongitudes {
        let theta = Double(longitude) / Double(headLongitudes) * 2 * Double.pi
        points.append(BodyPoint(x: centreX + rx * ring * cos(theta) / aspect,
                                y: centreY + ry * sin(phi),
                                z: centreZ + rz * ring * sin(theta)))
      }
    }
    points.append(BodyPoint(x: centreX, y: centreY - ry, z: centreZ))
    points.append(BodyPoint(x: centreX, y: centreY + ry, z: centreZ))
    return points
  }

  // MARK: - Torso

  private static let torsoRingCount = 16
  private static let torsoSegments = 20
  /// The torso is wider than it is deep, so the ring is an ellipse squashed front to back.
  private static let torsoDepthRatio = 0.62
  private static let torsoHipRatio = 0.80
  private static let torsoDropWithoutHips = 0.30
  private static let torsoNeckLift = 0.02
  private static let waistInset = 0.82
  private static let waistAt = 0.55

  /// A tube from the neck to the hips. The spine is the straight line between them and the radius
  /// follows a top-to-waist-to-hip profile, so the middle of the tube is visibly pinched.
  private static func torsoPoints(_ joints: [JointID: JointSample]) -> [BodyPoint] {
    guard let neck = torsoTop(joints) else { return [] }

    let shoulders = [joints[.leftShoulder], joints[.rightShoulder]].compactMap { $0 }
    let halfShoulder = shoulders.isEmpty
      ? halfShoulderFallback
      : max(0.06, shoulders.map { abs($0.x - neck.x) }.max() ?? halfShoulderFallback)
    let topRadius = halfShoulder * aspect

    let hips = [joints[.leftHip], joints[.rightHip]].compactMap { $0 }
    let hipX: Double
    let hipY: Double
    let hipZ: Double
    if !hips.isEmpty {
      hipX = hips.map(\.x).reduce(0, +) / Double(hips.count)
      hipY = hips.map(\.y).reduce(0, +) / Double(hips.count)
      hipZ = averageDepth(hips, fallback: (neck.depthM ?? 0.58))
    } else if let root = joints[.root] {
      hipX = root.x
      hipY = root.y
      hipZ = root.depthM ?? (neck.depthM ?? 0.58)
    } else {
      hipX = neck.x
      hipY = neck.y + torsoDropWithoutHips
      hipZ = (neck.depthM ?? 0.58)
    }

    let halfHip = hips.isEmpty
      ? halfShoulder * torsoHipRatio
      : max(0.05, hips.map { abs($0.x - hipX) }.max() ?? 0)
    let hipRadius = halfHip * aspect
    let waistRadius = min(topRadius, hipRadius) * waistInset

    let topX = neck.x * aspect
    let topY = neck.y - torsoNeckLift
    let topZ = neck.depthM ?? 0.38
    let bottomX = hipX * aspect
    let bottomZ = hipZ

    var points: [BodyPoint] = []
    points.reserveCapacity(torsoRingCount * torsoSegments)
    for ring in 0..<torsoRingCount {
      let t = Double(ring) / Double(torsoRingCount - 1)
      let centreX = topX + (bottomX - topX) * t
      let centreY = topY + (hipY - topY) * t
      let centreZ = topZ + (bottomZ - topZ) * t
      let radius = torsoRadius(at: t, top: topRadius, waist: waistRadius, hip: hipRadius)

      for segment in 0..<torsoSegments {
        let theta = Double(segment) / Double(torsoSegments) * 2 * Double.pi
        points.append(BodyPoint(x: (centreX + radius * cos(theta)) / aspect,
                                y: centreY,
                                z: centreZ + radius * torsoDepthRatio * sin(theta)))
      }
    }
    return points
  }

  /// A frame with no neck still needs a top: the midpoint of the shoulder line stands in for it.
  private static func torsoTop(_ joints: [JointID: JointSample]) -> JointSample? {
    if let neck = joints[.neck] { return neck }
    let shoulders = [joints[.leftShoulder], joints[.rightShoulder]].compactMap { $0 }
    guard !shoulders.isEmpty else { return nil }
    if shoulders.count == 1 { return shoulders[0] }
    let depths = shoulders.compactMap(\.depthM)
    return JointSample(x: shoulders.map(\.x).reduce(0, +) / 2,
                       y: shoulders.map(\.y).reduce(0, +) / 2,
                       depthM: depths.isEmpty ? nil : depths.reduce(0, +) / Double(depths.count),
                       confidence: 1)
  }

  private static func torsoRadius(at t: Double,
                                  top: Double,
                                  waist: Double,
                                  hip: Double) -> Double {
    if t <= waistAt {
      return mixed(top, waist, smoothstep(t / waistAt))
    }
    return mixed(waist, hip, smoothstep((t - waistAt) / (1 - waistAt)))
  }

  /// Half the shoulder line the torso is built around when the frame has no shoulder joints, in
  /// normalized x.
  private static let halfShoulderFallback = 0.10

  // MARK: - Arms

  private static let armChains: [(JointID, JointID, JointID)] = [
    (.leftShoulder, .leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow, .rightWrist),
  ]
  private static let armRingCount = 14
  private static let armSegments = 12
  private static let armMinimumRadius = 0.016
  private static let armMaximumRadius = 0.028
  private static let armRadiusToLength = 0.09
  private static let armWristTaper = 0.12
  private static let fallbackDepth = 0.45

  /// A capsule around the shoulder-elbow-wrist polyline. Missing joints shorten the chain rather
  /// than moving it; a chain without at least two joints cannot place an arm and is skipped.
  private static func armPoints(_ joints: [JointID: JointSample],
                                chain: (JointID, JointID, JointID)) -> [BodyPoint] {
    let ids = [chain.0, chain.1, chain.2]
    var path: [Vector] = []
    var previousDepth: Double?
    for id in ids {
      guard let joint = joints[id] else { continue }
      let depth = joint.depthM ?? previousDepth ?? fallbackDepth
      previousDepth = depth
      path.append(Vector(x: joint.x * aspect, y: joint.y, z: depth))
    }
    guard path.count >= 2 else { return [] }

    var lengths: [Double] = []
    var total = 0.0
    for index in 0..<(path.count - 1) {
      let segment = length(Vector(x: path[index + 1].x - path[index].x,
                                  y: path[index + 1].y - path[index].y,
                                  z: path[index + 1].z - path[index].z))
      lengths.append(segment)
      total += segment
    }
    guard total > 0 else { return [] }

    let radius = min(armMaximumRadius, max(armMinimumRadius, total * armRadiusToLength))

    var points: [BodyPoint] = []
    points.reserveCapacity(armRingCount * armSegments + 2)
    var firstCentre = path[0]
    var firstTangent = Vector(x: 0, y: 1, z: 0)
    var lastCentre = path[path.count - 1]
    var lastTangent = Vector(x: 0, y: 1, z: 0)
    for ring in 0..<armRingCount {
      let t = Double(ring) / Double(armRingCount - 1)
      let (centre, tangent) = location(along: path, lengths: lengths, at: t * total)
      if ring == 0 {
        firstCentre = centre
        firstTangent = tangent
      }
      if ring == armRingCount - 1 {
        lastCentre = centre
        lastTangent = tangent
      }

      let (normal, binormal) = basis(for: tangent)
      let ringRadius = radius * (1 - armWristTaper * t)
      for segment in 0..<armSegments {
        let theta = Double(segment) / Double(armSegments) * 2 * Double.pi
        let offsetX = (normal.x * cos(theta) + binormal.x * sin(theta)) * ringRadius
        let offsetY = (normal.y * cos(theta) + binormal.y * sin(theta)) * ringRadius
        let offsetZ = (normal.z * cos(theta) + binormal.z * sin(theta)) * ringRadius
        points.append(BodyPoint(x: (centre.x + offsetX) / aspect,
                                y: centre.y + offsetY,
                                z: centre.z + offsetZ))
      }
    }

    // The hemispherical tips the rings stop short of, so the capsule is closed.
    points.append(BodyPoint(x: (firstCentre.x - firstTangent.x * radius) / aspect,
                            y: firstCentre.y - firstTangent.y * radius,
                            z: firstCentre.z - firstTangent.z * radius))
    points.append(BodyPoint(x: (lastCentre.x + lastTangent.x * radius) / aspect,
                            y: lastCentre.y + lastTangent.y * radius,
                            z: lastCentre.z + lastTangent.z * radius))
    return points
  }

  /// The centre and unit tangent `distance` along the polyline.
  private static func location(along path: [Vector],
                               lengths: [Double],
                               at distance: Double) -> (Vector, Vector) {
    var travelled = 0.0
    for index in 0..<lengths.count {
      let segment = lengths[index]
      if distance <= travelled + segment || index == lengths.count - 1 {
        let t = segment > 0 ? min(1, max(0, (distance - travelled) / segment)) : 0
        let start = path[index]
        let end = path[index + 1]
        let centre = Vector(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t,
                            z: start.z + (end.z - start.z) * t)
        let tangent = normalized(Vector(x: end.x - start.x,
                                        y: end.y - start.y,
                                        z: end.z - start.z))
        return (centre, tangent)
      }
      travelled += segment
    }
    return (path[0], Vector(x: 0, y: 1, z: 0))
  }

  /// An orthonormal frame around the axis, chosen from a fixed helper axis, so the ring is placed
  /// the same way on every call.
  private static func basis(for tangent: Vector) -> (Vector, Vector) {
    let helper = abs(tangent.z) < 0.9
      ? Vector(x: 0, y: 0, z: 1)
      : Vector(x: 1, y: 0, z: 0)
    let normal = normalized(cross(helper, tangent))
    let binormal = normalized(cross(tangent, normal))
    return (normal, binormal)
  }
}
