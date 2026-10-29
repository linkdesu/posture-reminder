#if DEBUG
import Foundation

/// `Documents/debug/idle-*.jsonl`：常亮取证日志，同时以 `[idle]` 前缀打到标准输出。
/// 与 QA 的 42 键契约无关（另一个文件、另一套键名）。第一次写入时才建文件。
final class IdleTimerDebugLog {
  static let shared = IdleTimerDebugLog()

  private lazy var file = DebugLineFile(prefix: "idle")

  func write(_ line: String) {
    file.write(line)
  }
}
#endif
