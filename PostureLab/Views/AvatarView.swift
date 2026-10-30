import Foundation
import SwiftUI

/// The projection shared by the avatar and the debug overlay. Both draw the same body in the same
/// place, so a screenshot with debug on lines its skeleton up with the point cloud.
enum PoseProjection {
  /// The depth grid's 3:4 frame, aspect-fitted and centred in the available space. The joints and the
  /// body cloud use the same normalized coordinates as the grid, so one rect serves both.
  static func rect(in size: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let gridAspect = CGFloat(DepthFrame.width) / CGFloat(DepthFrame.height)
    let width = min(size.width, size.height * gridAspect)
    let height = width / gridAspect
    return CGRect(x: (size.width - width) / 2,
                  y: (size.height - height) / 2,
                  width: width,
                  height: height)
  }

  /// Normalized (0...1, y downwards) to the model rect.
  static func point(_ point: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height)
  }
}

/// The child as a 3D point cloud. When the depth source has a mask, the points are that mask's own
/// cells — `DepthCloud` samples them straight from the depth frame — projected through a camera fixed
/// in front of the body: a point nearer than the body's mean depth is magnified and brightened, a
/// farther one shrunk and dimmed, and each point's radius follows its own perspective. A geometry
/// without a cloud (a scripted rig) falls back to `BodyCloud`, which derives volumes from the joints.
///
/// The canvas renders asynchronously, at most `frameInterval` apart, and every point is batched into
/// one of `bandCount` depth bands, so a frame is at most twelve fills instead of one per point and
/// none of that work runs on the main thread. Between the 10 Hz samples `CloudMotion` moves each
/// point from the last sample to the current one on the display clock, so the body glides instead of
/// stepping.
///
/// The parts the dominant posture blames take that posture's colour from `PosturePalette`, exactly as
/// they do in the report. With no body at all the view draws a vector silhouette — a head, shoulders
/// and a torso in outline — so the ground is never a blank warning and never a camera picture.
///
/// It never renders an image, never touches a camera and never writes to disk; RGB is not an input it
/// can even express.
struct AvatarView: View {
  private let geometry: PoseGeometry?
  private let assessment: PostureAssessment?

  /// The last two samples, so the canvas can draw the frame between them.
  @State private var motion = CloudMotion()

