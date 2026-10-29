#if DEBUG
import Foundation

/// 一个样本的肩部测量快照，只用于 DEBUG 日志。
///
/// 归一化坐标与 `JointSample` 同一套空间（0...1，y 向下），深度单位米，肩距单位厘米。
/// `shouldersAvailable` 是关节来源自己的结论：两个肩都在、且通过约束时才为真；为假时下游必须
/// 按「不可用」处理，而不是拿一个乱给的点继续算。
struct JointDebugSample {
  var neck: JointSample?
  var leftShoulder: JointSample?
  var rightShoulder: JointSample?
  /// 据深度换算的两肩三维距离，厘米。
  var shoulderSpanCM: Double?
  var shouldersAvailable: Bool
  /// 头部在轮廓里占的宽度（归一化 x）。
  var headWidth: Double?
  var headTopY: Double?
  var headBottomY: Double?
  /// 本次找肩用的那一行（归一化 y），便于 QA 核对肩点确实在颈部以下。
  var shoulderRowY: Double?
}

/// 每个样本一行 `Documents/debug/joints-*.jsonl`，同时以 `[joints]` 前缀打到标准输出。
final class JointDebugLog {
  static let shared = JointDebugLog()

  private let file = DebugLineFile(prefix: "joints")

  func write(_ sample: JointDebugSample) {
    file.write(Self.line(sample))
  }

  /// 纯函数，字段名就是 QA 解析时用的键名。
  static func line(_ sample: JointDebugSample) -> String {
    let epochMilliseconds = Int((Date().timeIntervalSince1970 * 1000).rounded())
    return "{\"t\":\(epochMilliseconds)"
      + ",\"neck_x\":\(number(sample.neck?.x))"
      + ",\"neck_y\":\(number(sample.neck?.y))"
      + ",\"neck_z_m\":\(number(sample.neck?.depthM))"
      + ",\"left_shoulder_x\":\(number(sample.leftShoulder?.x))"
      + ",\"left_shoulder_y\":\(number(sample.leftShoulder?.y))"
      + ",\"left_shoulder_z_m\":\(number(sample.leftShoulder?.depthM))"
      + ",\"right_shoulder_x\":\(number(sample.rightShoulder?.x))"
      + ",\"right_shoulder_y\":\(number(sample.rightShoulder?.y))"
      + ",\"right_shoulder_z_m\":\(number(sample.rightShoulder?.depthM))"
      + ",\"shoulder_span_cm\":\(number(sample.shoulderSpanCM))"
      + ",\"shoulders_available\":\(sample.shouldersAvailable)"
      + ",\"head_width\":\(number(sample.headWidth))"
      + ",\"head_top_y\":\(number(sample.headTopY))"
      + ",\"head_bottom_y\":\(number(sample.headBottomY))"
      + ",\"shoulder_row_y\":\(number(sample.shoulderRowY))}"
  }

  private static func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.4f", value)
  }
}
#endif
