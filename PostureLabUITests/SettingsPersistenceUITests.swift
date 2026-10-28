import XCTest

/// AC2: every setting on the settings page can be changed, and is still there after the app is killed
/// and started again.
///
/// One table drives all of it. `settings` below names each of the twelve rows of the settings spec
/// in `GLOSSARY.md`, in the order the page draws them, says how to read the value it shows and how
/// to change it through the control the page itself draws — so a thirteenth setting is one line
/// there, and the two passes below do not change. Each setting is photographed before and after
/// its change; the app is then killed, restarted with nothing overridden, walked back to the same
/// page and read row by row, and every value has to be the one that was set.
///
/// The screenshots leave as `XCTAttachment`s under the names `AC2-<nn>-<setting>-before|after` plus
/// `AC2-13-after-relaunch`; see `attachScreenshot`.
final class SettingsPersistenceUITests: XCTestCase {

  private var app: XCUIApplication!

  /// One row of the settings page: the name its screenshots carry, how to read the value the row
  /// shows, and how to change it through its own control.
  ///
  /// Both are closures because a form taller than the screen recycles its rows: every read and every
  /// change has to look the row up again where it is now.
  private struct Setting {
    let name: String
    let read: () -> String
    let change: () -> Void
  }

  /// The three sounds the 结束提示音 picker offers, in the order the page lists them.
  private static let endSounds = ["柔和铃声", "铃声", "静音"]

  /// The twelve settings of the domain spec (`GLOSSARY.md`). 姿态语音提醒 and its volume are one row
  /// of that spec — "开/关；音量" — so they are one case here too and are read and changed together.
  private var settings: [Setting] {
    [
      Setting(name: "focusMinutes",
              read: { self.stepperValue(of: "专注时长", unit: "分钟") },
              change: { self.step("专注时长", unit: "分钟") }),
      Setting(name: "shortBreakMinutes",
              read: { self.stepperValue(of: "短休息", unit: "分钟") },
              change: { self.step("短休息", unit: "分钟") }),
      Setting(name: "longBreakMinutes",
              read: { self.stepperValue(of: "长休息", unit: "分钟") },
              change: { self.step("长休息", unit: "分钟") }),
      Setting(name: "focusPerLongBreak",
              read: { self.stepperValue(of: "几个专注后长休息", unit: "个") },
              change: { self.step("几个专注后长休息", unit: "个") }),
      Setting(name: "autoStartBreak",
              read: { self.switchValue(of: "自动开始休息") },
              change: { self.flip("自动开始休息") }),
      Setting(name: "autoStartFocus",
              read: { self.switchValue(of: "自动开始下一个专注") },
              change: { self.flip("自动开始下一个专注") }),
      Setting(name: "dailyGoal",
              read: { self.stepperValue(of: "每日目标番茄数", unit: "个") },
              change: { self.step("每日目标番茄数", unit: "个") }),
      Setting(name: "endSound",
              read: { self.endSoundValue() },
              change: { self.chooseAnotherSound() }),
      Setting(name: "remindBeforeEnd",
              read: { self.switchValue(of: "结束前提醒") },
              change: { self.flip("结束前提醒") }),
      Setting(name: "postureVoice",
              read: { "\(self.switchValue(of: "姿态语音提醒")) \(self.volumeValue())" },
              change: { self.changeVoiceRow() }),
      Setting(name: "monitorDuringBreak",
              read: { self.switchValue(of: "休息时是否监测姿态") },
              change: { self.flip("休息时是否监测姿态") }),
      Setting(name: "keepScreenAwake",
              read: { self.switchValue(of: "屏幕常亮") },
              change: { self.flip("屏幕常亮") })
    ]
  }

  // MARK: - The test

  func testEverySettingSurvivesARelaunch() {
    app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(wait(upTo: 30, for: { self.settingsPageIsUp() }),
                  "the settings page did not open (arguments: \(app.launchArguments))")

    var expected: [String: String] = [:]
    for (index, setting) in settings.enumerated() {
      let before = setting.read()
      let stem = String(format: "AC2-%02d-%@", index + 1, setting.name)
      attachScreenshot(of: app, named: "\(stem)-before")

      setting.change()
      let after = setting.read()
      XCTAssertNotEqual(after, before, "\(setting.name) did not change through its own control")
      attachScreenshot(of: app, named: "\(stem)-after")
      expected[setting.name] = after
    }

    // Give the preferences daemon a beat to take the last write, so what is being tested is a value
    // that reached storage rather than one still in flight, and then kill the process.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    app.terminate()

    // Back with only `-pomodoro 1`: no setting is overridden on the command line and no launch
    // argument opens this page, so everything it shows has to come out of storage.
    app.launchArguments = PomodoroLaunch.withoutOverrides
    app.launch()

    // The gear on the child's screen, tapped rather than asked for.
    let gear = app.first(.button, labelled: "设置页")
    XCTAssertTrue(gear.waitForExistence(timeout: 30), "the child's screen never offered 设置页")
    gear.tap()

    XCTAssertTrue(wait(upTo: 10, for: { self.settingsPageIsUp() }),
                  "the settings page did not come back after the relaunch")
    attachScreenshot(of: app, named: "AC2-13-after-relaunch")

    for setting in settings {
      XCTAssertEqual(setting.read(), expected[setting.name],
                     "\(setting.name) did not survive the relaunch")
    }
  }

