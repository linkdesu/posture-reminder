#if DEBUG
import Foundation

/// 每秒一条的调试性能埋点。
///
/// 只在 DEBUG 构建里存在：一个后台计时器把上一秒的渲染帧数、最大帧间隔、各步耗时、点云点数与设备
/// 环境（热状态、电量、是否降级）汇总成一行 JSON，追加到 `Documents/debug/perf-<会话时间>.jsonl`，
/// 同时打到标准输出（`[perf] {...}`），这样 `devicectl device process launch --console` 和拉取沙盒
/// 两条路都能读到。
///
/// 它与 QA 的 42 键 JSONL 契约没有关系：另一个文件、另一套键名、另一个目录文件。
///
/// 键名（全部单位写进键名，避免 QA 二次换算）：
/// - `t`：这一行代表的那一秒结束时的 epoch 毫秒
/// - `frames` / `fps` / `frame_gap_ms`：该秒内点云画布实际绘制的帧数、帧率与相邻两帧最大间隔
/// - `render_ms_avg` / `render_ms_max`：画布重绘闭包本身的耗时（CPU 侧，含路径构造）
/// - `capture_ms_avg` / `capture_ms_max`：一个深度帧从 delegate 到深度数组的耗时
/// - `segment_ms_avg` / `segment_ms_max`：分割
/// - `cloud_ms_avg` / `cloud_ms_max`：点云取样
/// - `vision_ms_avg` / `vision_ms_max`：一次 Vision 推理 + 关节映射
/// - `assess_ms_avg` / `assess_ms_max`：一次姿态判定
/// - `cloud_frames` / `cloud_points`：该秒内发出的点云帧数，以及最后一帧的点数（应恒为 600）
/// - `cloud_gap_p95_ms` / `cloud_gap_max_ms`：该秒内相邻两帧点云更新间隔的 p95 与最大值；
///   068-2 的流畅门槛（未降级时 p95 ≤ 40 ms、最大 ≤ 200 ms）就按这两个键判
/// - `vision_calls` / `assess_count`：该秒内的推理次数与判定次数
/// - `thermal_state`：`nominal` / `fair` / `serious` / `critical`
/// - `battery_level`：0...1，设备不报告时为 null
/// - `degraded`：这一秒是否处于发热降级（Vision 5 Hz、点云 15 Hz）
/// - `window_s`：本行统计窗口的实际秒数（计时器漂移时不是整数 1）
final class PerfMonitor {
  static let shared = PerfMonitor()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "me.xieal.posturelab.perf", qos: .utility)
  private let file = DebugLineFile(prefix: "perf")

  private var timer: DispatchSourceTimer?
  private var windowStart = ProcessInfo.processInfo.systemUptime

  private var frames = 0
  private var lastFrameAt: TimeInterval?
  private var maxFrameGap: TimeInterval = 0
  private var renderTotal: TimeInterval = 0
  private var renderMax: TimeInterval = 0
  private var renderCalls = 0

  private var captureTotal: TimeInterval = 0
  private var captureMax: TimeInterval = 0
  private var captureCalls = 0
  private var segmentTotal: TimeInterval = 0
  private var segmentMax: TimeInterval = 0
  private var segmentCalls = 0
  private var cloudTotal: TimeInterval = 0
  private var cloudMax: TimeInterval = 0
  private var cloudCalls = 0
  private var cloudFrames = 0
  private var cloudPoints = 0
  private var cloudGaps: [TimeInterval] = []
  private var lastCloudFrameAt: TimeInterval?

  private var visionTotal: TimeInterval = 0
  private var visionMax: TimeInterval = 0
  private var visionCalls = 0
  private var assessTotal: TimeInterval = 0
  private var assessMax: TimeInterval = 0
  private var assessments = 0

  private var thermalState = "nominal"
  private var batteryLevel: Double?
  private var degraded = false

  private init() {}

  // MARK: - Lifecycle

  /// 幂等：重复调用只保留第一个计时器。
  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil else { return }
    windowStart = ProcessInfo.processInfo.systemUptime

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.flush() }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    lock.lock()
    timer?.cancel()
    timer = nil
    lock.unlock()
  }

  // MARK: - Recording

  /// 一次点云画布的实际绘制。
  func recordFrame() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    frames += 1
    if let last = lastFrameAt {
      maxFrameGap = max(maxFrameGap, now - last)
    }
    lastFrameAt = now
    lock.unlock()
  }

  /// 画布重绘闭包的耗时。
  func recordRender(seconds: TimeInterval) {
    lock.lock()
    renderCalls += 1
    renderTotal += seconds
    renderMax = max(renderMax, seconds)
    lock.unlock()
  }

  /// 深度帧从 delegate 到深度数组。
  func recordCapture(seconds: TimeInterval) {
    lock.lock()
    captureCalls += 1
    captureTotal += seconds
    captureMax = max(captureMax, seconds)
    lock.unlock()
  }

  func recordSegment(seconds: TimeInterval) {
    lock.lock()
    segmentCalls += 1
    segmentTotal += seconds
    segmentMax = max(segmentMax, seconds)
    lock.unlock()
  }

  /// 一次点云帧发出（30 Hz，降级 15 Hz）。相邻两帧的间隔是 068-2 的流畅证据。
  func recordCloudFrame(at now: TimeInterval) {
    lock.lock()
    if let last = lastCloudFrameAt {
      cloudGaps.append(now - last)
    }
    lastCloudFrameAt = now
    lock.unlock()
  }

  /// 一次点云取样，以及它产出的点数。
  func recordCloud(seconds: TimeInterval, points: Int) {
    lock.lock()
    cloudCalls += 1
    cloudTotal += seconds
    cloudMax = max(cloudMax, seconds)
    cloudFrames += 1
    cloudPoints = points
    lock.unlock()
  }

  /// 一次 Vision 推理（含关节映射）。
  func recordVision(seconds: TimeInterval) {
    lock.lock()
    visionCalls += 1
    visionTotal += seconds
    visionMax = max(visionMax, seconds)
    lock.unlock()
  }

  func recordAssessment(seconds: TimeInterval) {
    lock.lock()
    assessments += 1
    assessTotal += seconds
    assessMax = max(assessMax, seconds)
    lock.unlock()
  }

  /// 每秒由热状态采样器刷新；`degraded` 是采集源当前实际使用的负载。
  func recordEnvironment(thermalState: String, battery: Double?, degraded: Bool) {
    lock.lock()
    self.thermalState = thermalState
    self.batteryLevel = battery
    self.degraded = degraded
    lock.unlock()
  }

  // MARK: - One line per second

  private func flush() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let window = max(0.001, now - windowStart)
    let gaps = cloudGaps.sorted()
    let p95 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int((0.95 * Double(gaps.count - 1)).rounded()))]
    let line = Self.line(window: window,
                         frames: frames,
                         gap: maxFrameGap,
                         render: (renderCalls, renderTotal, renderMax),
                         capture: (captureCalls, captureTotal, captureMax),
                         segment: (segmentCalls, segmentTotal, segmentMax),
                         cloud: (cloudCalls, cloudTotal, cloudMax),
                         cloudFrames: cloudFrames,
                         cloudPoints: cloudPoints,
                         cloudGaps: (p95, gaps.last ?? 0),
                         vision: (visionCalls, visionTotal, visionMax),
                         assess: (assessments, assessTotal, assessMax),
                         thermalState: thermalState,
                         battery: batteryLevel,
                         degraded: degraded)
    frames = 0
    lastFrameAt = nil
    maxFrameGap = 0
    renderCalls = 0
    renderTotal = 0
    renderMax = 0
    captureCalls = 0
    captureTotal = 0
    captureMax = 0
    segmentCalls = 0
    segmentTotal = 0
    segmentMax = 0
    cloudCalls = 0
    cloudTotal = 0
    cloudMax = 0
    cloudFrames = 0
    cloudGaps = []
    lastCloudFrameAt = nil
    visionCalls = 0
    visionTotal = 0
    visionMax = 0
    assessments = 0
    assessTotal = 0
    assessMax = 0
    windowStart = now
    lock.unlock()

    file.write(line)
  }

  /// 纯函数，便于在测试里核对字段与换算。`(calls, total, max)` 是每一步的计数、累计与最大值。
  static func line(window: Double,
                   frames: Int,
                   gap: TimeInterval,
                   render: (Int, TimeInterval, TimeInterval),
                   capture: (Int, TimeInterval, TimeInterval),
                   segment: (Int, TimeInterval, TimeInterval),
                   cloud: (Int, TimeInterval, TimeInterval),
                   cloudFrames: Int,
                   cloudPoints: Int,
                   cloudGaps: (TimeInterval, TimeInterval) = (0, 0),
                   vision: (Int, TimeInterval, TimeInterval),
                   assess: (Int, TimeInterval, TimeInterval),
                   thermalState: String = "nominal",
                   battery: Double? = nil,
                   degraded: Bool = false) -> String {
    let fps = Double(frames) / window
    let epochMilliseconds = Int((Date().timeIntervalSince1970 * 1000).rounded())
    func average(_ step: (Int, TimeInterval, TimeInterval)) -> Double {
      step.0 > 0 ? step.1 / Double(step.0) : 0
    }
    func milliseconds(_ seconds: TimeInterval) -> String {
      String(format: "%.2f", seconds * 1000)
    }
    func batteryValue() -> String {
      guard let battery, battery.isFinite else { return "null" }
      return String(format: "%.2f", battery)
    }
    // 整数用插值而不是 %d：epoch 毫秒是 64 位，`%d` 会把它截成 32 位，QA 会读到负数。
    return "{\"t\":\(epochMilliseconds)"
      + ",\"frames\":\(frames)"
      + ",\"fps\":\(String(format: "%.1f", fps))"
      + ",\"frame_gap_ms\":\(milliseconds(gap))"
      + ",\"render_ms_avg\":\(milliseconds(average(render)))"
      + ",\"render_ms_max\":\(milliseconds(render.2))"
      + ",\"capture_ms_avg\":\(milliseconds(average(capture)))"
      + ",\"capture_ms_max\":\(milliseconds(capture.2))"
      + ",\"segment_ms_avg\":\(milliseconds(average(segment)))"
      + ",\"segment_ms_max\":\(milliseconds(segment.2))"
      + ",\"cloud_ms_avg\":\(milliseconds(average(cloud)))"
      + ",\"cloud_ms_max\":\(milliseconds(cloud.2))"
      + ",\"vision_ms_avg\":\(milliseconds(average(vision)))"
      + ",\"vision_ms_max\":\(milliseconds(vision.2))"
      + ",\"assess_ms_avg\":\(milliseconds(average(assess)))"
      + ",\"assess_ms_max\":\(milliseconds(assess.2))"
      + ",\"cloud_frames\":\(cloudFrames)"
      + ",\"cloud_points\":\(cloudPoints)"
      + ",\"cloud_gap_p95_ms\":\(milliseconds(cloudGaps.0))"
      + ",\"cloud_gap_max_ms\":\(milliseconds(cloudGaps.1))"
      + ",\"vision_calls\":\(vision.0)"
      + ",\"assess_count\":\(assess.0)"
      + ",\"thermal_state\":\"\(thermalState)\""
      + ",\"battery_level\":\(batteryValue())"
      + ",\"degraded\":\(degraded)"
      + ",\"window_s\":\(String(format: "%.2f", window))}"
  }
}
#endif
