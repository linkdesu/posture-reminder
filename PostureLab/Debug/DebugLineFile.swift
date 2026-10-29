#if DEBUG
import Foundation

/// 一行一条的调试文本日志。
///
/// 只活在 DEBUG 构建里，写到 `Documents/debug/<prefix>-<会话时间>.jsonl`，同时以 `[prefix]` 前缀
/// 打到标准输出，所以真机上 `devicectl device process launch --console` 和拉取沙盒两条路都能读到。
///
/// 它和 QA 的 42 键 JSONL 契约没有关系：另一个文件、另一套键名，`docs/qa-log-schema.md` 里的
/// 42 个键一个都不多、一个都不少。
final class DebugLineFile {
  private let prefix: String
  private let lock = NSLock()
  private var handle: FileHandle?

  init(prefix: String) {
    self.prefix = prefix
    open()
  }

  deinit {
    try? handle?.close()
  }

  func write(_ line: String) {
    print("[\(prefix)] \(line)")
    lock.lock()
    let handle = self.handle
    lock.unlock()
    guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
    try? handle.write(contentsOf: data)
  }

  private func open() {
    let directory = FileDebugLogger.defaultDirectory
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
      let url = directory.appendingPathComponent("\(prefix)-\(stamp).jsonl")
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
