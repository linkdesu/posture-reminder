#if DEBUG
import Foundation

/// 一行一条的调试文本日志。
///
/// 只活在 DEBUG 构建里，写到 `Documents/debug/<prefix>-<会话时间>.jsonl`，同时以 `[prefix]` 前缀
/// 打到标准输出，所以真机上 `devicectl device process launch --console` 和拉取沙盒两条路都能读到。
///
/// **文件在第一次写入时才创建**：没有内容的一次运行（模拟器没有深度、没有 Vision）不该在容器里
/// 留下一个 0 字节的 `.jsonl`——那既不是证据，也会被 `audit-sandbox.py` 判成「首行不是 JSON」。
///
/// 它和 QA 的 43 键 JSONL 契约没有关系：另一个文件、另一套键名，`docs/qa-log-schema.md` 里的
/// 45 个键一个都不多、一个都不少。
final class DebugLineFile {
  private let prefix: String
  private let lock = NSLock()
  private var handle: FileHandle?
  private var opened = false

  init(prefix: String) {
    self.prefix = prefix
  }

  deinit {
    try? handle?.close()
  }

  func write(_ line: String) {
    print("[\(prefix)] \(line)")
    lock.lock()
    if !opened {
      open()
      opened = true
    }
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
      // 第一行固定是构建身份：一个从手机里拷出来的日志文件不必再问「这是哪个构建」。
      let epoch = Int((Date().timeIntervalSince1970 * 1000).rounded())
      let header = "{\"t\":\(epoch),\"header\":\"log\",\"version\":\"\(AppInfo.version)\""
        + ",\"build\":\"\(AppInfo.build)\",\"commit\":\"\(AppInfo.commit)\"}\n"
      if let data = header.data(using: .utf8) {
        try? handle.write(contentsOf: data)
      }
      self.handle = handle
    } catch {
      // 埋点写不了文件也必须让标准输出继续工作，绝不把错误抛给调用方。
    }
  }
}
#endif
