import Foundation
import SwiftUI

/// The projection shared by the avatar and the debug overlay. Both draw the same body in the same
/// place, so a screenshot with debug on lines its skeleton up with the particle cloud.
enum PoseProjection {
  /// The depth grid's 3:4 frame, aspect-fitted and centred in the available space. The joints use
  /// the same normalized coordinates as the grid, so one rect serves both.
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

/// A cartoon child built only from the coarse depth grid and the joints: a head, a torso and two upper
/// arms drawn as round-cornered outlines with a soft fill, and a sparse, depth-shaded scan of the
/// depth frame over the top. The parts the dominant posture blames take that posture's colour from
/// `PosturePalette`, so the part that lights up here wears the colour the report gives the same
/// posture; everything else stays calm.
///
/// It never renders an image, never touches a camera and never writes to disk; RGB is not an input it
/// can even express. Pure, so the same inputs draw the same picture.
struct AvatarView: View {
  private let geometry: PoseGeometry?
  private let assessment: PostureAssessment?

  init(geometry: PoseGeometry?, assessment: PostureAssessment?) {
    self.geometry = geometry
    self.assessment = assessment
  }

  var body: some View {
    Canvas(opaque: true, rendersAsynchronously: false) { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

      guard let geometry, !geometry.joints.isEmpty || geometry.depth != nil else {
        drawEmptyState(in: &context, size: size)
        return
      }
      draw(geometry, in: &context, size: size)
    }
    .allowsHitTesting(false)
  }

  // MARK: - Composition

  private func draw(_ geometry: PoseGeometry, in context: inout GraphicsContext, size: CGSize) {
    let rect = PoseProjection.rect(in: size)
    guard rect.width > 0, rect.height > 0 else { return }

    let dominant = assessment?.dominant
    let alertJoints = Self.alertJoints(for: dominant)
    let alertInk = Self.alertInk(for: dominant)
    let parts = Self.figureParts(joints: geometry.joints,
                                rect: rect,
                                alertJoints: alertJoints,
                                alertInk: alertInk)
    let style = StrokeStyle(lineWidth: Self.strokeWidth(in: rect), lineCap: .round, lineJoin: .round)

    // Fill, then the scan, then the outline: the points sit inside the silhouette and the cartoon line
    // stays crisp on top of them.
    for part in parts where part.isClosed {
      context.fill(part.path, with: .color(part.ink.opacity(Self.fillOpacity)))
    }

    drawCloud(in: &context, rect: rect, depth: geometry.depth,
              alertPositions: Self.positions(of: alertJoints, in: geometry.joints),
              alertInk: alertInk)

    for part in parts {
      context.stroke(part.path, with: .color(part.ink.opacity(Self.strokeOpacity)), style: style)
    }

    drawAlertMarkers(in: &context, rect: rect, joints: geometry.joints,
                     alertJoints: alertJoints, alertInk: alertInk, stroke: style.lineWidth)
  }

  // MARK: - Cartoon figure

  /// One piece of the drawing. The closed pieces — the head and the torso — get a fill as well as an
  /// outline; the upper arms are a single open stroke.
  private struct FigurePart {
    var path: Path
    var ink: Color
    var isClosed: Bool
  }

  private static let headJoints: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
  private static let torsoJoints: [JointID] = [.neck, .leftShoulder, .rightShoulder,
                                              .root, .leftHip, .rightHip]
  /// Head, torso, then one upper arm per side: the whole figure is these five pieces.
  private static let upperArms: [(shoulder: JointID, elbow: JointID)] = [
    (.leftShoulder, .leftElbow),
    (.rightShoulder, .rightElbow),
  ]

  /// Every piece the available joints can place. A frame whose skeleton is missing joints loses the
  /// pieces it cannot place rather than drawing a wrong body.
  private static func figureParts(joints: [JointID: JointSample],
                                  rect: CGRect,
                                  alertJoints: Set<JointID>,
                                  alertInk: Color?) -> [FigurePart] {
    var parts: [FigurePart] = []

    if let head = headPath(joints: joints, rect: rect) {
      let blamed = headJoints.contains { alertJoints.contains($0) }
      parts.append(FigurePart(path: head, ink: ink(for: blamed, alertInk: alertInk), isClosed: true))
    }

    if let torso = torsoPath(joints: joints, rect: rect) {
      let blamed = torsoJoints.contains { alertJoints.contains($0) }
      parts.append(FigurePart(path: torso, ink: ink(for: blamed, alertInk: alertInk), isClosed: true))
    }

    for arm in upperArms {
      guard let shoulder = joints[arm.shoulder], let elbow = joints[arm.elbow] else { continue }
      var path = Path()
      path.move(to: PoseProjection.point(shoulder.position, in: rect))
      path.addLine(to: PoseProjection.point(elbow.position, in: rect))
      parts.append(FigurePart(path: path,
                              ink: ink(for: alertJoints.contains(arm.shoulder), alertInk: alertInk),
                              isClosed: false))
    }

    return parts
  }

