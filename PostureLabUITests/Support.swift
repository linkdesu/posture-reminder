import XCTest

/// How the UI tests start the app, and what they leave behind.
///
/// Every argument here is one `App.swift` already parses for the acceptance runner — `-settings 1`
/// for the settings page, `-scenario`/`-focusMinutes` for a scripted run, `-debug 0` to keep a
/// screenshot child-facing. The app launches on the child's screen with no arguments at all; the
/// tests add no flag of their own and no back door: what they check, they check by touching the
/// controls a child or a parent touches.
enum PomodoroLaunch {
  /// The settings page, opened before the first frame.
  static let settingsPage = ["-settings", "1"]

  /// The child's screen with nothing overridden: every value it shows comes from what the last run
  /// wrote down, which is the whole point of the relaunch in `SettingsPersistenceUITests`.
  static let withoutOverrides: [String] = []

  /// A scripted run, whose first focus starts on its own and whose countdown is `minutes` long.
  static func scriptedFocus(scenario: String, minutes: Int) -> [String] {
    ["-scenario", scenario, "-focusMinutes", String(minutes), "-debug", "0"]
  }
}

extension XCTestCase {

  /// The app under test, launched once with `arguments`.
  func launchApp(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    return app
  }

  /// Attaches a PNG of what the app is showing to the running test, under `name`, kept whatever the
  /// verdict.
  ///
  /// The attachment is the evidence: `.keepAlways` files it in the `.xcresult` under exactly this
  /// name, and
  ///
  ///     xcrun xcresulttool export attachments --path <run>.xcresult --output-path <dir> --filter "*.png"
  ///
  /// writes one PNG per attachment into `dir`, so the acceptance directory can be rebuilt from a test
  /// run and `manifest.json` says which file is which.
  func attachScreenshot(of app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Waits for `condition` to hold, and answers whether it does. UI state arrives a frame or two
  /// after the tap that asked for it and the countdown ticks once a second, so the checks in these
  /// tests are waits rather than single looks.
  @discardableResult
  func wait(upTo timeout: TimeInterval = 10, for condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }
}

extension XCUIApplication {

  /// The first element of `type` whose accessibility label is exactly `label`.
  ///
  /// Matching on the label rather than on the shorthand subscript — `buttons["暂停"]` matches the
  /// accessibility *identifier* — is what these screens need: their titles are Chinese text the app
  /// writes, and the two controls whose visible text cannot name them (the countdown and the volume
  /// slider) carry an explicit `accessibilityLabel` for exactly this.
  func first(_ type: XCUIElement.ElementType, labelled label: String) -> XCUIElement {
    first(type, matching: NSPredicate(format: "label == %@", label))
  }

  /// The first element of `type` whose accessibility label starts with `prefix`.
  ///
  /// A control can absorb its row's title and its value into one element — a stepper then reads
  /// "专注时长, 25 分钟" — so the label is matched from the front and the value read out of the tail.
  func first(_ type: XCUIElement.ElementType, labelStartingWith prefix: String) -> XCUIElement {
    first(type, matching: NSPredicate(format: "label BEGINSWITH %@", prefix))
  }

  private func first(_ type: XCUIElement.ElementType,
                     matching predicate: NSPredicate) -> XCUIElement {
    let typed = descendants(matching: type).matching(predicate).firstMatch
    if typed.exists { return typed }
    // A merged row can come back as some other element type than the control it draws, so the same
    // label is looked for once more without the type filter.
    return descendants(matching: .any).matching(predicate).firstMatch
  }
}