  init(geometry: PoseGeometry?, assessment: PostureAssessment?) {
    self.geometry = geometry
    self.assessment = assessment
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !hasBody)) { timeline in
      Canvas(opaque: true, rendersAsynchronously: true) { context, size in
        #if DEBUG
        // 一帧一次；`rendersAsynchronously` 让这个闭包不在主线程，计数由 PerfMonitor 加锁。
        let renderStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
          PerfMonitor.shared.recordRender(seconds: ProcessInfo.processInfo.systemUptime - renderStartedAt)
        }
        PerfMonitor.shared.recordFrame()
        #endif
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        guard let geometry, !geometry.joints.isEmpty else {
          drawSilhouette(in: &context, size: size)
          return
        }
        // 第一个样本到达前 `motion` 还是空的，直接用当前样本，不从空白插值。
        let points = motion.to.isEmpty
          ? geometry.cloud
          : motion.displayed(at: timeline.date.timeIntervalSinceReferenceDate)
        let cloud = points.isEmpty ? BodyCloud.points(for: geometry.joints) : points
        guard !cloud.isEmpty else {
          drawSilhouette(in: &context, size: size)
          return
        }
        draw(cloud, geometry: geometry, in: &context, size: size)
      }
    }
    .allowsHitTesting(false)
    // 新的样本进来时只记下它和时刻，插值本身发生在画布里，主线程不做逐点计算。
    .onChange(of: geometry) { _, newValue in
      motion.push(newValue?.cloud ?? [], at: Date().timeIntervalSinceReferenceDate)
    }
  }

  private var hasBody: Bool {
    !(geometry?.joints.isEmpty ?? true)
  }

  // MARK: - Composition

  private func draw(_ points: [BodyPoint],
                    geometry: PoseGeometry,
                    in context: inout GraphicsContext,
                    size: CGSize) {
    let rect = PoseProjection.rect(in: size)
    guard rect.width > 0, rect.height > 0 else { return }

    // The projection is affine, so the cloud's centre can be projected once and every point then
    // only moves by its own perspective: no per-point CGPoint array, no sort.
    var centreX = 0.0
    var centreY = 0.0
    var depthSum = 0.0
    var nearZ = Double.greatestFiniteMagnitude
    var farZ = -Double.greatestFiniteMagnitude
    for point in points {
      centreX += point.x
      centreY += point.y
      depthSum += point.z
      nearZ = min(nearZ, point.z)
      farZ = max(farZ, point.z)
    }
    let count = Double(points.count)
    centreX /= count
    centreY /= count
    let meanZ = depthSum / count
    let span = farZ - nearZ
    let centre = PoseProjection.point(CGPoint(x: centreX, y: centreY), in: rect)

    let dominant = assessment?.dominant
    let alertInk = Self.alertInk(for: dominant)
    let alertPositions = Self.positions(of: Self.alertJoints(for: dominant), in: geometry.joints)
    let alertRadiusSquared = Self.alertRadius * Self.alertRadius

    let baseRadius = min(rect.width, rect.height) * Self.particleRadiusScale
    // One path per depth band, filled once: twelve fills for a whole body instead of one per point.
    var bands = [Path](repeating: Path(), count: Self.bandCount)
    var alertBands = [Path](repeating: Path(), count: Self.bandCount)

    for point in points {
      let nearness = Self.nearness(of: point.z, maximum: farZ, span: span)
      let perspective = CGFloat(Self.perspective(z: point.z, reference: meanZ))
      let radius = baseRadius * perspective * CGFloat(0.80 + 0.50 * nearness)
      let projected = PoseProjection.point(CGPoint(x: point.x, y: point.y), in: rect)
      let position = CGPoint(x: centre.x + (projected.x - centre.x) * perspective,
                             y: centre.y + (projected.y - centre.y) * perspective)
      let dot = CGRect(x: position.x - radius,
                       y: position.y - radius,
                       width: radius * 2,
                       height: radius * 2)
      let band = min(Self.bandCount - 1, Int(nearness * Double(Self.bandCount)))
      if alertInk != nil,
         Self.isAlert(point, joints: alertPositions, radiusSquared: alertRadiusSquared) {
        alertBands[band].addEllipse(in: dot)
      } else {
        bands[band].addEllipse(in: dot)
      }
    }

    // Far to near, so nearer points sit on top even though they are batched.
    for band in 0..<Self.bandCount {
      let nearness = (Double(band) + 0.5) / Double(Self.bandCount)
      let opacity = Self.particleMinOpacity + Self.particleMaxOpacity * nearness
      if !bands[band].isEmpty {
        let ink = Self.farInk.mixed(with: Self.nearInk, nearness)
        context.fill(bands[band], with: .color(ink.color(opacity: opacity)))
      }
      if let alertInk, !alertBands[band].isEmpty {
        context.fill(alertBands[band], with: .color(alertInk.opacity(opacity)))
      }
    }
  }

  // MARK: - Depth

  /// 0 for the farthest point and 1 for the nearest. A cloud whose points all share one depth has
  /// no range to shade, so it sits in the middle instead of pretending to a direction.
  private static func nearness(of z: Double, maximum: Double, span: Double) -> Double {
    guard span > 0.001 else { return 0.5 }
    return min(1, max(0, (maximum - z) / span))
  }

  /// A camera `cameraDistance` in front of the body's mean depth. The mean projects exactly where
  /// `PoseProjection.point` puts its joint; a point beside it moves by its own depth difference only.
  /// The clamp keeps a stray joint from blowing the figure up or collapsing it.
  private static func perspective(z: Double, reference: Double) -> Double {
    let distance = cameraDistance + (z - reference)
    guard distance > 0.1 else { return maximumPerspective }
    return min(maximumPerspective, max(minimumPerspective, cameraDistance / distance))
  }

  private static func isAlert(_ point: BodyPoint,
                              joints: [CGPoint],
                              radiusSquared: Double) -> Bool {
    joints.contains { joint in
      let dx = Double(joint.x) - point.x
      let dy = Double(joint.y) - point.y
      return dx * dx + dy * dy <= radiusSquared
    }
  }

  // MARK: - Dominant posture

  /// The body parts that carry a posture's blame. Everything else stays calm. `headTilt` lights the
  /// head and `shoulderTilt` the shoulder line, so the two postures that used to share one pose now
  /// also light different parts.
  private static func alertJoints(for kind: PostureKind?) -> Set<JointID> {
    let head = Set(headJoints)
    let shoulders: Set<JointID> = [.leftShoulder, .rightShoulder]
    let wrists: Set<JointID> = [.leftWrist, .rightWrist]

    switch kind {
    case .deskLean: return head.union(shoulders)
    case .near: return head
    case .headForward: return head
    case .slouch: return shoulders.union([.neck])
    case .headDown: return head
    case .headTilt: return head
    case .shoulderTilt: return shoulders
    case .chinRest: return wrists.union(head)
    case nil: return []
    }
  }

  /// Where the blamed joints sit in normalized coordinates, for the cloud's own "is this point near
  /// a blamed part" test. A point near the head changes colour with the head, a point near a
  /// shoulder with the shoulder line, and a hand resting on a cheek with the wrist.
  private static func positions(of ids: Set<JointID>,
                                in joints: [JointID: JointSample]) -> [CGPoint] {
    JointID.allCases.filter { ids.contains($0) }.compactMap { joints[$0]?.position }
  }

  // MARK: - Empty state

  /// A vector silhouette of a seated upper body — head, neck, shoulders and torso in outline — for
  /// the moment before the depth sensor has a body to show. It is drawn with paths, not a picture: it
  /// is a place, not a person, and it deliberately has no face. This is the only thing the view draws
  /// besides the cloud.
  private func drawSilhouette(in context: inout GraphicsContext, size: CGSize) {
    let rect = PoseProjection.rect(in: size)
    guard rect.width > 0, rect.height > 0 else { return }

    let ink = Color.white.opacity(0.14)
    let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 5])

    // Head: a circle sitting where the head band of a real mask lands.
    let headRadius = rect.width * 0.075
    let headCentre = PoseProjection.point(CGPoint(x: 0.5, y: 0.30), in: rect)
    let head = Path(ellipseIn: CGRect(x: headCentre.x - headRadius,
                                      y: headCentre.y - headRadius * 1.1,
                                      width: headRadius * 2,
                                      height: headRadius * 2.2))
    context.stroke(head, with: .color(ink), style: stroke)

    // Shoulders and torso: one continuous outline, narrower at the neck and flaring at the shoulder
    // line, so the shape reads as a seated child rather than a rectangle.
    var body = Path()
    body.move(to: CGPoint(x: headCentre.x, y: headCentre.y + headRadius * 1.25))
    body.addLine(to: CGPoint(x: headCentre.x, y: headCentre.y + headRadius * 1.7))
    body.addCurve(to: PoseProjection.point(CGPoint(x: 0.24, y: 0.52), in: rect),
                  control1: PoseProjection.point(CGPoint(x: 0.41, y: 0.40), in: rect),
                  control2: PoseProjection.point(CGPoint(x: 0.27, y: 0.44), in: rect))
    body.addCurve(to: PoseProjection.point(CGPoint(x: 0.32, y: 0.78), in: rect),
                  control1: PoseProjection.point(CGPoint(x: 0.21, y: 0.62), in: rect),
                  control2: PoseProjection.point(CGPoint(x: 0.28, y: 0.72), in: rect))
    body.move(to: PoseProjection.point(CGPoint(x: 0.68, y: 0.78), in: rect))
    body.addCurve(to: PoseProjection.point(CGPoint(x: 0.76, y: 0.52), in: rect),
                  control1: PoseProjection.point(CGPoint(x: 0.72, y: 0.72), in: rect),
                  control2: PoseProjection.point(CGPoint(x: 0.79, y: 0.62), in: rect))
    body.addCurve(to: CGPoint(x: headCentre.x, y: headCentre.y + headRadius * 1.7),
                  control1: PoseProjection.point(CGPoint(x: 0.73, y: 0.44), in: rect),
                  control2: PoseProjection.point(CGPoint(x: 0.59, y: 0.40), in: rect))
    context.stroke(body, with: .color(ink), style: stroke)

    // The base of the silhouette, closed so the outline reads as one figure.
    var base = Path()
    base.move(to: PoseProjection.point(CGPoint(x: 0.32, y: 0.78), in: rect))
    base.addLine(to: PoseProjection.point(CGPoint(x: 0.68, y: 0.78), in: rect))
    context.stroke(base, with: .color(ink), style: stroke)
  }
}