  /// The posture's own colour when the piece carries the blame, the calm slate otherwise. A piece can
  /// only be blamed while some posture dominates, which is also the only time `alertInk` exists.
  private static func ink(for isBlamed: Bool, alertInk: Color?) -> Color {
    isBlamed ? (alertInk ?? calmInk) : calmInk
  }

  /// The head: a circle around the face joints. Its radius follows how far apart they sit — the ear
  /// line is the widest part of a face — and the vertical one is squeezed by the grid's 3:4 aspect, so
  /// the head comes out round on screen rather than as a tall oval.
  private static func headPath(joints: [JointID: JointSample], rect: CGRect) -> Path? {
    let samples = headJoints.compactMap { joints[$0] }
    guard !samples.isEmpty else { return nil }

    let centreX = samples.map(\.x).reduce(0, +) / Double(samples.count)
    let centreY = samples.map(\.y).reduce(0, +) / Double(samples.count)
    let halfWidth = max(minimumHeadHalfWidth, (samples.map { abs($0.x - centreX) }.max() ?? 0) * 1.5)
    let halfHeight = halfWidth * rect.width / rect.height * 1.15

    return Path(ellipseIn: projected(CGRect(x: centreX - halfWidth,
                                            y: centreY - halfHeight,
                                            width: halfWidth * 2,
                                            height: halfHeight * 2),
                                     in: rect))
  }

  /// The torso: the shoulder line, flared out from the neck, into a rounded trapezoid that reaches
  /// down past the hips. Every corner is pushed out from the joints by `torsoMargin`, so the outline
  /// wraps the shoulders instead of cutting through them, and the bottom edge is narrower than the top
  /// one because shoulders are the widest part of a seated child. That taper is also what leaves the
  /// upper arms hanging outside the outline instead of being swallowed by it.
  private static func torsoPath(joints: [JointID: JointSample], rect: CGRect) -> Path? {
    guard let left = joints[.leftShoulder], let right = joints[.rightShoulder] else { return nil }

    let centreX = (left.x + right.x) / 2
    let topY = min(left.y, right.y, joints[.neck]?.y ?? Double.infinity) - torsoMargin
    // With no hip or root joint the trapezoid still gets a plausible shoulder-to-hip span instead of
    // collapsing into a sliver.
    let lower = [joints[.leftHip]?.y, joints[.rightHip]?.y, joints[.root]?.y]
      .compactMap { $0 }.max() ?? (max(left.y, right.y) + torsoDropWithoutHips)
    let bottomY = max(topY + torsoMargin, lower) + torsoMargin

    let halfTop = max(abs(left.x - centreX), abs(right.x - centreX)) + torsoMargin
    let hipHalf = [joints[.leftHip]?.x, joints[.rightHip]?.x]
      .compactMap { $0 }
      .map { abs($0 - centreX) }
      .max() ?? (halfTop - torsoMargin) * torsoHipRatio
    let halfBottom = min(halfTop, hipHalf + torsoMargin)

    let corners = [
      CGPoint(x: centreX - halfTop, y: topY),
      CGPoint(x: centreX + halfTop, y: topY),
      CGPoint(x: centreX + halfBottom, y: bottomY),
      CGPoint(x: centreX - halfBottom, y: bottomY),
    ]
    return roundedPath(corners.map { PoseProjection.point($0, in: rect) })
  }

  /// A closed outline that walks past every corner on a quadratic curve, so the trapezoid is a drawn
  /// cartoon shape rather than a ruler-drawn one. A corner rounds over a quarter of its shorter edge at
  /// most, which is what keeps two neighbouring corners from swallowing each other.
  private static func roundedPath(_ corners: [CGPoint]) -> Path {
    guard corners.count >= 3 else { return Path() }

    var path = Path()
    for index in corners.indices {
      let previous = corners[(index + corners.count - 1) % corners.count]
      let current = corners[index]
      let next = corners[(index + 1) % corners.count]
      let round = min(length(from: previous, to: current), length(from: current, to: next)) * 0.25
      let entry = point(from: current, towards: previous, distance: round)
      let exit = point(from: current, towards: next, distance: round)

      if index == 0 {
        path.move(to: entry)
      }
      path.addQuadCurve(to: exit, control: current)
    }
    path.closeSubpath()
    return path
  }

