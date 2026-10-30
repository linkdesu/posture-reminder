import Foundation

/// The posture timeline of one focus, as a pure value: the segments the parent report draws,
/// assembled from the two things the focus really has — the wall-clock instant the child tapped
/// 开始, and the classified samples that follow it.
///
/// v0.6: the timeline starts at the tap, so the stretch between the tap and the focus's first
/// posture sample is a segment of its own (`detecting`,「识别中」) rather than part of whichever
/// posture happens to come first and rather than a hole. That is what makes the timeline add up:
///
///     detecting + good/posture + no_data  =  plannedSeconds  (±1 s)
///
/// The bands outside that sum are the two the wall clock runs past the countdown in: `paused` (the
/// child's own pause) and, since v0.6.3, `no_person` (an absence suspension, drawn as 不在画面).
///
/// v0.6.1: the same rule covers silence after the first sample. A sample band is only evidence up
/// to its last sample; if the stream then stops (the parent opened the report, the sensor gave up),
/// `noteSampleGap` cuts the band at that last sample and opens a `no_data` band, which the next
/// sample or the finish closes. Without it the last posture — usually `good` — silently kept the
/// whole gap, and the parent's good-posture ratio was inflated by time nobody measured.
///
/// A `paused` band is the one segment outside that sum, because a pause runs the wall clock past
/// the countdown instead of inside it (B1, B2). v0.6.3 splits the two pauses: the child's own 暂停
/// still draws `paused`, while an absence suspension draws `no_person` — a measured "nobody here",
/// shown as 不在画面 — and it is outside the sum for the same reason, since the countdown is frozen
/// while it lasts. The type is clock-agnostic: every instant is passed in, which is what lets a
/// test pin a late first sample, a missing one, and a stalled stream.
struct FocusTimeline: Equatable {
  /// How quiet the sample stream must be before the timeline stops trusting it: one full second.
  /// Samples arrive at 10 Hz, so a whole second with none means the stream stopped rather than that
  /// a frame was late; any shorter window would turn normal jitter into a `no_data` speck.
  static let sampleGapThreshold: TimeInterval = 1

  /// Chronological segments; the one still open is not here yet.
  private(set) var segments: [PostureSegment] = []
  /// Epoch seconds of the 开始 tap while the「识别中」段 is still open; nil once a sample closed it.
  private(set) var detectingSince: Double?
  /// Epoch seconds of the last classified sample; nil until the focus has one. It is where a
  /// `no_data` band starts, because the stream's evidence ends there and not at the tick that
  /// noticed the silence.
  private(set) var lastSampleAt: Double?
  /// The band in flight: its kind and the instant it started.
  private var open: OpenBand?

  init() {}

  /// Opens the timeline at the 开始 tap: the「识别中」段 begins here and the countdown with it.
  mutating func started(at tap: TimeInterval) {
    guard detectingSince == nil, open == nil else { return }
    detectingSince = tap
  }

  /// One classified sample. The first sample of a focus closes the「识别中」段 - which is returned so
  /// the caller can log it - and opens the posture band; a later sample only opens a new band when
  /// the kind changes. A sample that follows a `no_data` band closes it here; it is returned for the
  /// same reason, since it is a band the log contract records.
  mutating func observe(_ kind: String, at t: TimeInterval) -> PostureSegment? {
    let detecting = closeDetecting(at: t)
    defer { lastSampleAt = t }
    guard let current = open else {
      open = OpenBand(kind: kind, start: t)
      return detecting
    }
    guard current.kind != kind else { return detecting }
    let closed = PostureSegment(kind: current.kind, start: current.start, end: t)
    segments.append(closed)
    open = OpenBand(kind: kind, start: t)
    // Only the bands that are not postures write a `segment` line; a posture change is already
    // visible in the `sample`/`status_changed` rows.
    return current.kind == PostureSegment.noDataKind ? closed : detecting
  }

  /// The wall clock moved without a sample: if the open band's last sample is more than
  /// `sampleGapThreshold` behind `t`, the band is closed at that sample and a `no_data` band opens
  /// where the evidence ended. Called by the ticker, so the cut lands on the last sample instead of
  /// on whenever the next tick or sample happens to arrive.
  ///
  /// Before the first sample there is no open band (`detecting` is already covering that gap), and a
  /// pause is left alone: pausing is a deliberate state whose band the controller already writes.
  mutating func noteSampleGap(at t: TimeInterval) {
    guard let last = lastSampleAt, let current = open else { return }
    guard current.kind != PostureSegment.noDataKind,
          current.kind != PostureSegment.pausedKind else { return }
    guard t - last > Self.sampleGapThreshold else { return }
    // A band that began at its own last sample has no measured stretch to keep; dropping it avoids
    // a zero-length legend row.
    if last > current.start {
      segments.append(PostureSegment(kind: current.kind, start: current.start, end: last))
    }
    open = OpenBand(kind: PostureSegment.noDataKind, start: last)
  }

  /// The focus is over: whatever is still open closes at `t`, including a「识别中」段 in a focus that
  /// never produced a sample and a `no_data` band the next sample never closed. Returns the closed
  /// non-posture band (detecting or no_data), if that is what closed, so the caller can log it.
  mutating func finished(at t: TimeInterval) -> PostureSegment? {
    let detecting = closeDetecting(at: t)
    if let open {
      let closed = PostureSegment(kind: open.kind, start: open.start, end: t)
      segments.append(closed)
      self.open = nil
      if detecting == nil, open.kind == PostureSegment.noDataKind { return closed }
    }
    return detecting
  }

  /// The time the timeline accounts for inside the countdown: every segment except the two bands
  /// that run the wall clock past it — the child's `paused` and the absence `no_person` suspension.
  /// This is the number the sum invariant is read on.
  var countedSeconds: Double {
    segments.filter { $0.kind != PostureSegment.pausedKind && $0.kind != PostureStatus.noPerson.rawValue }
      .reduce(0) { $0 + $1.seconds }
  }

  /// The kind the band of the moment draws, so the controller and its tests read one rule.
  ///
  /// A running focus draws whatever the engine last classified. Of the two pauses, only the child's
  /// own 暂停 is `paused`; an absence suspension is `no_person`, because the camera measured the
  /// absence rather than the child stopping, and the report names that band 不在画面. Both still
  /// freeze the countdown and both still count into `pausedSeconds` — only the drawing differs.
  static func bandKind(isPaused: Bool, isPausedByAbsence: Bool, status: String?) -> String? {
    guard isPaused else { return status }
    return isPausedByAbsence ? PostureStatus.noPerson.rawValue : PostureSegment.pausedKind
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
