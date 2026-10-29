import Foundation

/// The posture timeline of one focus, as a pure value: the segments the parent report draws,
/// assembled from the two things the focus really has — the wall-clock instant the child tapped
/// 开始, and the classified samples that follow it.
///
/// v0.6: the timeline starts at the tap, so the stretch between the tap and the focus's first
/// posture sample is a segment of its own (`detecting`,「识别中」) rather than part of whichever
/// posture happens to come first and rather than a hole. That is what makes the timeline add up:
///
///     detecting + good/posture/no_person  =  plannedSeconds  (±1 s)
///
/// A `paused` band is the one segment outside that sum, because a pause runs the wall clock past
/// the countdown instead of inside it (B1, B2). The type is clock-agnostic: every instant is passed
/// in, which is what lets a test pin a late first sample and a missing one.
struct FocusTimeline: Equatable {
  /// Chronological segments; the one still open is not here yet.
  private(set) var segments: [PostureSegment] = []
  /// Epoch seconds of the 开始 tap while the「识别中」段 is still open; nil once a sample closed it.
  private(set) var detectingSince: Double?
  /// The posture band in flight: its kind and the instant it started.
  private var open: OpenBand?

  init() {}

  /// Opens the timeline at the 开始 tap: the「识别中」段 begins here and the countdown with it.
  mutating func started(at tap: TimeInterval) {
    guard detectingSince == nil, open == nil else { return }
    detectingSince = tap
  }

  /// One classified sample. The first sample of a focus closes the「识别中」段 - which is returned so
  /// the caller can log it - and opens the posture band; a later sample only opens a new band when
  /// the kind changes.
  mutating func observe(_ kind: String, at t: TimeInterval) -> PostureSegment? {
    let detecting = closeDetecting(at: t)
    guard let current = open else {
      open = OpenBand(kind: kind, start: t)
      return detecting
    }
    guard current.kind != kind else { return detecting }
    segments.append(PostureSegment(kind: current.kind, start: current.start, end: t))
    open = OpenBand(kind: kind, start: t)
    return detecting
  }

  /// The focus is over: whatever is still open closes at `t`, including a「识别中」段 in a focus that
  /// never produced a sample. Returns the closed detecting segment, if that is what closed.
  mutating func finished(at t: TimeInterval) -> PostureSegment? {
    let detecting = closeDetecting(at: t)
    if let open {
      segments.append(PostureSegment(kind: open.kind, start: open.start, end: t))
      self.open = nil
    }
    return detecting
  }

  /// The time the timeline accounts for inside the countdown: every segment except a `paused` band,
  /// which is wall time the focus did not spend. This is the number the sum invariant is read on.
  var countedSeconds: Double {
    segments.filter { $0.kind != PostureSegment.pausedKind }
      .reduce(0) { $0 + $1.seconds }
  }

  private struct OpenBand: Equatable {
    var kind: String
    var start: Double
  }

  private mutating func closeDetecting(at t: TimeInterval) -> PostureSegment? {
    guard let start = detectingSince else { return nil }
    detectingSince = nil
    let end = max(start, t)
    // A sample that was already there at the tap closes nothing: a zero-length band would be a row
    // in the legend for a moment nobody waited through.
    guard end > start else { return nil }
    let segment = PostureSegment(kind: PostureSegment.detectingKind, start: start, end: end)
    segments.append(segment)
    return segment
  }
}