// MARK: - Palette

private struct Ink {
  var r: Double
  var g: Double
  var b: Double

  func mixed(with other: Ink, _ t: Double) -> Ink {
    let k = min(1, max(0, t))
    return Ink(r: r + (other.r - r) * k,
               g: g + (other.g - g) * k,
               b: b + (other.b - b) * k)
  }

  func color(opacity: Double) -> Color {
    Color(.sRGB, red: r, green: g, blue: b, opacity: min(1, max(0, opacity)))
  }
}

private extension AvatarView {
  static let headJoints: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]

  /// 画布的最短刷新间隔：30 fps 上限，够看出连续动作，又给关节推算和判定留出余量。
  static let frameInterval: TimeInterval = 1.0 / 30.0
  /// 深度分档数。每档一条路径一次填充，所以一帧最多 `bandCount × 2` 次填充。
  static let bandCount = 6

  /// The cloud's depth ramp, far to near: a dark slate brightening to a near white, so depth reads
  /// from brightness and size without competing with the palette.
  static let farInk = Ink(r: 0.24, g: 0.29, b: 0.37)
  static let nearInk = Ink(r: 0.86, g: 0.91, b: 0.97)

  /// The dominant posture's own colour, straight out of the single palette, so the part that lights
  /// up on the avatar wears the colour that posture wears in the report. Nil when nothing breaches.
  static func alertInk(for kind: PostureKind?) -> Color? {
    guard let kind else { return nil }
    return PosturePalette.color(for: kind.rawValue)
  }

  static let particleMinOpacity = 0.28
  static let particleMaxOpacity = 0.62
  /// A point's radius before perspective, as a share of the canvas's shorter side.
  static let particleRadiusScale: CGFloat = 0.0045

  /// A camera three quarters of a metre in front of the body, and the bounds that keep a stray joint
  /// from warping the figure.
  static let cameraDistance = 0.75
  static let minimumPerspective = 0.60
  static let maximumPerspective = 1.60

  /// How close to a blamed joint, in normalized x/y, a cloud point must sit to wear the posture's
  /// colour. Large enough to cover the surface the joint anchors, small enough to leave the rest calm.
  static let alertRadius = 0.075
}
