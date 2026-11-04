import Foundation
import SwiftUI

/// Good-GYM style debug layer: the COCO-ish skeleton with a Chinese name on every joint a posture
/// reads, and one row per feature reading with its value, threshold and — the part Link asked for —
/// the joints and the arithmetic the number comes from.
///
/// It is on screen whenever debug mode is on, focus or not: before 开始专注 there are no readings yet,
/// so the rows show their formula with a dash instead of a value, and the skeleton appears as soon as
/// the source has joints.
///
/// Nothing here is drawn over the controls: the feature table is the bottom-leading column, the
/// skeleton follows the same projection as the point cloud, and the whole layer ignores touches.
struct DebugOverlayView: View {
  private let geometry: PoseGeometry?
  private let assessment: PostureAssessment?

  init(geometry: PoseGeometry?, assessment: PostureAssessment?) {
    self.geometry = geometry
    self.assessment = assessment
  }

  var body: some View {
    if geometry != nil || assessment != nil {
      ZStack(alignment: .bottomLeading) {
        Canvas(rendersAsynchronously: false) { context, size in
          guard let geometry else { return }
          // 0.6.8 (17)：人形由 AvatarView 用 Vision 画；这里不再画 COCO 骨架（旧的鼻–眼–耳链
          // 在头上叠出一个 M 形）。只保留右下的指标表。
        }
        VStack(alignment: .leading, spacing: 6) {
          jointTable()
          featureTable()
        }
        .padding(16)
      }
      .allowsHitTesting(false)
    }
  }

  // MARK: - Joint table

  /// All fifteen joint names, five to a row, each carrying its own availability: a filled name is a
  /// joint this frame measured, a struck-through dim one is a joint the depth source could not
  /// measure. Nothing on the screen ever shows a joint that is not in the list.
  private func jointTable() -> some View {
    let columns = Array(repeating: GridItem(.fixed(58), spacing: 4, alignment: .leading),
                        count: 5)
    let joints = geometry?.joints ?? [:]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
      ForEach(JointID.allCases, id: \.self) { id in
        let available = joints[id] != nil
        Text(id.debugName)
          .font(.system(size: 9, weight: available ? .semibold : .regular))
          .foregroundStyle(available ? Color.white.opacity(0.8) : Color.white.opacity(0.28))
          .strikethrough(!available, color: Color.white.opacity(0.28))
          .accessibilityLabel("\(id.debugName) \(available ? "可用" : "不可用")")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: 320, alignment: .leading)
    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Feature table

  private func featureTable() -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(PostureFeature.allCases.filter { $0 != .headHeightDrop }, id: \.self) { feature in
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Text(feature.displayName)
              .frame(width: 48, alignment: .leading)
            Text(valueText(feature))
              .frame(width: 40, alignment: .trailing)
            Text("/")
              .opacity(0.35)
            Text(thresholdText(feature))
              .frame(width: 40, alignment: .trailing)
          }
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(reading(feature).map { $0.isOverThreshold ? Color.red : Color.white.opacity(0.6) }
                           ?? Color.white.opacity(0.35))

          Text(PostureFeatureSource.formula(feature))
            .font(.system(size: 9, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
  }

  private func reading(_ feature: PostureFeature) -> FeatureReading? {
    assessment?.readings.first { $0.feature == feature }
  }

  private func valueText(_ feature: PostureFeature) -> String {
    guard let reading = reading(feature) else { return "—" }
    // 「本轮还没有样本」是 `—`；「样本到了但这项没量到」是 未测量。
    return reading.isMeasured ? format(reading.value, for: feature) : "未测量"
  }

  private func thresholdText(_ feature: PostureFeature) -> String {
    reading(feature).map { format($0.threshold, for: feature) } ?? "—"
  }

  /// No units in the column, so the numbers stay aligned; the feature name and the formula carry the
  /// meaning.
  private func format(_ value: Double, for feature: PostureFeature) -> String {
    switch feature {
    case .distance, .headPitch, .headRoll, .shoulderTilt:
      return String(format: "%.0f", value)
    case .headHeightDrop, .handToFace, .headForward, .slouch:
      return String(format: "%.2f", value)
    }
  }
}

// MARK: - Copy

extension JointID {
  /// The Chinese name a joint carries in the debug overlay. `root` is the rig's torso centre rather
  /// than a real joint, so it is named for what it stands for.
  var debugName: String {
    switch self {
    case .nose: return "头"
    case .leftEye: return "左眼"
    case .rightEye: return "右眼"
    case .leftEar: return "左耳"
    case .rightEar: return "右耳"
    case .neck: return "颈"
    case .root: return "躯干"
    case .leftShoulder: return "左肩"
    case .rightShoulder: return "右肩"
    case .leftElbow: return "左肘"
    case .rightElbow: return "右肘"
    case .leftWrist: return "左腕"
    case .rightWrist: return "右腕"
    case .leftHip: return "左髋"
    case .rightHip: return "右髋"
    }
  }
}

/// What each reading is computed from, in the words of the classifier it mirrors. This is copy, not
/// maths: `PostureClassifier.read` remains the only place a value is produced, and if its formula
/// moves these lines have to move with it.
enum PostureFeatureSource {
  static func formula(_ feature: PostureFeature) -> String {
    switch feature {
    case .distance:
      return "距离 = 头部区域深度中位数到相机（深度图）"
    case .headPitch:
      return "低头角度 = 基线俯仰 − 头部深度平面俯仰"
    case .headRoll:
      return "歪头 = |头部深度平面滚转 − 基线滚转|"
    case .shoulderTilt:
      return "肩线 = 左肩-右肩连线与水平夹角 − 基线"
    case .headHeightDrop:
      return "头高 = 头中心 y − 基线头高"
    case .handToFace:
      return "手到脸 = min(左腕、右腕 到 鼻尖的距离)；深度版无腕关节"
    case .headForward:
      return "头前伸 = 基线鼻深 − 当前鼻深"
    case .slouch:
      return "驼背 = max(肩宽缩短比, 颈-躯干缩短比)"
    }
  }
}
