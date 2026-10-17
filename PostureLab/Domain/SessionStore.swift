import Foundation

final class SessionStore {
  static let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

  private static let fileName = "sessions.json"
  private static let maxSessions = 20

  private let fileURL: URL

  private(set) var sessions: [SessionSummary]

  init(directory: URL = SessionStore.defaultDirectory) {
    fileURL = directory.appendingPathComponent(SessionStore.fileName)

    let stored = try? Data(contentsOf: fileURL)
    let decoded = stored.flatMap { try? JSONDecoder().decode([SessionSummary].self, from: $0) }
    sessions = decoded ?? []
  }

  func add(_ summary: SessionSummary) {
    sessions.insert(summary, at: 0)
    if sessions.count > SessionStore.maxSessions {
      sessions.removeLast(sessions.count - SessionStore.maxSessions)
    }
    persist()
  }

  var last: SessionSummary? { sessions.first }

  private func persist() {
    guard let data = try? JSONEncoder().encode(sessions) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