  /// A point `distance` along the way from `origin` to `target`, clamped to the segment's own length.
  private static func point(from origin: CGPoint, towards target: CGPoint, distance: CGFloat) -> CGPoint {
    let segment = length(from: origin, to: target)
    guard segment > 0 else { return origin }
    let step = min(distance, segment) / segment
    return CGPoint(x: origin.x + (target.x - origin.x) * step,
                   y: origin.y + (target.y - origin.y) * step)
  }

  private static func length(from a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = Double(b.x - a.x)
    let dy = Double(b.y - a.y)
    return CGFloat((dx * dx + dy * dy).squareRoot())
  }

  /// The model rect for a normalized box. The projection is a scale plus an offset, so a box projects
  /// into a box.
  private static func projected(_ box: CGRect, in rect: CGRect) -> CGRect {
    let origin = PoseProjection.point(box.origin, in: rect)
    let corner = PoseProjection.point(CGPoint(x: box.maxX, y: box.maxY), in: rect)
    return CGRect(x: origin.x, y: origin.y,
                  width: corner.x - origin.x, height: corner.y - origin.y)
  }

  /// One fixed line width for the whole figure: uniform strokes are what makes a drawing read as a
  /// cartoon rather than as an analysis.
  private static func strokeWidth(in rect: CGRect) -> CGFloat {
    max(2, min(rect.width, rect.height) * 0.014)
  }

  // MARK: - Depth scan

  private struct CloudCell {
    var x: Double
    var y: Double
    var depth: Double
    var order: Int
  }

  /// Every third cell in each direction: 8 columns by 11 rows over the 24 by 32 grid. The stride is
  /// the whole trick — one point per three cells reads as a scan of a body, where one per cell read as
  /// a solid mass. Cells whose reading the frame's own edge fade has swallowed are skipped, so a real
  /// frame shows a few dozen points rather than all 88.
  private static let particleStride = 3

  /// Reading closer than this is indistinguishable from the edge fade of the fake depth frame, so
  /// it is treated as no reading rather than as an extremely close point.
  private static let minimumReadableDepth = 0.08
  private static let depthNear = 0.15
  private static let depthFar = 0.65

  private func drawCloud(in context: inout GraphicsContext,
                         rect: CGRect,
                         depth: DepthFrame?,
                         alertPositions: [CGPoint],
                         alertInk: Color?) {
    guard let depth else { return }

    var cells: [CloudCell] = []
    for y in stride(from: 1, to: DepthFrame.height, by: Self.particleStride) {
      for x in stride(from: 1, to: DepthFrame.width, by: Self.particleStride) {
        let metres = Double(depth.value(x: x, y: y))
        guard metres >= Self.minimumReadableDepth else { continue }
        cells.append(CloudCell(x: (Double(x) + 0.5) / Double(DepthFrame.width),
                               y: (Double(y) + 0.5) / Double(DepthFrame.height),
                               depth: metres,
                               order: y * DepthFrame.width + x))
      }
    }

    // Far to near, so nearer particles sit on top. Ties break on grid order, keeping the render
    // deterministic even though `sort` is not stable.
    cells.sort { lhs, rhs in
      lhs.depth != rhs.depth ? lhs.depth > rhs.depth : lhs.order < rhs.order
    }

    let spacing = min(rect.width / CGFloat(DepthFrame.width), rect.height / CGFloat(DepthFrame.height))
    let alertRadiusSquared = 0.075 * 0.075

    for cell in cells {
      let nearness = min(1, max(0, (Self.depthFar - cell.depth) / (Self.depthFar - Self.depthNear)))
      let isAlert = alertPositions.contains { joint in
        let dx = Double(joint.x) - cell.x
        let dy = Double(joint.y) - cell.y
        return dx * dx + dy * dy <= alertRadiusSquared
      }

      let radius = spacing * CGFloat(0.22 + 0.30 * nearness)
      let centre = PoseProjection.point(CGPoint(x: cell.x, y: cell.y), in: rect)
      let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
      let opacity = Self.particleMinOpacity + Self.particleMaxOpacity * nearness

      if isAlert, let alertInk {
        context.fill(Path(ellipseIn: dot), with: .color(alertInk.opacity(opacity)))
      } else {
        let ink = Self.farInk.mixed(with: Self.nearInk, nearness)
        context.fill(Path(ellipseIn: dot), with: .color(ink.color(opacity: opacity)))
      }
    }
  }