  /// Whether the settings page is on screen. It answers to two names: the 主页 button its bar carries
  /// as the way back to the child's screen, and the 设置页 title of the bar itself.
  private func settingsPageIsUp() -> Bool {
    app.first(.button, labelled: "主页").exists
      || app.first(.navigationBar, labelled: "设置页").exists
  }

  // MARK: - Finding a row

  /// The row that carries `title`, scrolled into view.
  ///
  /// A form taller than the screen only builds the rows near the viewport, so a row that is not there
  /// yet has to be scrolled to: down while it is below the window or not built at all, up when it is
  /// above. The settings are walked in the order the page draws them, so this only moves up for the
  /// one row of backtracking inside the voice row.
  @discardableResult
  private func reveal(_ title: String) -> XCUIElement {
    for _ in 0..<12 {
      let candidate = row(title)
      if candidate.exists && onScreen(candidate) { return candidate }
      // Only a row that is in the tree but lost above the window is worth going back up for: rows
      // below are both the ones out of view and the ones a form has not built yet.
      scrollForm(down: !isAbove(candidate))
    }
    let candidate = row(title)
    XCTAssertTrue(candidate.exists,
                  "the settings page has no row titled \(title); it shows \(app.cells.count) cells "
                    + "and texts \(app.staticTexts.allElementsBoundByIndex.map(\.label).prefix(12))")
    return candidate
  }

  /// The row that carries `title`.
  ///
  /// A form row is a cell and the title is a text inside it — but a control can also absorb its row's
  /// label into itself, so the row is looked for as a cell first and as a labelled control second.
  private func row(_ title: String) -> XCUIElement {
    let byText = app.cells.containing(.staticText, identifier: title).firstMatch
    if byText.exists { return byText }
    let byLabel = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    if byLabel.exists { return byLabel }
    for type in [XCUIElement.ElementType.stepper, .switch, .slider, .button, .other] {
      let merged = app.first(type, labelStartingWith: title)
      if merged.exists { return merged }
    }
    return byText
  }

  /// Whether a row is somewhere the test can read it, and tap it.
  ///
  /// Two things get in the way of a row that is only technically on screen: the navigation bar floats
  /// over the top of the form and takes taps aimed at a row under it, and a row the page has disabled
  /// — the volume slider while the voice switch is off — is never hittable at all. So a row counts as
  /// reachable when it is hittable, or when it sits inside the part of the window the form owns.
  private func onScreen(_ element: XCUIElement) -> Bool {
    element.isHittable || contentArea.contains(element.frame)
  }

  /// Whether a row is in the tree but scrolled above the top of the form.
  private func isAbove(_ element: XCUIElement) -> Bool {
    element.exists && element.frame.maxY <= contentArea.minY
  }

  /// The window minus the navigation bar, which is drawn over the top of the form.
  private var contentArea: CGRect {
    let window = app.frame
    let bar = app.navigationBars.firstMatch
    let top = bar.exists ? bar.frame.maxY : window.minY
    return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
  }

