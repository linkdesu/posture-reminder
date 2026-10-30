import Foundation
import UIKit

/// 每秒读一次设备热状态与电量，把结论交给会话层。
///
/// 热状态只有四个值（`nominal`/`fair`/`serious`/`critical`），降级口径在 `CaptureLoad`：`serious`
/// 起 Vision 5 Hz、点云 15 Hz。这个类型只负责采样与转发，不写日志——降级起止的那两行由会话层写进
/// 42 键日志，每秒的环境读数由 `PerfMonitor` 写进 perf 日志。
///
/// 电量在模拟器与部分设备上不报告（`batteryLevel < 0`），交给调用方写 null。
@MainActor
final class ThermalSampler {
  /// 采样间隔：1 秒。降级要在升温的几秒内被发现，而不是十秒。
  static let interval: TimeInterval = 1

  /// `(thermal_state, battery_level, degraded)`；状态名与日志的 `thermal_state` 同一套拼写。
  var onSample: ((String, Double?, Bool) -> Void)?

  private var timer: Timer?

  /// 幂等。启动时先发一次，热状态不会因为「刚启动还没到第一秒」而漏掉降级。
  func start() {
    guard timer == nil else { return }
    UIDevice.current.isBatteryMonitoringEnabled = true
    let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sample() }
    }
    self.timer = timer
    sample()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func sample() {
    let state = Self.name(ProcessInfo.processInfo.thermalState)
    let level = UIDevice.current.batteryLevel
    onSample?(state, level < 0 ? nil : Double(level), CaptureLoad.degraded(thermalState: state))
  }

  static func name(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "nominal"
    }
  }
}
