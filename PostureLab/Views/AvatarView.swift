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

/// An artistic body built only from the coarse depth grid and the joints: a depth-shaded particle
/// cloud with a soft, denser face mask. It never renders an image, never touches a camera and never
/// writes to disk; RGB is not an input it can even express. Pure, so the same inputs draw the same
/// picture.
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

    let alertJoints = Self.alertJoints(for: assessment?.dominant)
    let alertPositions = JointID.allCases
      .filter { alertJoints.contains($0) }
      .compactMap { geometry.joints[$0]?.position }

    drawCloud(in: &context, rect: rect, depth: geometry.depth, alertPositions: alertPositions)
    drawAlertGlows(in: &context, rect: rect, positions: alertPositions)
    drawFaceMask(in: &context, rect: rect, joints: geometry.joints,
                 isAlert: alertJoints.contains { Self.headJoints.contains($0) })
    drawAlertDots(in: &context, rect: rect, joints: geometry.joints, alertJoints: alertJoints)
  }

  // MARK: - Depth cloud

  private struct CloudCell {
    var x: Double
    var y: Double
    var depth: Double
    var order: Int
  }

  /// Reading closer than this is indistinguishable from the edge fade of the fake depth frame, so
  /// it is treated as no reading rather than as an extremely close point.
  private static let minimumReadableDepth = 0.08
  private static let depthNear = 0.15
  private static let depthFar = 0.65

  private func drawCloud(in context: inout GraphicsContext,
                         rect: CGRect,
                         depth: DepthFrame?,
                         alertPositions: [CGPoint]) {
    guard let depth else { return }

    var cells: [CloudCell] = []
    cells.reserveCapacity(DepthFrame.width * DepthFrame.height)
    for y in 0..<DepthFrame.height {
      for x in 0..<DepthFrame.width {
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

      let ink = isAlert
        ? Self.alertFarInk.mixed(with: Self.alertNearInk, nearness)
        : Self.farInk.mixed(with: Self.nearInk, nearness)
      let radius = spacing * CGFloat(0.24 + 0.34 * nearness)
      let centre = PoseProjection.point(CGPoint(x: cell.x, y: cell.y), in: rect)
      let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)

      context.fill(Path(ellipseIn: dot), with: .color(ink.color(opacity: 0.22 + 0.66 * nearness)))
    }
  }

  // MARK: - Face mask

  private static let headJoints: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]

  /// A soft, denser mask over the head joints: a low radial wash plus a fixed lattice of bright
  /// points inside it. No randomness, so the mask is identical every frame for the same joints.
  private func drawFaceMask(in context: inout GraphicsContext,
                            rect: CGRect,
                            joints: [JointID: JointSample],
                            isAlert: Bool) {
    let head = Self.headJoints.compactMap { joints[$0] }
    guard let reference = joints[.nose] ?? head.first else { return }

    let centreX = head.map(\.x).reduce(0, +) / Double(head.count)
    let centreY = head.map(\.y).reduce(0, +) / Double(head.count)
    let halfWidth = max(0.05, head.map { abs($0.x - centreX) }.max() ?? 0) + 0.02
    let halfHeight = halfWidth * 1.2

    let nearness = min(1, max(0, (Self.depthFar - (reference.depthM ?? Self.depthFar)) /
                                (Self.depthFar - Self.depthNear)))
    let ink = isAlert
      ? Self.alertFarInk.mixed(with: Self.alertNearInk, nearness)
      : Self.farInk.mixed(with: Self.maskNearInk, nearness)

    let centre = PoseProjection.point(CGPoint(x: centreX, y: centreY), in: rect)
    let halfWidthPoints = CGFloat(halfWidth) * rect.width
    let halfHeightPoints = CGFloat(halfHeight) * rect.height
    let wash = CGRect(x: centre.x - halfWidthPoints,
                      y: centre.y - halfHeightPoints,
                      width: halfWidthPoints * 2,
                      height: halfHeightPoints * 2)

    context.fill(Path(ellipseIn: wash), with: .radialGradient(
      Gradient(colors: [ink.color(opacity: 0.24), ink.color(opacity: 0)]),
      center: centre,
      startRadius: 0,
      endRadius: max(halfWidthPoints, halfHeightPoints)
    ))

    for row in 0...6 {
      for column in 0...6 {
        let dx = Double(column) / 3 - 1
        let dy = Double(row) / 3 - 1
        let radiusSquared = dx * dx + dy * dy
        guard radiusSquared <= 1.05 else { continue }

        let point = CGPoint(x: centre.x + CGFloat(dx) * halfWidthPoints * 0.88,
                            y: centre.y + CGFloat(dy) * halfHeightPoints)
        let radius: CGFloat = CGFloat(1.3 + 0.9 * nearness)
        let dot = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let opacity = 0.85 * (1 - radiusSquared * 0.4)
        context.fill(Path(ellipseIn: dot), with: .color(ink.color(opacity: opacity)))
      }
    }

    for id in Self.headJoints {
      guard let joint = joints[id] else { continue }
      let point = PoseProjection.point(joint.position, in: rect)
      let radius: CGFloat = CGFloat(2.4 + 1.2 * nearness)
      let dot = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: dot), with: .color(ink.color(opacity: 0.9)))
    }
  }

  // MARK: - Alert parts

  private func drawAlertGlows(in context: inout GraphicsContext,
                              rect: CGRect,
                              positions: [CGPoint]) {
    guard !positions.isEmpty else { return }
    let radius = min(rect.width, rect.height) * 0.07

    for position in positions {
      let centre = PoseProjection.point(position, in: rect)
      let wash = CGRect(x: centre.x - radius, y: centre.y - radius,
                        width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: wash), with: .radialGradient(
        Gradient(colors: [Self.alertNearInk.color(opacity: 0.32),
                          Self.alertNearInk.color(opacity: 0)]),
        center: centre,
        startRadius: 0,
        endRadius: radius
      ))
    }
  }

  /// A small anchor dot on every alert joint outside the face, so the wrist and shoulder parts read
  /// as changed even where the cloud is sparse.
  private func drawAlertDots(in context: inout GraphicsContext,
                             rect: CGRect,
                             joints: [JointID: JointSample],
                             alertJoints: Set<JointID>) {
    for id in JointID.allCases where alertJoints.contains(id) && !Self.headJoints.contains(id) {
      guard let joint = joints[id] else { continue }
      let centre = PoseProjection.point(joint.position, in: rect)
      let radius: CGFloat = 2.2
      let dot = CGRect(x: centre.x - radius, y: centre.y - radius,
                       width: radius * 2, height: radius * 2)
      context.fill(Path(ellipseIn: dot), with: .color(Self.alertNearInk.color(opacity: 0.9)))
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

  // MARK: - Empty state

  /// A quiet ring of dim dots: honest about having nothing to show without looking broken.
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
  static let farInk = Ink(r: 0.09, g: 0.20, b: 0.40)
  static let nearInk = Ink(r: 0.66, g: 0.92, b: 1.00)
  static let maskNearInk = Ink(r: 0.84, g: 0.98, b: 1.00)
  static let alertFarInk = Ink(r: 0.42, g: 0.14, b: 0.04)
  static let alertNearInk = Ink(r: 1.00, g: 0.60, b: 0.20)
}
