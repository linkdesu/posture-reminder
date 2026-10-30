#if DEBUG
import Foundation

/// 一帧关节结果的调试快照：模型是否看人、每个关节的原始置信度与可见性，加上双肩的两条结论。
///
/// 只写 DEBUG 的 `Documents/debug/joints-*.jsonl`；42 键的 QA 契约与它无关（另一个文件、另一套键）。
/// QA 用它算三个真机指标：双肩可用帧占比、肩点落在头上的帧数、以及每个关节的置信度分布。
struct JointFrameDebugSample {
  /// 会话时钟，秒。
  var sessionT: TimeInterval
  /// 模型这一帧是否报出了人。false = 画面里没人；true 而关节不可见 = 被 0.5 门槛过滤。
  var detected: Bool
  /// 关节与深度帧的配对是否过期（超过 150 ms）。过期时关节一律不可见。
  var stale: Bool
  /// 双肩因为落在鼻以上被整帧作废。
  var shouldersInvalidated: Bool
  /// 过了门槛、可以进入判定的关节置信度；不可见时为 nil。键是 `JointID.rawValue`。
  var confidence: [String: Double]
  /// 模型的**原始**置信度（门槛之前）；模型没报这个关节时为 nil。键是 `JointID.rawValue`。
  var rawConfidence: [String: Double]
  /// 每个关节这一帧是否可见。
  var visible: [String: Bool]
  /// Vision 肩线（采集侧已配对好的肩点）：端点、角度、是否高于头部；不可用时端点为 null。
  var visionShoulders: MaskShoulderLine.Estimate = .unavailable
  /// 遮罩肩线（`MaskShoulderLine.estimate`，深度队列算好随观测存放）；不可用时端点为 null。
  var maskShoulders: MaskShoulderLine.Estimate = .unavailable
}

/// 每个 Vision 帧一行 `joints-*.jsonl`，同时以 `[joints]` 前缀打到标准输出。
final class JointFrameLog {
  static let shared = JointFrameLog()

  private let file = DebugLineFile(prefix: "joints")

  func write(_ sample: JointFrameDebugSample) {
    file.write(Self.line(sample))
  }

  /// 纯函数，字段名就是 QA 解析时用的键名。
  static func line(_ sample: JointFrameDebugSample) -> String {
    let epochMilliseconds = Int((Date().timeIntervalSince1970 * 1000).rounded())

    var entries: [String] = []
    for joint in VisionPoseMapping.deliveredJoints {
      let key = joint.rawValue
      let visible = sample.visible[key] ?? false
      let confidence = visible ? sample.confidence[key] : nil
      entries.append("\"\(key)\":{\"c\":\(number(confidence)),\"v\":\(visible)}")
    }

    let available = (sample.visible["leftShoulder"] ?? false) && (sample.visible["rightShoulder"] ?? false)

    var raw: [String] = []
    for joint in VisionPoseMapping.deliveredJoints {
      let key = joint.rawValue
      raw.append("\"\(key)\":\(number(sample.rawConfidence[key]))")
    }

    // 两条肩线并排：Vision 肩点（过了 0.5 门槛的）与遮罩肩线（`MaskShoulderLine`），
    // 供真机对比哪条更稳；它们都不进判定。
    let visionLine = Self.shoulderLine(sample.visionShoulders)
    let maskLine = Self.shoulderLine(sample.maskShoulders)

    return "{\"t\":\(epochMilliseconds)"
      + ",\"session_t\":\(String(format: "%.3f", sample.sessionT))"
      + ",\"detected\":\(sample.detected)"
      + ",\"stale\":\(sample.stale)"
      + ",\"shoulders_available\":\(available)"
      + ",\"shoulders_invalidated\":\(sample.shouldersInvalidated)"
      + ",\"raw\":{\(raw.joined(separator: ","))}"
      + ",\"joints\":{\(entries.joined(separator: ","))}"
      + ",\"vision_shoulders\":\(visionLine)"
      + ",\"mask_shoulders\":\(maskLine)}"
  }

  /// 一条肩线的 JSON：左右端点（null 写 null）、`angle_deg`、`above_head`（nil 写 null）、`available`。
  private static func shoulderLine(_ shoulders: MaskShoulderLine.Estimate) -> String {
    "{" + "\"left\":\(point(shoulders.left))"
      + ",\"right\":\(point(shoulders.right))"
      + ",\"angle_deg\":\(number(shoulders.angleDeg))"
      + ",\"above_head\":\(shoulders.aboveHead.map(String.init) ?? "null")"
      + ",\"available\":\(shoulders.available)}"
  }

  private static func point(_ point: CGPointLike?) -> String {
    guard let point else { return "null" }
    return "{\"x\":\(String(format: "%.3f", point.x)),\"y\":\(String(format: "%.3f", point.y))}"
  }

  private static func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.3f", value)
  }
}
#endif
