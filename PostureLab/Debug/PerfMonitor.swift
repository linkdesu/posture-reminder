#if DEBUG
import Foundation

/// 每秒一条的调试性能埋点。
///
/// 只在 DEBUG 构建里存在：一个后台计时器把上一秒的点云渲染帧数、最大帧间隔、关节推算耗时和
/// 姿态判定次数汇总成一行 JSON，追加到 `Documents/debug/perf-<会话时间>.jsonl`，同时打到标准
/// 输出（`[perf] {...}`），这样 `devicectl device process launch --console` 和拉取沙盒两条路
/// 都能读到。
///
/// 它与 QA 的 42 键 JSONL 契约没有关系：另一个文件、另一套键名、另一个目录文件，
/// `docs/qa-log-schema.md` 里的 42 个键一个都不多、一个都不少。
///
/// 键名（全部单位写进键名，避免 QA 二次换算）：
/// - `t`：这一行代表的那一秒结束时的 epoch 毫秒
/// - `frames`：该秒内点云画布实际绘制的帧数
/// - `fps`：`frames / window_s`，该秒的渲染帧率
/// - `frame_gap_ms`：该秒内相邻两帧之间的最大间隔，毫秒
/// - `joint_ms_avg` / `joint_ms_max`：该秒内每次关节推算的平均/最大耗时，毫秒
/// - `joint_calls`：该秒内的关节推算次数
/// - `assess_count`：该秒内的姿态判定次数（每个姿态样本判定一次）
/// - `window_s`：本行统计窗口的实际秒数（计时器漂移时不是整数 1）
final class PerfMonitor {
  static let shared = PerfMonitor()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "me.xieal.posturelab.perf", qos: .utility)

  private var timer: DispatchSourceTimer?
  private var handle: FileHandle?
  private var windowStart = ProcessInfo.processInfo.systemUptime

  private var frames = 0
  private var lastFrameAt: TimeInterval?
  private var maxFrameGap: TimeInterval = 0
  private var jointTotal: TimeInterval = 0
  private var jointMax: TimeInterval = 0
  private var jointCalls = 0
  private var assessments = 0

  private init() {}

  // MARK: - Lifecycle

  /// 幂等：重复调用只保留第一个计时器。
  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil else { return }
    windowStart = ProcessInfo.processInfo.systemUptime
    openLogFile()

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
    try? handle?.close()
    handle = nil
    lock.unlock()
  }

  // MARK: - Recording

  /// 一次点云画布的实际绘制。`rendersAsynchronously` 打开后这个闭包在后台线程跑，所以计数要加锁。
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

  func recordJointEstimate(seconds: TimeInterval) {
    lock.lock()
    jointCalls += 1
    jointTotal += seconds
    jointMax = max(jointMax, seconds)
    lock.unlock()
  }

  func recordAssessment() {
    lock.lock()
    assessments += 1
    lock.unlock()
  }

  // MARK: - One line per second

  private func flush() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let window = max(0.001, now - windowStart)
    let line = Self.line(window: window,
                         frames: frames,
                         gap: maxFrameGap,
                         jointTotal: jointTotal,
                         jointMax: jointMax,
                         jointCalls: jointCalls,
                         assessments: assessments)
    frames = 0
    lastFrameAt = nil
    maxFrameGap = 0
    jointTotal = 0
    jointMax = 0
    jointCalls = 0
    assessments = 0
    windowStart = now
    let handle = self.handle
    lock.unlock()

    print("[perf] \(line)")
    if let handle, let data = (line + "\n").data(using: .utf8) {
      try? handle.write(contentsOf: data)
    }
  }

  /// 纯函数，便于在测试里核对字段与换算。
  private static func line(window: Double,
                           frames: Int,
                           gap: TimeInterval,
                           jointTotal: TimeInterval,
                           jointMax: TimeInterval,
                           jointCalls: Int,
                           assessments: Int) -> String {
    let fps = Double(frames) / window
    let jointAverage = jointCalls > 0 ? jointTotal / Double(jointCalls) : 0
    let epochMilliseconds = Int((Date().timeIntervalSince1970 * 1000).rounded())
    return String(
      format: "{\"t\":%d,\"frames\":%d,\"fps\":%.1f,\"frame_gap_ms\":%.1f,"
        + "\"joint_ms_avg\":%.2f,\"joint_ms_max\":%.2f,\"joint_calls\":%d,"
        + "\"assess_count\":%d,\"window_s\":%.2f}",
      epochMilliseconds, frames, fps, gap * 1000,
      jointAverage * 1000, jointMax * 1000, jointCalls,
      assessments, window)
  }

  // MARK: - File

  private func openLogFile() {
    let directory = FileDebugLogger.defaultDirectory
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
      let url = directory.appendingPathComponent("perf-\(stamp).jsonl")
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: url)
      _ = try handle.seekToEnd()
      self.handle = handle
    } catch {
      // 埋点写不了文件也必须让标准输出继续工作，绝不把错误抛给调用方。
    }
  }
}
#endif
