import Foundation

/// 发热降级时的采集负载。
///
/// 正常：深度 30 Hz 驱动点云、Vision 约 10 Hz。降到 `serious` 时深度 15 Hz、Vision 5 Hz
/// （ADR-0008 第 5 条与 0.6.8 的验收口径）。口径写成一张表而不是散在调用点里，是为了让日志与降级
/// 行为共用同一个来源：`device-logs` 判「降级时段」时读的就是这个结论。
struct CaptureLoad: Equatable {
  /// 点云更新的上限，Hz。
  var cloudHz: Double
  /// Vision 推理的上限，Hz。
  var visionHz: Double

  static let normal = CaptureLoad(cloudHz: 30, visionHz: 10)
  static let degraded = CaptureLoad(cloudHz: 15, visionHz: 5)

  /// 降级的判定：`serious` 与 `critical` 都算。字符串与日志的 `thermal_state` 同一套拼写。
  static func degraded(thermalState: String) -> Bool {
    thermalState == "serious" || thermalState == "critical"
  }

  static func load(thermalState: String) -> CaptureLoad {
    degraded(thermalState: thermalState) ? .degraded : .normal
  }

  var cloudInterval: TimeInterval { 1 / max(1, cloudHz) }
  var visionInterval: TimeInterval { 1 / max(1, visionHz) }
}
