import XCTest

/// The parent-facing name for absence. Docs and acceptance call the state 无人; the report legend
/// says 不在画面, because that is what a parent reads on the history page.
///
/// The seeded history is deterministic: its last day always carries at least one absence segment,
/// so the label is in the day view's legend from the first frame.
final class ReportCopyUITests: XCTestCase {

  func testReportCallsAbsenceNotInFrame() {
    let app = launchApp(["-seedHistory", "30", "-report", "day"])

    XCTAssertTrue(app.first(.staticText, labelled: "不在画面").waitForExistence(timeout: 30),
                  "the report legend never showed 不在画面")
    XCTAssertFalse(app.first(.staticText, labelled: "无人").exists,
                   "the report legend still uses the docs term 无人")
    attachScreenshot(of: app, named: "AC-report-not-in-frame")
  }
}
