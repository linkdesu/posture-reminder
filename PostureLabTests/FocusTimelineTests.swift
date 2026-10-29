import Foundation
import XCTest
@testable import PostureLab

/// The「识别中」段, the「无数据」段 and the timeline's sum invariant. The arrival shapes the briefs
/// name — an immediate first sample, one 1.4 s late, one that never comes, and a stream that stalls
/// after the first sample — asserted on the pure timeline so the rules are proved without a camera,
/// a timer or a view.
final class FocusTimelineTests: XCTestCase {
  private let planned: TimeInterval = 60

  /// AC: 首样本即时到达. A sample that is already there at the tap leaves no band: there was no wait
  /// to draw.
  func testAnImmediateFirstSampleLeavesNoDetectingBand() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    XCTAssertNil(timeline.observe(PostureStatus.good.rawValue, at: 1_000))
    XCTAssertNil(timeline.finished(at: 1_000 + planned))

    XCTAssertEqual(timeline.segments.map(\.kind), [PostureStatus.good.rawValue])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// AC: 首样本晚到 1.4 s. The gap is its own segment, closed by the first sample, and the sum is
  /// still the plan - the 1.4 s is taken out of the posture band, not added to the total.
  func testAFirstSampleArrivingLateKeepsTheGapAsItsOwnDetectingSegment() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)

    let detecting = timeline.observe(PostureStatus.good.rawValue, at: 1_001.4)
    XCTAssertEqual(timeline.detectingSince, nil)
    XCTAssertEqual(detecting?.kind, PostureSegment.detectingKind)
    XCTAssertEqual(detecting?.seconds ?? 0, 1.4, accuracy: 1e-9)
    XCTAssertEqual(detecting?.start, 1_000)
    XCTAssertEqual(detecting?.end, 1_001.4)

    XCTAssertNil(timeline.finished(at: 1_000 + planned))
    XCTAssertEqual(timeline.segments.map(\.kind),
                   [PostureSegment.detectingKind, PostureStatus.good.rawValue])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// AC: 首样本一直没来. The focus still has a timeline: one「识别中」段 covering the whole plan, so the
  /// parent reads a focus that ran and a camera that never answered, not an empty day.
  func testAFirstSampleThatNeverArrivesStillAddsUpToThePlan() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)

    // The ticker's gap check has nothing to cut here: the「识别中」段 already covers the silence,
    // so a missing first sample can never turn into a second band.
    timeline.noteSampleGap(at: 1_010)

    let detecting = timeline.finished(at: 1_000 + planned)
    XCTAssertEqual(detecting?.seconds ?? 0, planned, accuracy: 1e-9)
    XCTAssertEqual(timeline.segments.map(\.kind), [PostureSegment.detectingKind])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
    XCTAssertNil(timeline.detectingSince)
  }

  /// The detecting band is never merged into the first posture: a posture change later in the focus
  /// splits the band it is in, leaving the detecting segment where it was.
  func testPostureChangesSplitTheBandWithoutTouchingTheDetectingSegment() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    XCTAssertNotNil(timeline.observe(PostureStatus.good.rawValue, at: 1_000.5))
    XCTAssertNil(timeline.observe(PostureKind.near.rawValue, at: 1_030))
    XCTAssertNil(timeline.finished(at: 1_060))

    XCTAssertEqual(timeline.segments.map(\.kind), [
      PostureSegment.detectingKind,
      PostureStatus.good.rawValue,
      PostureKind.near.rawValue,
    ])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// A pause is wall time outside the countdown, so it is drawn but not counted: the sum stays the
  /// plan even when a pause stretches the band.
  func testPausedTimeIsDrawnButOutsideTheCountedSum() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    timeline.observe(PostureStatus.good.rawValue, at: 1_000.2)
    timeline.observe(PostureSegment.pausedKind, at: 1_010)
    timeline.observe(PostureStatus.good.rawValue, at: 1_020)
    // The pause held the countdown, so the focus closes ten seconds past `planned`.
    timeline.finished(at: 1_070)

    XCTAssertEqual(timeline.segments.map(\.kind), [
      PostureSegment.detectingKind,
      PostureStatus.good.rawValue,
      PostureSegment.pausedKind,
      PostureStatus.good.rawValue,
    ])
    // 0.2 detecting + 9.8 good + 10 paused + 50 good: the two good bands plus detecting are the
    // plan, and the paused band is drawn without being counted.
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// v0.6.1 AC: 首样本后无样本停留. The stream stalls after a good sample - the parent opened the
  /// report, so the camera was given up - and the band closes at its **last sample**, not at the
  /// tick that noticed the silence and not at the sample that resumes it. The stretch in between is
  /// one `no_data` band: same pale grey as 「识别中」, never a `PostureStatus`, so it can neither be
  /// scored nor inflate 良好.
  func testASampleGapAfterTheFirstSampleBecomesNoData() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    timeline.observe(PostureStatus.good.rawValue, at: 1_000.5)
    timeline.observe(PostureStatus.good.rawValue, at: 1_002)

    // 0.7 s of silence is a late frame, not a stopped stream: the good band is still open, so the
    // only closed segment is the「识别中」one.
    timeline.noteSampleGap(at: 1_002.7)
    XCTAssertEqual(timeline.segments.map(\.kind), [PostureSegment.detectingKind])

    // The parent's visit to the report: four seconds with no sample. The good band is closed where
    // its evidence ended (1_002), and the gap from there is `no_data`.
    timeline.noteSampleGap(at: 1_006)
    XCTAssertEqual(timeline.segments.map(\.kind),
                   [PostureSegment.detectingKind, PostureStatus.good.rawValue])

    // The next sample closes the no_data band and opens a posture one.
    let noData = timeline.observe(PostureKind.near.rawValue, at: 1_030)
    XCTAssertEqual(noData?.kind, PostureSegment.noDataKind)
    XCTAssertEqual(noData?.start, 1_002)
    XCTAssertEqual(noData?.end, 1_030)
    XCTAssertEqual(noData?.seconds ?? .nan, 28, accuracy: 1e-9)

    XCTAssertNil(PostureStatus(rawValue: PostureSegment.noDataKind),
                 "no_data is a timeline band, never a state")
    XCTAssertEqual(PosturePalette.color(for: PostureSegment.noDataKind),
                   PosturePalette.color(for: PostureSegment.detectingKind),
                   "无数据 uses the same pale grey as 识别中")

    XCTAssertNil(timeline.finished(at: 1_060))
    XCTAssertEqual(timeline.segments.map(\.kind), [
      PostureSegment.detectingKind,
      PostureStatus.good.rawValue,
      PostureSegment.noDataKind,
      PostureKind.near.rawValue,
    ])
    // The good band was credited for its 1.5 s of evidence only, not for the report visit.
    let good = timeline.segments.first { $0.kind == PostureStatus.good.rawValue }
    XCTAssertEqual(good?.seconds ?? .nan, 1.5, accuracy: 1e-9)
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// A stall the next sample never ends still closes at the finish, and the plan still adds up:
  /// 0.5 detecting + 1.5 good + 58 no_data = 60.
  func testAnUnrecoveredGapClosesAtTheFinish() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    timeline.observe(PostureStatus.good.rawValue, at: 1_000.5)
    timeline.observe(PostureStatus.good.rawValue, at: 1_002)
    timeline.noteSampleGap(at: 1_005)

    let closed = timeline.finished(at: 1_060)
    XCTAssertEqual(closed?.kind, PostureSegment.noDataKind)
    XCTAssertEqual(closed?.start, 1_002)
    XCTAssertEqual(closed?.end, 1_060)
    XCTAssertEqual(timeline.segments.map(\.kind), [
      PostureSegment.detectingKind,
      PostureStatus.good.rawValue,
      PostureSegment.noDataKind,
    ])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// A pause keeps its meaning: silence during a pause is still the pause band, not `no_data`. The
  /// focus closes 25 s past the plan because the pause held the countdown, and the counted sum is
  /// still the plan.
  func testAPauseBandIsNotTurnedIntoNoData() {
    var timeline = FocusTimeline()
    timeline.started(at: 1_000)
    timeline.observe(PostureStatus.good.rawValue, at: 1_000.2)
    timeline.observe(PostureSegment.pausedKind, at: 1_010)
    // Twenty seconds of silence inside the pause: the paused band stays paused.
    timeline.noteSampleGap(at: 1_030)
    timeline.observe(PostureStatus.good.rawValue, at: 1_035)
    timeline.finished(at: 1_085)

    XCTAssertEqual(timeline.segments.map(\.kind), [
      PostureSegment.detectingKind,
      PostureStatus.good.rawValue,
      PostureSegment.pausedKind,
      PostureStatus.good.rawValue,
    ])
    XCTAssertEqual(timeline.countedSeconds, planned, accuracy: 0.001)
  }

  /// The detecting kind is a timeline band, never a `state`: the aggregation's `PostureStatus` gate
  /// is what keeps it out of the posture statistics and the good-posture ratio.
  func testDetectingIsNotAPostureStatus() {
    XCTAssertNil(PostureStatus(rawValue: PostureSegment.detectingKind))
    XCTAssertNil(PostureStatus(rawValue: PostureSegment.noDataKind))
    XCTAssertEqual(PostureSegment.detectingKind, "detecting")
    XCTAssertEqual(PostureSegment.noDataKind, "no_data")
    XCTAssertEqual(PostureSegment.detectingKind, PosturePalette.detectingKind)
    XCTAssertEqual(PostureSegment.noDataKind, PosturePalette.noDataKind)
    XCTAssertNotEqual(PostureSegment.detectingKind, PostureStatus.noPerson.rawValue)
    XCTAssertNotEqual(PostureSegment.detectingKind, PostureSegment.pausedKind)
    XCTAssertNotEqual(PostureSegment.noDataKind, PostureSegment.detectingKind)
    XCTAssertNotEqual(PostureSegment.noDataKind, PostureSegment.pausedKind)
  }
}

