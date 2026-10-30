import XCTest

/// Where on 开始专注 a child may tap.
///
/// The button is a full-width capsule drawn around the word; the acceptance rule is that the whole
/// capsule is the target, not just the glyphs. This test parks a focus, taps each corner and each
/// edge of the button's own frame, and asks for 暂停 — the button that only appears once the focus
/// has started. Every point is tapped on a fresh launch so one success cannot hide the next.
///
/// The two outermost points (2%/98%) sit at the capsule's bounding-box corners; because the shape is
/// rounded they can fall outside the drawn capsule. The 8%/12% points are the "blank but still on the
/// capsule" points the rule is about. Both are measured and reported separately.
final class StartHitAreaUITests: XCTestCase {

  private struct Point {
    let name: String
    let dx: CGFloat
    let dy: CGFloat
  }

  /// Points on the button's own frame, normalized. Corners first, then edge midpoints.
  private let points: [Point] = [
    Point(name: "frame-corner-top-leading", dx: 0.02, dy: 0.02),
    Point(name: "frame-corner-top-trailing", dx: 0.98, dy: 0.02),
    Point(name: "frame-corner-bottom-leading", dx: 0.02, dy: 0.98),
    Point(name: "frame-corner-bottom-trailing", dx: 0.98, dy: 0.98),
    Point(name: "blank-top-leading", dx: 0.08, dy: 0.15),
    Point(name: "blank-top-trailing", dx: 0.92, dy: 0.15),
    Point(name: "blank-bottom-leading", dx: 0.08, dy: 0.85),
    Point(name: "blank-bottom-trailing", dx: 0.92, dy: 0.85),
    Point(name: "blank-leading-edge", dx: 0.05, dy: 0.5),
    Point(name: "blank-trailing-edge", dx: 0.95, dy: 0.5)
  ]

  func testTheWholeStartCapsuleStartsTheFocus() {
    continueAfterFailure = true
    var failures: [String] = []

    for point in points {
      let app = launchApp(PomodoroLaunch.parkedPreview())
      let start = app.first(.button, labelled: "开始专注")
      guard start.waitForExistence(timeout: 30) else {
        failures.append("\(point.name): the parked screen never appeared")
        app.terminate()
        continue
      }
      let frame = start.frame

      start.coordinate(withNormalizedOffset: CGVector(dx: point.dx, dy: point.dy)).tap()
      let started = app.first(.button, labelled: "暂停").waitForExistence(timeout: 6)
      if started {
        attachScreenshot(of: app, named: "AC-hit-\(point.name)")
      } else {
        failures.append("\(point.name): no 暂停 after tapping "
          + "(dx=\(point.dx), dy=\(point.dy)); button frame \(frame)")
      }
      app.terminate()
    }

    XCTAssertTrue(failures.isEmpty, "taps that did not start a focus: \(failures)")
  }
}
