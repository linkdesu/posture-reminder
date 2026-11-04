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
  /// 这一帧的在场证据路径（v0.6.8 (18)）：`face_eyes` / `neck_shoulder` / `none`。只有鼻子过门槛
  /// 的一帧记 `none`——鼻子是锚点，不是证据。
  var presencePath: PresencePath
  /// 同帧是否找到人脸（`VNDetectFaceLandmarksRequest` 的人脸框）。
  var faceDetected: Bool
  /// 关节的屏幕归一化坐标（只对可见关节有意义）。
  var pointX: [String: Double] = [:]
  var pointY: [String: Double] = [:]
  /// Vision 肩线：端点、角度、是否高于头部；不可用时端点为 null。
  var visionShoulders: ShoulderLine = .unavailable
  /// 背景轮廓这一帧是否开启（设置项）。
  var outlineEnabled: Bool = true
  /// 背景点云这一帧的点数与相对上一帧的平均位移（归一化）。
  var backgroundPoints: Int = 0
  var backgroundShift: Double = 0
  /// 距离与前倾这一帧有没有值。
  var distanceValid: Bool = false
  var forwardValid: Bool = false
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
    // 在场判定的三个输入关节单独列一份扁平键：`joints` 里有同样的数字，但 QA 复算路径时不必
    // 再钻进嵌套对象。不可见时为 null，与 `joints.<名>.c` 一致。
    func passed(_ key: String) -> String {
      number((sample.visible[key] ?? false) ? sample.confidence[key] : nil)
    }

    return "{\"t\":\(epochMilliseconds)"
      + ",\"session_t\":\(String(format: "%.3f", sample.sessionT))"
      + ",\"detected\":\(sample.detected)"
      + ",\"stale\":\(sample.stale)"
      + ",\"shoulders_available\":\(available)"
      + ",\"shoulders_invalidated\":\(sample.shouldersInvalidated)"
      + ",\"presence_path\":\"\(sample.presencePath.rawValue)\""
      + ",\"face_detected\":\(sample.faceDetected)"
      + ",\"neck\":\(passed("neck"))"
      + ",\"left_shoulder\":\(passed("leftShoulder"))"
      + ",\"right_shoulder\":\(passed("rightShoulder"))"
      + ",\"raw\":{\(raw.joined(separator: ","))}"
      + ",\"joints\":{\(entries.joined(separator: ","))}"
      + ",\"vision_shoulders\":\(visionLine)"
      + ",\"figure_points\":\(figurePoints(sample))"
      + ",\"figure_lines\":\(figureLines(sample))"
      + ",\"background_points\":\(sample.backgroundPoints)"
      + ",\"background_shift\":\(number(sample.backgroundShift))"
      + ",\"outline_enabled\":\(sample.outlineEnabled)"
      + ",\"distance_valid\":\(sample.distanceValid)"
      + ",\"forward_valid\":\(sample.forwardValid)}"
  }

  /// 人形的点：名称、屏幕归一化坐标、置信度。只列这一帧真正画得出来的点。
  private static func figurePoints(_ sample: JointFrameDebugSample) -> String {
    let order: [JointID] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck,
                            .leftShoulder, .rightShoulder]
    var items: [String] = []
    for id in order where sample.visible[id.rawValue] == true {
      guard let x = sample.pointX[id.rawValue], let y = sample.pointY[id.rawValue] else { continue }
      items.append("{\"name\":\"\(id.rawValue)\",\"x\":\(number(x)),\"y\":\(number(y))"
                   + ",\"c\":\(number(sample.confidence[id.rawValue]))}")
    }
    return "[" + items.joined(separator: ",") + "]"
  }

  /// 画了哪些线：只有耳–眼、眼–眼、眼–耳、颈–双肩。
  private static func figureLines(_ sample: JointFrameDebugSample) -> String {
    var lines: [String] = []
    func has(_ id: JointID) -> Bool { sample.visible[id.rawValue] == true }
    if has(.leftEar) && has(.leftEye) { lines.append("\"ear_eye\"") }
    if has(.leftEye) && has(.rightEye) { lines.append("\"eye_eye\"") }
    if has(.rightEye) && has(.rightEar) { lines.append("\"eye_ear\"") }
    if has(.neck) && has(.leftShoulder) { lines.append("\"neck_left_shoulder\"") }
    if has(.neck) && has(.rightShoulder) { lines.append("\"neck_right_shoulder\"") }
    return "[" + lines.joined(separator: ",") + "]"
  }

  /// 一条肩线的 JSON：左右端点（null 写 null）、`angle_deg`、`above_head`（nil 写 null）、`available`。
  private static func shoulderLine(_ shoulders: ShoulderLine) -> String {
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
