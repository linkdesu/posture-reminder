import Foundation
import XCTest
@testable import PostureLab

/// The「识别中」段 and the timeline's sum invariant. These are the three arrival shapes the v0.6
/// brief names — an immediate first sample, one 1.4 s late, and one that never comes — asserted on
/// the pure timeline so the rule is proved without a camera, a timer or a view.
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

  /// The detecting kind is a timeline band, never a `state`: the aggregation's `PostureStatus` gate
  /// is what keeps it out of the posture statistics and the good-posture ratio.
  func testDetectingIsNotAPostureStatus() {
    XCTAssertNil(PostureStatus(rawValue: PostureSegment.detectingKind))
    XCTAssertEqual(PostureSegment.detectingKind, "detecting")
    XCTAssertEqual(PostureSegment.detectingKind, PosturePalette.detectingKind)
    XCTAssertNotEqual(PostureSegment.detectingKind, PostureStatus.noPerson.rawValue)
    XCTAssertNotEqual(PostureSegment.detectingKind, PostureSegment.pausedKind)
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
