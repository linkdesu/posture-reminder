import Foundation

/// 构建身份：版本号、build 号、commit。
///
/// 每一份调试日志的第一行都会带上它（`DebugLineFile` 的 header 行、会话日志的 `log_header` 事件），
/// 这样一份从手机上拷出来的日志不必再问「这是哪个构建」。
///
/// 版本号与 build 号来自 Info.plist；commit 由构建脚本（`project.yml` 的 `GitCommit` 阶段）在
/// 构建时写进 bundle 的 `GitCommit.txt`——不在源文件里写死 hash，否则每个提交都要手改一次。
enum AppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  }

  static var commit: String {
    guard let url = Bundle.main.url(forResource: "GitCommit", withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown" : trimmed
  }

  /// `0.6.8 (16) 496060c`——日志第一行与报告里用的同一种写法。
  static var summary: String { "\(version) (\(build)) \(commit)" }
}