/// The log side of the same segment: one `segment` line, its own four keys, and no change to the
/// key set every other line carries.
final class SegmentLogTests: XCTestCase {
  func testADetectingSegmentWritesItsOwnLineAndKeys() throws {
    let record = MonitoringEvent
      .segment(kind: PostureSegment.detectingKind, start: 1_000, end: 1_001.4)
      .logRecord(now: Date(timeIntervalSince1970: 1_002))

    XCTAssertEqual(record.event, "segment")
    XCTAssertEqual(record.segment_kind, "detecting")
    XCTAssertEqual(record.segment_start, 1_000_000)
    XCTAssertEqual(record.segment_end, 1_001_400)
    XCTAssertEqual(try XCTUnwrap(record.segment_seconds), 1.4, accuracy: 1e-6)

    let data = try JSONEncoder().encode(record)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(fields.count, 42, "the log contract carries 42 keys from v0.6 on")
    XCTAssertEqual(fields["segment_kind"] as? String, "detecting")
  }

  /// v0.6.1: `no_data` rides the same event and the same 42 keys; only the `segment_kind` value is
  /// new, so a reader's key set is unchanged.
  func testANoDataSegmentReusesTheSameFourKeys() throws {
    let record = MonitoringEvent
      .segment(kind: PostureSegment.noDataKind, start: 1_002, end: 1_030)
      .logRecord(now: Date(timeIntervalSince1970: 1_031))

    XCTAssertEqual(record.event, "segment")
    XCTAssertEqual(record.segment_kind, "no_data")
    XCTAssertEqual(record.segment_start, 1_002_000)
    XCTAssertEqual(record.segment_end, 1_030_000)
    XCTAssertEqual(try XCTUnwrap(record.segment_seconds), 28, accuracy: 1e-6)

    let data = try JSONEncoder().encode(record)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(fields.count, 42)
    XCTAssertEqual(fields["segment_kind"] as? String, "no_data")
  }

  /// Every other line still carries the four keys, as `null`: a reader never has to check presence.
  func testOtherLinesCarryTheSegmentKeysAsNull() throws {
    let record = MonitoringEvent.paused(t: 4).logRecord(now: Date(timeIntervalSince1970: 5))
    let data = try JSONEncoder().encode(record)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(fields.count, 42)
    for key in ["segment_kind", "segment_start", "segment_end", "segment_seconds"] {
      XCTAssertTrue(fields[key] is NSNull, "\(key) should be null on a paused line")
    }
  }
}
