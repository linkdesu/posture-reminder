#if DEBUG
import Foundation

/// 每个深度帧一行 `Documents/debug/frames-*.jsonl`：逐帧原始记录，不做每秒汇总。
///
/// 为什么需要它：`perf-*.jsonl` 是每秒一行的汇总，而汇总会把同一秒里的不同事实压成一个数
/// （0.6.8 (14) 的 `cloud_points` 只保留了该秒最后一帧的点数，于是「前几帧有人、最后一帧没人」
/// 的整秒看起来全是 0 点）。逐帧记录让 QA 不用猜：这一帧的深度有没有读数、分割出多少格、点云按
/// 预算生成了多少点、这一帧到底上了屏没有、上屏花了多久。
///
/// 一行 = 一个深度帧：
/// - `t`：写行时的 epoch 毫秒（上屏后写，所以它晚于帧本身的时刻）
/// - `frame_s`：深度帧自己的呈现时刻（会话时钟，秒），点云相机的真实节奏就是它
/// - `arrival_s`：回调到达时刻（会话时钟，秒）；与 `frame_s` 的差是这一帧在管线里排队的时间
/// - `depth_ms` / `segment_ms` / `cloud_ms`：取深度、分割、点云三步各自的耗时
/// - `points`：这一帧实际生成的点数（0 表示没有分割出人体）
/// - `mask_cells`：分割遮罩的格数（0 表示 `DepthSegmentation` 判定这一帧没有人）
/// - `depth_valid`：有效深度读数的占比（0...1）；它接近 1 而 `mask_cells` 是 0，说明传感器好好的，
///   只是画面里没有比背景近的人；它接近 0 才是传感器的问题
/// - `nearest_m`：这一帧最近的深度读数，米；没有读数时为 null
/// - `degraded`：这一帧是否处于发热降级
/// - `cloud_emitted`：这一帧的点云有没有推给画布（降级时会隔帧推）
/// - `render_ms`：画布重绘闭包为这一帧花的时间；这一帧被下一帧顶掉、或画布没在画（无人体时暂停）
///   时为 null
/// - `render_latency_ms`：从回调到达画布画出这一帧的延迟；同上，没上屏时为 null
final class FrameLog {
  static let shared = FrameLog()

  struct Record {
    var ts: Int
    var frameS: Double
    var arrivalS: Double
    var depthMS: Double
    var segmentMS: Double
    var cloudMS: Double
    var points: Int
    var maskCells: Int
    var depthValid: Double
    var nearestM: Double?
    var degraded: Bool
    var cloudEmitted: Bool
  }

  private let lock = NSLock()
  private let file = DebugLineFile(prefix: "frames")
  private var pending: Record?
  /// 待上屏那一帧的回调到达时刻（`systemUptime`），用来算上屏延迟。
  private var pendingArrivalUptime: TimeInterval = 0

  /// 深度线程调用：收下这一帧。上一帧如果还没上屏（被顶掉了），先按「未上屏」写出去，
  /// 不丢记录、也不把它的延迟算到别人头上。
  func begin(_ record: Record, arrivalUptime: TimeInterval) {
    lock.lock()
    let superseded = pending
    pending = record
    pendingArrivalUptime = arrivalUptime
    lock.unlock()
    if let superseded {
      file.write(Self.line(superseded, renderMS: nil, renderLatencyMS: nil))
    }
  }

  /// 画布线程调用：这一帧上屏了，补上渲染耗时与延迟后写行。
  func rendered(seconds: Double) {
    lock.lock()
    let record = pending
    let arrival = pendingArrivalUptime
    pending = nil
    lock.unlock()
    guard let record else { return }
    let latency = (ProcessInfo.processInfo.systemUptime - arrival) * 1000
    file.write(Self.line(record, renderMS: seconds * 1000, renderLatencyMS: max(0, latency)))
  }

  /// 采集停下时把还挂着的最后一帧写出去（未上屏）。
  func flushPending() {
    lock.lock()
    let record = pending
    pending = nil
    lock.unlock()
    guard let record else { return }
    file.write(Self.line(record, renderMS: nil, renderLatencyMS: nil))
  }

  /// 纯函数，字段名就是 QA 解析时用的键名。
  static func line(_ record: Record, renderMS: Double?, renderLatencyMS: Double?) -> String {
    "{\"t\":\(record.ts)"
      + ",\"frame_s\":\(fixed(record.frameS, 3))"
      + ",\"arrival_s\":\(fixed(record.arrivalS, 3))"
      + ",\"depth_ms\":\(fixed(record.depthMS, 2))"
      + ",\"segment_ms\":\(fixed(record.segmentMS, 2))"
      + ",\"cloud_ms\":\(fixed(record.cloudMS, 2))"
      + ",\"points\":\(record.points)"
      + ",\"mask_cells\":\(record.maskCells)"
      + ",\"depth_valid\":\(fixed(record.depthValid, 3))"
      + ",\"nearest_m\":\(number(record.nearestM))"
      + ",\"degraded\":\(record.degraded)"
      + ",\"cloud_emitted\":\(record.cloudEmitted)"
      + ",\"render_ms\":\(number(renderMS))"
      + ",\"render_latency_ms\":\(number(renderLatencyMS))}"
  }

  private static func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
  }

  private static func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.2f", value)
  }
}
#endif
