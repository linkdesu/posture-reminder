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
  /// 4 个关键点（头/颈/双肩）的平滑与出现/消失过渡。
  @State private var keyPoints = KeyPointOverlayMotion()

  init(geometry: PoseGeometry?, assessment: PostureAssessment?) {
    self.geometry = geometry
    self.assessment = assessment
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !hasBody)) { timeline in
      Canvas(opaque: true, rendersAsynchronously: true) { context, size in
        #if DEBUG
        // 一帧一次；`rendersAsynchronously` 让这个闭包不在主线程，计数与逐帧记录都由各自加锁。
        let renderStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
          let seconds = ProcessInfo.processInfo.systemUptime - renderStartedAt
          PerfMonitor.shared.recordRender(seconds: seconds)
          // 把这一帧的上屏耗时与延迟补进它对应的深度帧记录（cloud-*.jsonl）。
          FrameLog.shared.rendered(seconds: seconds)
        }
        PerfMonitor.shared.recordFrame()
        #endif
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        // 点云来自深度，不依赖关节：Vision 一时看不到人（凑近、侧脸）时，点云照样该在。
        // 0.6.8 (15) 就是在这里把「关节空」当成「没有人」，于是凑近时点云被矢量轮廓顶掉，
        // 看起来像点云消失（r20：cloud 每帧都有 600 点，深度层没有问题）。
        guard let geometry else {
          drawSilhouette(in: &context, size: size)
          return
        }
        // 第一个样本到达前 `motion` 还是空的，直接用当前样本，不从空白插值。
        let points = motion.to.isEmpty
          ? geometry.cloud
          : motion.displayed(at: timeline.date.timeIntervalSinceReferenceDate)
        // z == 0 是「这一格没有读数」的占位：固定网格的槽位在人体外时会保留旧值直到过期，
        // 真正的空槽位不参与绘制，也不参与下面的质心计算。
        let visible = points.filter { $0.z > 0 }
        #if DEBUG
        FrameLog.shared.noteVisiblePoints(visible.count)
        #endif
        // 0.6.8 (17)：人形由 Vision 画，深度点云只是可选的暗色背景轮廓（设置项默认开）。
        if geometry.outlineEnabled, !visible.isEmpty {
          draw(visible, geometry: geometry, in: &context, size: size, dim: Self.outlineDim)
        }

        let overlay = keyPoints.displayed(at: timeline.date.timeIntervalSinceReferenceDate)
        if overlay.alpha > 0.01, !overlay.points.isEmpty {
          drawFigure(overlay.points, mouth: geometry.mouth, alpha: overlay.alpha,
                     in: &context, size: size)
        } else if !geometry.outlineEnabled || visible.isEmpty {
          // 既没有人形、也没有背景轮廓时才退回矢量轮廓，绝不空屏。
          drawSilhouette(in: &context, size: size)
        }
      }
    }
    .allowsHitTesting(false)
    // 新的样本进来时只记下它和时刻，插值本身发生在画布里，主线程不做逐点计算。
    .onChange(of: geometry) { _, newValue in
      let now = Date().timeIntervalSinceReferenceDate
      motion.push(newValue?.cloud ?? [], at: now, interval: newValue?.cloudInterval)
      keyPoints.update(Self.keyPoints(from: newValue?.joints ?? [:]), at: now)
    }
  }

  private var hasBody: Bool {
    !(geometry?.joints.isEmpty ?? true) || !(geometry?.cloud.isEmpty ?? true)
  }

  // MARK: - Composition

  private func draw(_ points: [BodyPoint],
                    geometry: PoseGeometry,
                    in context: inout GraphicsContext,
                    size: CGSize,
                    dim: Double = 1) {
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
        context.fill(bands[band], with: .color(ink.color(opacity: opacity * dim)))
      }
      if let alertInk, !alertBands[band].isEmpty {
        context.fill(alertBands[band], with: .color(alertInk.opacity(opacity * dim)))
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

  /// 4 个关键点：头（鼻点，没有鼻点时取双眼中点）、颈、左右肩。缺任何一个就不返回整组，
  /// 由 `KeyPointOverlayMotion` 决定保持还是淡出。
  /// 人形的点：鼻、双眼、双耳、颈、双肩——每帧只收这一帧真正测到的，缺的就缺席（由过渡层负责
  /// 保持与淡出）。嘴是轮廓，单独由 `drawFigure` 画。
  static func keyPoints(from joints: [JointID: JointSample]) -> [JointID: CGPoint] {
    var points: [JointID: CGPoint] = [:]
    for id in [JointID.nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck,
               .leftShoulder, .rightShoulder] {
      if let joint = joints[id] { points[id] = joint.position }
    }
    return points
  }

  /// Vision 人形：鼻/眼/耳/颈/双肩的点、嘴的外轮廓，以及**只限这几种**连线：
  /// 耳–眼、眼–眼、眼–耳（左右各一段），颈–左肩、颈–右肩。没有别的线（0.6.8 (16) 头上那个 M
  /// 形来自旧的 COCO 骨架鼻–眼–耳链，已随 DebugOverlay 一起删除）。不画任何文字。
  static let figureLines: [(JointID, JointID)] = [
    (.leftEar, .leftEye), (.leftEye, .rightEye), (.rightEye, .rightEar),
    (.neck, .leftShoulder), (.neck, .rightShoulder),
  ]

  private func drawFigure(_ points: [JointID: CGPoint],
                          mouth: [CGPointLike],
                          alpha: Double,
                          in context: inout GraphicsContext,
                          size: CGSize) {
    let rect = PoseProjection.rect(in: size)
    guard rect.width > 0, rect.height > 0 else { return }
    let ink = Self.keyInk.color(opacity: alpha)

    var lines = Path()
    for (from, to) in Self.figureLines {
      guard let start = points[from], let end = points[to] else { continue }
      lines.move(to: PoseProjection.point(start, in: rect))
      lines.addLine(to: PoseProjection.point(end, in: rect))
    }
    context.stroke(lines, with: .color(ink),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

    // 点半径是人形之外的 3 倍：孩子的部位要一眼认出来。
    let radius = min(rect.width, rect.height) * Self.particleRadiusScale * 3
    for (_, point) in points {
      let centre = PoseProjection.point(point, in: rect)
      let dot = CGRect(x: centre.x - radius, y: centre.y - radius,
                       width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: dot), with: .color(ink))
    }

    // 嘴：外轮廓闭合折线（Vision 面部特征；取不到就不画，不伪造）。
    guard mouth.count >= 3 else { return }
    var lips = Path()
    lips.move(to: PoseProjection.point(CGPoint(x: mouth[0].x, y: mouth[0].y), in: rect))
    for point in mouth.dropFirst() {
      lips.addLine(to: PoseProjection.point(CGPoint(x: point.x, y: point.y), in: rect))
    }
    lips.closeSubpath()
    context.stroke(lips, with: .color(ink), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
  }

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

/// 4 个关键点的平滑与出现/消失。
///
/// 关键点齐全时坐标按 0.15 s 时间常数做指数平滑（静止时相邻帧位移远小于屏宽 2%）；只要有一个不齐，
/// 先保持最后已知位置 `hold` 秒，再用 `fade` 秒淡出；从缺失恢复时不瞬亮，同样用 `fade` 秒淡入。
/// 纯值类型、纯函数式的时间查询，画布按显示时钟取当前结果，单测可以直接推进时间。
struct KeyPointOverlayMotion: Equatable {
  /// 缺失后保持完全可见的时长。
  static let hold: TimeInterval = 0.3
  /// 淡出 / 淡入的时长。
  static let fade: TimeInterval = 0.2
  /// 坐标平滑的时间常数。
  static let smoothingTau: TimeInterval = 0.15

  private(set) var points: [JointID: CGPoint] = [:]
  private var missingSince: TimeInterval?
  private var presentSince: TimeInterval = -TimeInterval.greatestFiniteMagnitude
  private var lastUpdate: TimeInterval?

  /// 收一帧关键点。`raw` 为空 = 这一帧有部位低于门槛。
  mutating func update(_ raw: [JointID: CGPoint], at now: TimeInterval) {
    guard raw.count == 4 else {
      if missingSince == nil { missingSince = now }
      lastUpdate = now
      return
    }
    let dt = lastUpdate.map { max(0, now - $0) } ?? 0
    let alpha = dt > 0 ? 1 - exp(-dt / Self.smoothingTau) : 1
    for (id, target) in raw {
      if let previous = points[id] {
        points[id] = CGPoint(x: previous.x + (target.x - previous.x) * alpha,
                             y: previous.y + (target.y - previous.y) * alpha)
      } else {
        points[id] = target
      }
    }
    if missingSince != nil {
      presentSince = now
      missingSince = nil
    }
    lastUpdate = now
  }

  /// 显示时钟上的透明度：齐全时淡入，缺失时保持 `hold` 再 `fade` 淡出。
  func alpha(at now: TimeInterval) -> Double {
    if let missingSince {
      let gone = now - missingSince
      if gone <= Self.hold { return 1 }
      return max(0, 1 - (gone - Self.hold) / Self.fade)
    }
    return min(1, max(0, (now - presentSince) / Self.fade))
  }

  func displayed(at now: TimeInterval) -> (points: [JointID: CGPoint], alpha: Double) {
    (points, alpha(at: now))
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
  /// 深度背景轮廓的亮度：人形是主角，点云退到 0.18。
  static let outlineDim = 0.18
  /// 关键点的对比色：暖琥珀，和点云的冷灰蓝、以及三种体态配色都能分开。
  static let keyInk = Ink(r: 1.0, g: 0.78, b: 0.28)
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
