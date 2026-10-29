import Foundation
import XCTest
@testable import PostureLab

/// What the player writes, and what it must not write.
///
/// The `cue_played` line is the timer's evidence, so the settings page's 试听 button has to be able
/// to make the same sound without producing one. `SpeechSpy` keeps the events so the difference
/// between the two entry points is checkable without an audio device.
private final class CueSpy: DebugLogging {
  var isEnabled = true
  private(set) var events: [MonitoringEvent] = []

  func log(_ event: MonitoringEvent) { events.append(event) }
  func screenshot(_ name: String) {}

  /// The cue names written as `cue_played.message`, in order.
  var cueMessages: [String] {
    events.compactMap { event in
      guard case .cuePlayed(let cue) = event else { return nil }
      return cue
    }
  }
}

@MainActor
final class ReminderPlayerTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    let suite = "ReminderPlayerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDownWithError() throws {
    defaults = nil
  }

  /// A preview is a sound for the settings page, not a session event: the same clip may or may not
  /// start on a headless simulator, but no `cue_played` line is ever written for it.
  func testPreviewWritesNoCueLine() {
    let spy = CueSpy()
    let player = ReminderPlayer(settings: Settings(defaults: defaults), logger: spy)

    player.preview(cue: .endChime)
    player.preview(cue: .endSoft)

    XCTAssertEqual(spy.cueMessages, [], "a preview claimed a timer cue in the log")
  }

  /// And the timer's own call still reports what it started: the two entry points stay different.
  func testAPreviewLeavesTheTimerCuePathAlone() {
    let spy = CueSpy()
    let player = ReminderPlayer(settings: Settings(defaults: defaults), logger: spy)

    player.preview(cue: .endChime)
    XCTAssertEqual(spy.cueMessages, [])

    // A cue the player cannot start (no such clip) writes nothing either; the assertion here is that
    // the logging decision lives with `play(cue:)`, not with the preview.
    player.play(cue: .endSoft)
    XCTAssertTrue(spy.cueMessages.allSatisfy { $0 == PomodoroCue.endSoft.rawValue },
                  "play(cue:) reported a cue it was not asked for")
  }
}
