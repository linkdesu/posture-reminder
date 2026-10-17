import Foundation
import SwiftUI

/// Good-GYM style debug layer: the COCO-ish skeleton, one dot per joint, and one monospaced row per
/// feature reading with its value and threshold. Over-threshold rows are red. Nil geometry or nil
/// assessment draws nothing, so an empty screenshot is honest rather than misleading.
struct DebugOverlayView: View {
  private let geometry: PoseGeometry?
  private let assessment: PostureAssessment?

  init(geometry: PoseGeometry?, assessment: PostureAssessment?) {
    self.geometry = geometry
    self.assessment = assessment
  }

  var body: some View {
    if let geometry, let assessment {
      ZStack(alignment: .bottomLeading) {
        Canvas(rendersAsynchronously: false) { context, size in
          drawSkeleton(geometry, in: &context, size: size)
        }
        if !assessment.readings.isEmpty {
          featureTable(assessment)
            .padding(16)
        }
      }
      .allowsHitTesting(false)
    }
  }

  // MARK: - Skeleton

  /// Nose-eye-ear down each side, neck to both shoulders, arms to the wrists, neck to root and root
  /// to both hips.
  private static let chains: [(JointID, JointID)] = [
    (.nose, .leftEye), (.leftEye, .leftEar),
    (.nose, .rightEye), (.rightEye, .rightEar),
    (.neck, .leftShoulder), (.neck, .rightShoulder),
    (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    (.neck, .root), (.root, .leftHip), (.root, .rightHip),
  ]

  private func drawSkeleton(_ geometry: PoseGeometry,
                            in context: inout GraphicsContext,
                            size: CGSize) {
    let rect = PoseProjection.rect(in: size)
    guard rect.width > 0, rect.height > 0, !geometry.joints.isEmpty else { return }

    let positions = geometry.joints.mapValues { PoseProjection.point($0.position, in: rect) }

    var lines = Path()
    for (from, to) in Self.chains {
      guard let start = positions[from], let end = positions[to] else { continue }
      lines.move(to: start)
      lines.addLine(to: end)
    }
    context.stroke(lines,
                   with: .color(.white.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

    for id in JointID.allCases {
      guard let joint = geometry.joints[id], let centre = positions[id] else { continue }
      let radius: CGFloat = 3
      let dot = Path(ellipseIn: CGRect(x: centre.x - radius,
                                       y: centre.y - radius,
                                       width: radius * 2,
                                       height: radius * 2))
      if joint.confidence < 0.5 {
        context.stroke(dot, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
      } else {
        context.fill(dot, with: .color(.white.opacity(0.9)))
      }
    }
  }

  // MARK: - Feature table

  private func featureTable(_ assessment: PostureAssessment) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(assessment.readings, id: \.feature) { reading in
        row(reading)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
  }

  private func row(_ reading: FeatureReading) -> some View {
    HStack(spacing: 6) {
      Text(reading.feature.displayName)
        .frame(width: 60, alignment: .leading)
      Text(format(reading.value, for: reading.feature))
        .frame(width: 44, alignment: .trailing)
      Text("/")
        .opacity(0.35)
      Text(format(reading.threshold, for: reading.feature))
        .frame(width: 44, alignment: .trailing)
    }
    .font(.system(size: 11, weight: .semibold, design: .monospaced))
    .foregroundStyle(reading.isOverThreshold ? Color.red : Color.white.opacity(0.5))
  }

  /// No units in the column, so the numbers stay aligned; the feature name carries the meaning.
  private func format(_ value: Double, for feature: PostureFeature) -> String {
    switch feature {
    case .distance, .headPitch, .headRoll, .shoulderTilt:
      return String(format: "%.0f", value)
    case .headHeightDrop, .handToFace, .headForward, .slouch:
      return String(format: "%.2f", value)
    }
  }
}
