import Foundation
import UIKit

/// 把每条事件写成一行 JSONL，并给关键页面存截图。
final class FileDebugLogger: DebugLogging {
  var isEnabled: Bool

  /// 沙盒 Documents/debug/
  static var defaultDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("debug", isDirectory: true)
  }

  /// 沙盒 Documents/debug/screenshots/
  var screenshotDirectory: URL

  /// 本次会话的日志文件，`enabled` 为假时是 nil。
  private(set) var logFileURL: URL?

  private let directory: URL
  private var handle: FileHandle?

  /// Last screen the app reported; fills the `screen` key on lines that do not carry one.
  private var currentScreen = "home"

  /// Last posture value the engine reported; fills the `state` key on lines that do not carry one.
  private var currentState = "good"

  /// Battery and thermal sampling is throttled to this interval so the 10 Hz sample path stays
  /// cheap while a 30-minute session still shows the discharge and heat trend.
  private static let metricsRefreshInterval: TimeInterval = 10

  /// When the cached battery/thermal values were last refreshed.
  private var metricsRefreshedAt: Date?
  /// Battery charge in 0...1, or nil when the device does not report one.
  private var batteryLevel: Double?
  /// ProcessInfo thermal state mapped to its log spelling.
  private var thermalState: String?

  init(enabled: Bool = false, directory: URL = FileDebugLogger.defaultDirectory) {
    isEnabled = enabled
    self.directory = directory
    screenshotDirectory = directory.appendingPathComponent("screenshots", isDirectory: true)
    if enabled {
      UIDevice.current.isBatteryMonitoringEnabled = true
      openLogFile()
    }
  }

  deinit {
    try? handle?.close()
  }

  func log(_ event: MonitoringEvent) {
    guard isEnabled else { return }
    openLogFileIfNeeded()
    guard let handle = handle else { return }

    let now = Date()
    // `UIDevice` is main-thread only, and `log(_:)` is called from the `@MainActor` coordinator.
    refreshMetricsIfNeeded(now: now)

    var record = event.logRecord(now: now)
    // `screen_shown` and `status_changed` are the only sources for these two values, so tracking
    // whatever the record carries keeps the writer in sync without re-deriving the string mapping.
    if let screen = record.screen { currentScreen = screen }
    if let state = record.state { currentState = state }
    record.screen = record.screen ?? currentScreen
    record.state = record.state ?? currentState
    record.battery_level = batteryLevel
    record.thermal_state = thermalState

    let encoder = JSONEncoder()
    guard var line = try? encoder.encode(record) else { return }
    line.append(0x0A)
    try? handle.write(contentsOf: line)
  }

  /// Refresh the cached battery/thermal values at most once per `metricsRefreshInterval`.
  private func refreshMetricsIfNeeded(now: Date) {
    if let last = metricsRefreshedAt, now.timeIntervalSince(last) < Self.metricsRefreshInterval {
      return
    }
    metricsRefreshedAt = now

    // `batteryLevel` is -1 when the device does not report one (e.g. a simulator).
    let level = UIDevice.current.batteryLevel
    batteryLevel = level < 0 ? nil : Double(level)
    thermalState = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
  }

  private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "nominal"
    }
  }

  func screenshot(_ name: String) {
    guard isEnabled else { return }
    // The window lookup and the renderer are main-thread only; callers may be anywhere.
    DispatchQueue.main.async { [weak self] in
      self?.capture(name)
    }
  }

  private func capture(_ name: String) {
    guard let window = keyWindow else { return }

    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    guard let png = image.pngData() else { return }

    let url = screenshotDirectory.appendingPathComponent("\(name).png")
    try? FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
    try? png.write(to: url, options: .atomic)
  }

  /// Prefer the active scene's key window, but fall back to the foremost scene's first
  /// window: a device with no rendered surface (and a headless simulator) still hands out
  /// a window, just not a `foregroundActive` one.
  private var keyWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
      return nil
    }
    return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
  }

  private func openLogFileIfNeeded() {
    guard handle == nil else { return }
    openLogFile()
  }

  private func openLogFile() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      let url = FileDebugLogger.sessionFileURL(in: directory)
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      }

      let handle = try FileHandle(forWritingTo: url)
      _ = try handle.seekToEnd()

      self.handle = handle
      logFileURL = url
    } catch {
      // Prototype stage: a debug log that cannot be opened must never reach the caller.
    }
  }

  private static func sessionFileURL(in directory: URL) -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // Colons are legal in a URL but hostile in a file name, so the name uses the compact time.
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
    return directory.appendingPathComponent("session-\(stamp).jsonl")
  }
}
