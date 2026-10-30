import XCTest
@testable import PostureLab

/// 抖动的量化口径：只在「静止帧」上统计（这一帧原始输入的平均/最大位移 ≤ 0.5% 屏宽），取滚动 10 秒
/// 窗口内的位移 p95。单位是屏宽比例，所以 1% 抖动就是 0.01。
///
/// 验收门槛在 `verify.py device-logs` 里（关键点 1%、点云 2%）；这里只钉住「数字本身怎么算」。
final class JitterMeterTests: XCTestCase {
  private func feed(_ meter: inout JitterMeter, _ value: Double, count: Int,
                    from start: TimeInterval = 0) {
    // 每秒 30 帧地把同一个位移喂进去。
    for index in 0..<count {
      let t = start + Double(index) / 30
      _ = meter.record(displacements: [value], rawShift: 0.001, at: t)
    }
  }

  func testASteadyNoiseAroundOnePercentReportsAboutOnePercent() throws {
    var meter = JitterMeter()
    feed(&meter, 0.010, count: 300)
    let p95 = try XCTUnwrap(meter.p95(at: 9.9))
    XCTAssertEqual(p95, 0.010, accuracy: 0.001)
  }

  func testTheTopTenPercentOfJumpsRaiseTheP95() throws {
    var meter = JitterMeter()
    // 120 个安静样本 + 12 个大跳（静止门槛放行，位移本身很大）；前 0.3 s 是平滑尾巴，不计。
    for index in 0..<120 {
      _ = meter.record(displacements: [0.002], rawShift: 0.001, at: Double(index) * 0.03)
    }
    for index in 120..<132 {
      _ = meter.record(displacements: [0.03], rawShift: 0.001, at: Double(index) * 0.03)
    }
    // 120 个有效样本的 p95 落在排序后第 114 位，也就是那 12 个大跳里的第一个。
    let p95 = try XCTUnwrap(meter.p95(at: 3.96))
    XCTAssertEqual(p95, 0.03, accuracy: 0.001)
  }

  func testOnlyTheLastTenSecondsCount() throws {
    var meter = JitterMeter()
    feed(&meter, 0.03, count: 300)          // 0–10 s：大抖动
    feed(&meter, 0.002, count: 300, from: 20)  // 20–30 s：安静
    let p95 = try XCTUnwrap(meter.p95(at: 29.9))
    XCTAssertEqual(p95, 0.002, accuracy: 0.001, "10 s 之前的大抖动必须滚出窗口")
  }

  /// 孩子在真动的那一帧不算抖动：原始位移超过 0.5% 屏宽就不进直方图。
  func testMovingFramesAreNotCountedAsJitter() {
    var meter = JitterMeter()
    for index in 0..<300 {
      let recorded = meter.record(displacements: [0.02], rawShift: 0.02,
                                  at: Double(index) / 30)
      XCTAssertFalse(recorded)
    }
    XCTAssertNil(meter.p95(at: 9.9))
    XCTAssertEqual(meter.sampleCount(at: 9.9), 0)
  }

  /// 刚开始静止的 0.3 s 是「平滑尾巴」：那一刻屏幕上还在追上一下的输入，不是抖动。
  func testTheFirstMomentOfStillnessIsSettlingNotJitter() {
    var meter = JitterMeter()
    XCTAssertFalse(meter.record(displacements: [0.004], rawShift: 0.005, at: 0))
    XCTAssertFalse(meter.record(displacements: [0.004], rawShift: 0.005, at: 0.2))
    XCTAssertTrue(meter.record(displacements: [0.004], rawShift: 0.005, at: 0.31))
    XCTAssertEqual(meter.sampleCount(at: 0.31), 1)
  }

  /// 一次真实的移动之后，平滑尾巴那几帧也不进直方图；重新静止满 0.3 s 才恢复计数。
  func testAFrameAfterAMoveDoesNotCountUntilTheFigureSettles() {
    var meter = JitterMeter()
    _ = meter.record(displacements: [0.02], rawShift: 0.02, at: 0)   // 孩子在动
    _ = meter.record(displacements: [0.001], rawShift: 0.001, at: 0.1)  // 停下，尾巴还在走
    XCTAssertEqual(meter.sampleCount(at: 0.2), 0)
    _ = meter.record(displacements: [0.001], rawShift: 0.001, at: 0.45)
    XCTAssertEqual(meter.sampleCount(at: 0.45), 1)
  }

  func testTooFewSamplesIsNotAnAnswer() {
    var meter = JitterMeter()
    feed(&meter, 0.01, count: 20)
    XCTAssertNil(meter.p95(at: 1), "20 个样本不足以谈 p95")
  }

  /// 位移超过 4% 屏宽的点归入最后一档：它们已经是「动」而不是「抖」，但也不能把窗口算丢。
  func testHugeDisplacementsClampIntoTheLastBin() throws {
    var meter = JitterMeter()
    feed(&meter, 0.5, count: 300)
    XCTAssertEqual(try XCTUnwrap(meter.p95(at: 9.9)), Double(JitterMeter.binCount) * JitterMeter.binWidth,
                   accuracy: 1e-9)
  }
}