  // MARK: - Alert markers

  /// A soft halo and an anchor dot on every blamed joint the outline does not already carry — the
  /// wrists, and the neck and shoulder ends of the torso — so a hand on a cheek or a shoulder tilt
  /// still reads as changed even where the scan is sparse.
  private func drawAlertMarkers(in context: inout GraphicsContext,
                                rect: CGRect,
                                joints: [JointID: JointSample],
                                alertJoints: Set<JointID>,
                                alertInk: Color?,
                                stroke: CGFloat) {
    guard let alertInk else { return }

    for id in JointID.allCases where alertJoints.contains(id) && !Self.headJoints.contains(id) {
      guard let joint = joints[id] else { continue }
      let centre = PoseProjection.point(joint.position, in: rect)

      let halo = stroke * 2.4
      let wash = CGRect(x: centre.x - halo, y: centre.y - halo, width: halo * 2, height: halo * 2)
      context.fill(Path(ellipseIn: wash), with: .radialGradient(
        Gradient(colors: [alertInk.opacity(0.30), alertInk.opacity(0)]),
        center: centre,
        startRadius: 0,
        endRadius: halo
      ))

      let radius = stroke * 0.55
      let dot = CGRect(x: centre.x - radius, y: centre.y - radius,
                       width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: dot), with: .color(alertInk.opacity(0.95)))
    }
  }

  // MARK: - Dominant posture

  /// The body parts that carry a posture's blame. Everything else stays calm.
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
    case .headTilt: return head.union(shoulders)
    case .chinRest: return wrists.union(head)
    case nil: return []
    }
  }

  /// Where the blamed joints sit in normalized coordinates, for the scan's own "is this point near a
  /// blamed part" test.
  private static func positions(of ids: Set<JointID>,
                                in joints: [JointID: JointSample]) -> [CGPoint] {
    JointID.allCases.filter { ids.contains($0) }.compactMap { joints[$0]?.position }
  }

  // MARK: - Empty state

  /// A quiet ring of dim dots: honest about having nothing to show without looking broken, and
  /// deliberately without a face, since there is no one to draw one for.
  private func drawEmptyState(in context: inout GraphicsContext, size: CGSize) {
    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    let ink = Color.white.opacity(0.10)

    for index in 0..<12 {
      let angle = Double(index) / 12 * 2 * .pi
      let point = CGPoint(x: centre.x + CGFloat(cos(angle)) * 26,
                          y: centre.y + CGFloat(sin(angle)) * 26)
      let dot = CGRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)
      context.fill(Path(ellipseIn: dot), with: .color(ink))
    }
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
  /// The calm body: a cool, desaturated slate that belongs to no posture, which keeps the palette the
  /// only place a posture colour is written down.
  static let calmInk = Color(.sRGB, red: 0.62, green: 0.68, blue: 0.78, opacity: 1)

  /// The scan's depth ramp, far to near: a dark slate brightening to a near white, so depth reads from
  /// brightness and size without competing with the palette.
  static let farInk = Ink(r: 0.24, g: 0.29, b: 0.37)
  static let nearInk = Ink(r: 0.86, g: 0.91, b: 0.97)

  /// The dominant posture's own colour, straight out of the single palette, so the part that lights up
  /// on the avatar wears the colour that posture wears in the report. Nil when nothing breaches.
  static func alertInk(for kind: PostureKind?) -> Color? {
    guard let kind else { return nil }
    return PosturePalette.color(for: kind.rawValue)
  }

  static let fillOpacity = 0.13
  static let strokeOpacity = 0.90
  static let particleMinOpacity = 0.28
  static let particleMaxOpacity = 0.62

  /// The figure's proportions in normalized grid units: how far the torso outline is pushed out past
  /// the joints, how wide its bottom edge falls back to when the hips are missing, the shoulder-to-hip
  /// span it falls back to when the lower body is missing, and the smallest head the face joints are
  /// allowed.
  static let torsoMargin = 0.022
  static let torsoHipRatio = 0.80
  static let torsoDropWithoutHips = 0.30
  static let minimumHeadHalfWidth = 0.07
}
