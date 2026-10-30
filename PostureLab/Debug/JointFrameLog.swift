#if DEBUG
import Foundation

/// 一帧关节结果的调试快照：每个关节的置信度与可见性，加上双肩的两条结论。
///
/// 只写 DEBUG 的 `Documents/debug/joints-*.jsonl`；42 键的 QA 契约与它无关（另一个文件、另一套键）。
/// QA 用它算三个真机指标：双肩可用帧占比、肩点落在头上的帧数、以及每个关节的置信度分布。
struct JointFrameDebugSample {
  /// 会话时钟，秒。
  var sessionT: TimeInterval
  /// 关节与深度帧的配对是否过期（超过 150 ms）。过期时关节一律不可见。
  var stale: Bool
  /// 双肩因为落在鼻以上被整帧作废。
  var shouldersInvalidated: Bool
  /// 每个关节的置信度；不可见时为 nil。键是 `JointID.rawValue`。
  var confidence: [String: Double]
  /// 每个关节这一帧是否可见。
  var visible: [String: Bool]
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

    return "{\"t\":\(epochMilliseconds)"
      + ",\"session_t\":\(String(format: "%.3f", sample.sessionT))"
      + ",\"stale\":\(sample.stale)"
      + ",\"shoulders_available\":\(available)"
      + ",\"shoulders_invalidated\":\(sample.shouldersInvalidated)"
      + ",\"joints\":{\(entries.joined(separator: ","))}}"
  }

  private static func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.3f", value)
  }
}
#endif
