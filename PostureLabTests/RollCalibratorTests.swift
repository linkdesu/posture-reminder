import XCTest
@testable import PostureLab

/// 横滚校准：3 秒中位数成为个人基线；样本太少时不假装校准过。
final class RollCalibratorTests: XCTestCase {
  func testTheMedianOfTheFirstThreeSecondsBecomesTheBaseline() {
    var calibrator = RollCalibrator()
    for step in 0...30 {
      calibrator.observe(8 + Double(step % 3), at: Double(step) / 10)
    }
    XCTAssertTrue(calibrator.isSettled)
    XCTAssertEqual(try XCTUnwrap(calibrator.baseline), 9, accuracy: 1.5)
    XCTAssertEqual(try XCTUnwrap(calibrator.relative(24)), 15, accuracy: 1.5)
  }

  func testTooFewSamplesSettlesWithoutABaseline() {
    var calibrator = RollCalibrator()
    calibrator.observe(12, at: 0)
    calibrator.observe(13, at: 3.2)
    XCTAssertTrue(calibrator.isSettled)
    XCTAssertNil(calibrator.baseline)
    XCTAssertEqual(try XCTUnwrap(calibrator.relative(20)), 20, accuracy: 1e-9,
                   "without a baseline the angle is passed through unchanged")
  }

  func testAnglesAfterSettlingDoNotChangeTheBaseline() {
    var calibrator = RollCalibrator()
    for step in 0...30 { calibrator.observe(0, at: Double(step) / 10) }
    let settled = calibrator.baseline
    calibrator.observe(40, at: 10)
    XCTAssertEqual(calibrator.baseline, settled)
  }
}