  /// Scrolls the form by about a third of a screen, from the rows' leading edge so the drag cannot
  /// land on a control — the volume slider fills the middle of its row.
  private func scrollForm(down: Bool) {
    let from = CGVector(dx: 0.08, dy: down ? 0.8 : 0.5)
    let to = CGVector(dx: 0.08, dy: down ? 0.5 : 0.8)
    app.coordinate(withNormalizedOffset: from)
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: to))
  }

  // MARK: - Reading a row

  /// The value an integer row shows, "25 分钟".
  private func stepperValue(of title: String, unit: String) -> String {
    let value = visibleValue(of: reveal(title), matching: "\\d+ \(unit)")
    XCTAssertNotNil(value, "\(title) shows no \"NN \(unit)\" value")
    return value ?? ""
  }

  /// The state of a switch in the page's own words.
  private func switchValue(of title: String) -> String {
    // A switch below the fold is not in the tree yet, so its row goes first.
    reveal(title)
    let control = app.first(.switch, labelStartingWith: title)
    guard control.exists, let raw = control.value as? String else {
      XCTFail("\(title) has no switch to read")
      return ""
    }
    // A switch reports itself as "1"/"0" whatever language the simulator is set to.
    XCTAssertTrue(raw == "0" || raw == "1", "the switch for \(title) reported \(raw)")
    return raw == "1" ? "开" : "关"
  }

  /// Which of the three sounds the 结束提示音 row shows.
  private func endSoundValue() -> String {
    let shown = Self.endSounds.first { shows(reveal("结束提示音"), $0) }
    XCTAssertNotNil(shown, "结束提示音 shows none of \(Self.endSounds)")
    return shown ?? ""
  }

  /// The volume the row shows, "80%".
  private func volumeValue() -> String {
    let value = visibleValue(of: reveal("音量"), matching: "\\d+%")
    XCTAssertNotNil(value, "the volume row shows no percentage")
    return value ?? ""
  }

  /// The first piece of a row's visible text that matches `pattern`: one of the texts it draws, the
  /// value the control itself reports, or the tail of a label that merged the row's title and its
  /// value. Which of the three a row offers depends on how SwiftUI merged it, and all three give the
  /// caller the same token.
  private func visibleValue(of element: XCUIElement, matching pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    var candidates = element.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
    if let own = element.value as? String { candidates.append(own) }
    candidates.append(element.label)
    for candidate in candidates {
      let range = NSRange(candidate.startIndex..., in: candidate)
      if let match = expression.firstMatch(in: candidate, range: range),
         let found = Range(match.range, in: candidate) {
        return String(candidate[found])
      }
    }
    return nil
  }

  /// Whether a row shows `text` as its value: one of its own texts, or the tail of a label that
  /// merged the row's title and its value, "结束提示音, 柔和铃声".
  private func shows(_ element: XCUIElement, _ text: String) -> Bool {
    let labels = element.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
      + [element.label]
    return labels.contains { $0 == text || $0.hasSuffix(", \(text)") || $0.hasSuffix(" \(text)") }
  }

  // MARK: - Changing a row

  /// Steps an integer row to another value.
  ///
  /// The stepper's two halves are used where the row keeps them in the tree and reached by coordinate
  /// where it does not — the control is drawn at the row's trailing edge — and either direction is
  /// tried, so a row parked on a limit still moves.
  private func step(_ title: String, unit: String) {
    let element = reveal(title)
    let before = stepperValue(of: title, unit: unit)
    let buttons = element.descendants(matching: .button).allElementsBoundByIndex
    let taps: [() -> Void]
    if buttons.count >= 2 {
      taps = [{ buttons[0].tap() }, { buttons[1].tap() }]
    } else {
      let outward = element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
      let inward = element.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5))
      taps = [{ outward.tap() }, { inward.tap() }]
    }
    for tap in taps {
      tap()
      // The row redraws its value a frame after the tap; give it that frame before deciding the tap
      // missed and trying the other half.
      if wait(upTo: 1, for: { self.stepperValue(of: title, unit: unit) != before }) { return }
    }
    XCTFail("\(title) did not move off \(before)")
  }

  private func flip(_ title: String) {
    reveal(title)
    let control = app.first(.switch, labelStartingWith: title)
    XCTAssertTrue(control.exists, "\(title) has no switch to tap")
    control.tap()
  }

  /// Picks the first sound that is not the one already selected.
  ///
  /// A picker inside a form either opens its options as a menu or pushes them as a list; both are
  /// followed, and the test is left on the settings page either way.
  private func chooseAnotherSound() {
    let current = endSoundValue()
    guard let next = Self.endSounds.first(where: { $0 != current }) else {
      return XCTFail("结束提示音 offers no other sound to choose")
    }
    reveal("结束提示音").tap()

    let option = optionElement(named: next)
    XCTAssertTrue(option.waitForExistence(timeout: 5), "the 结束提示音 options did not open")
    option.tap()

    // A pushed list is expected to come back on its own; when it does not, its bar's back button is
    // the way out — the settings page's own bar carries the 主页 button instead.
    if !wait(upTo: 3, for: { self.app.first(.button, labelled: "主页").isHittable }) {
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(row("结束提示音").waitForExistence(timeout: 5),
                  "the 结束提示音 row did not come back")
  }

  /// The option labelled `name`, in either shape the picker takes: a menu item is a button, a pushed
  /// row is a text inside a cell.
  private func optionElement(named name: String) -> XCUIElement {
    let byButton = app.first(.button, labelled: name)
    if byButton.exists { return byButton }
    return app.first(.staticText, labelled: name)
  }

  /// The voice row of the settings spec is a switch and a volume slider in one row, so they are
  /// changed together: the slider while the switch is on, because it greys out and stops taking taps
  /// when the switch is off, and then the switch into the state it was not in when the row was read.
  private func changeVoiceRow() {
    let wasOn = switchValue(of: "姿态语音提醒") == "开"
    if !wasOn { flip("姿态语音提醒") }

    let volume = volumeValue()
    for position in [CGFloat(0.35), 0.65, 0.15] {
      setVolume(to: position)
      if volumeValue() != volume { break }
    }
    XCTAssertNotEqual(volumeValue(), volume, "the volume slider did not move off \(volume)")

    if wasOn { flip("姿态语音提醒") }
  }

  /// Drags the volume slider to `position` (0...1). The row's only control with a label of its own is
  /// the slider, which is how the page names it for a test; the row is scrolled to first, because a
  /// form does not build a slider it is not showing.
  private func setVolume(to position: CGFloat) {
    reveal("音量")
    let slider = app.first(.slider, labelled: "姿态语音音量")
    XCTAssertTrue(slider.exists, "the volume slider is not on the page")
    slider.adjust(toNormalizedSliderPosition: position)
  }
}
