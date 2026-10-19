import Foundation

enum PomodoroPhase: String, Codable, Equatable {
  case focus
  case shortBreak
  case longBreak
}

enum PomodoroCommand: Equatable {
  case start
  case pause
  case resume
  case abandon
  case skipBreak
}

enum PomodoroEvent: Equatable {
  /// `index` is the focus number (1-based). During a break it is the focus just finished.
  case phaseChanged(to: PomodoroPhase, index: Int)
  case completed(PomodoroRecord)
  case abandoned(PomodoroRecord)
  /// The focus ended because the child stayed away past the limit (B5). No break follows it, and
  /// the next focus waits for a `.start`.
  case interrupted(PomodoroRecord)
  /// The running focus is inside its last minute (B4). Reported once per focus, and only while
  /// `PomodoroSettings.remindBeforeEnd` is on.
  case endingSoon(remainingSeconds: Double)
  case breakSkipped(from: PomodoroPhase)
  /// The session is over; the UI can wind down.
  case finishedAll
}

/// Pure pomodoro timer driven by the samples it is fed.
///
/// The only clock is `PostureSample.t` (ADR-0001): feeding 25 minutes of samples runs a 25-minute
/// pomodoro, and no `Date` or dispatch time is read after construction. The countdown is anchored on
/// a sample time rather than decremented tick by tick, so a replay lands on exactly the same
/// remaining values, and a pause simply re-anchors.
///
/// The sample carries face presence too, so the same stream also decides how much of a focus the
/// child was actually there for: a focus burns time only while a face is in frame (B1), an absence
/// past `absenceLimit` ends it (B5), and the last minute is announced once (B4).
struct PomodoroEngine {
  /// A tick is 0.1 s; this only absorbs the drift of floating-point anchor subtraction, so a
  /// countdown never misses its end by one tick or ends a tick early.
  private static let completionTolerance: Double = 1e-9
  /// B5: an absence longer than this inside one running focus ends that focus as interrupted.
  private static let absenceLimit: Double = 300
  /// B4: how close to the end of a focus the one-minute warning fires.
  private static let endingSoonSeconds: Double = 60

  private var settings: PomodoroSettings
  /// Sample time zero in epoch seconds. Records and segments are stamped in epoch seconds while
  /// samples count seconds from the start of the session.
  private let epochOrigin: TimeInterval

  private(set) var phase: PomodoroPhase
  private(set) var isRunning: Bool
  /// Seconds left in the current phase.
  private(set) var remainingSeconds: Double
  /// The focus number (1-based). During a break it is the focus just finished.
  private(set) var focusIndex: Int
  /// The pomodoro in flight; during a break it is the one that just finished, which is what lets a
  /// skipped break be attached to it.
  private(set) var record: PomodoroRecord

  /// Whether a running focus is suspended because no face is in frame (B1). The focus is still
  /// running — its countdown simply holds where it was — so this is the only thing that tells an
  /// auto-suspension apart from a manual pause.
  var isPausedByAbsence: Bool { isRunning && absentSince != nil }

  /// Whether `record` is a focus that has not been closed yet.
  private var focusOpen: Bool
  private var hasStarted: Bool
  private var lastSampleT: TimeInterval?
  /// Sample time the countdown is measured from; nil while paused, suspended or before it was
  /// started.
  private var anchorT: TimeInterval?
  /// The remaining value at `anchorT`.
  private var remainingAtAnchor: Double
  /// When the absence freezing a running focus began (B1): the sample time the clock last accounted
  /// for, which is the last sample that reported a face. Non-nil only while that focus is
  /// suspended; the interval it covers is absence, never focus time.
  private var absentSince: TimeInterval?
  /// The presence the last sample reported; nil before the first sample, when the stream has said
  /// nothing yet. Remembered so a command that (re)starts a countdown can honour B1 without a
  /// sample of its own.
  private var facePresent: Bool? = nil
  /// Whether the focus in flight has already reported its one-minute warning (B4).
  private var warnedEndingSoon = false

  init(settings: PomodoroSettings, startedAt: Date = Date()) {
    let planned = Double(settings.focusMinutes * 60)
    self.settings = settings
    self.epochOrigin = startedAt.timeIntervalSince1970
    self.phase = .focus
    self.isRunning = false
    self.remainingSeconds = planned
    self.remainingAtAnchor = planned
    self.focusIndex = 1
    self.record = PomodoroRecord(startedAt: startedAt.timeIntervalSince1970,
                                 plannedSeconds: planned,
                                 focusedSeconds: 0,
                                 pausedSeconds: 0,
                                 outcome: .abandoned,
                                 focusIndex: 1)
    self.focusOpen = false
    self.hasStarted = false
  }

  /// Re-reads the parent's settings, which can change mid-run from the settings page.
  ///
  /// The plan a focus already started under stays fixed — its `plannedSeconds` and its countdown
  /// were decided when it began, which is exactly what makes "the next pomodoro uses the new
  /// length" true — so this only governs what comes next and the switches that gate events on the
  /// focus in flight (B4).
  mutating func update(settings: PomodoroSettings) {
    self.settings = settings
  }

  /// Takes one tick of the sample clock. Time comes from `sample.t` alone.
  mutating func ingest(_ sample: PostureSample) -> [PomodoroEvent] {
    let dt = lastSampleT.map { sample.t - $0 } ?? 0

    // A paused interval is the only thing that grows `pausedSeconds`: the focus clock is frozen, so
    // the time is credited to the pause instead of the focus. Breaks are outside the record. An
    // absence is not a pause (B1); it is only ever left out of the focus.
    if !isRunning, focusOpen {
      record.pausedSeconds += max(0, dt)
    }

    facePresent = sample.facePresent

    var events: [PomodoroEvent]
    if let since = absentSince, sample.t - since > Self.absenceLimit {
      // B5: the absence has outlived the limit, so this sample ends the focus rather than feeding
      // it. Checked first, and only while a focus is running, which is the whole scope of the rule.
      events = interruptFocus(at: sample.t)
    } else {
      applyPresence(at: sample.t)
      events = advance(to: sample.t)
    }

    if focusOpen {
      record.focusedSeconds = elapsedFocusSeconds
    }
    lastSampleT = sample.t
    return events
  }

  mutating func command(_ command: PomodoroCommand) -> [PomodoroEvent] {
    switch command {
    case .start:
      return start()
    case .pause:
      guard isRunning else { return [] }
      remainingAtAnchor = remainingSeconds
      anchorT = nil
      isRunning = false
      // A manual pause freezes the clock on its own, so the absence measurement ends with it: it
      // resumes from wherever the face stands when the focus is started again.
      absentSince = nil
      return []
    case .resume:
      // Nothing to resume while a break is waiting for a focus to be started again: only a focus in
      // flight or a break that was paused has a countdown to put back.
      guard !isRunning, focusOpen || phase != .focus else { return [] }
      setCountdown(remainingSeconds, anchoredAt: resumeAnchor, running: true)
      applyPresence(at: resumeAnchor)
      return []
    case .abandon:
      return abandon()
    case .skipBreak:
      return skipBreak()
    }
  }

  /// Ends the whole session (a scripted run reaching its end), closing a focus still in flight as
  /// abandoned so its actual focus time is not lost. A focus that never ran is not a record at all.
  mutating func finish(at t: TimeInterval) -> [PomodoroEvent] {
    var events = advance(to: t)
    // Only a focus that actually ran is closed. One that was merely waiting for its `.start` - the
    // focus `autoStartFocus` parks after every break, opened by a last-beat start as the script ran
    // out - never accrued a tick, so closing it would write a zero-second pomodoro the child never
    // began and the parent would read a focus that never happened. A focus that ran is still
    // abandoned with the time it really accumulated.
    if focusOpen, record.focusedSeconds > 0 {
      let actual = elapsedFocusSeconds
      let finished = close(outcome: .abandoned, at: t, focusedSeconds: actual)
      events.append(.abandoned(finished))
    }
    // Either way nothing is in flight once the session is over.
    focusOpen = false
    isRunning = false
    anchorT = nil
    absentSince = nil
    remainingAtAnchor = remainingSeconds
    lastSampleT = t
    events.append(.finishedAll)
    return events
  }

  // MARK: - Commands

  private mutating func start() -> [PomodoroEvent] {
    guard !isRunning else { return [] }
    let firstStart = !hasStarted
    hasStarted = true

    if phase == .focus, !focusOpen {
      openFocus(at: lastSampleT ?? 0)
    }
    setCountdown(remainingSeconds, anchoredAt: resumeAnchor, running: true)
    applyPresence(at: resumeAnchor)
    return firstStart ? [.phaseChanged(to: .focus, index: focusIndex)] : []
  }

  private mutating func abandon() -> [PomodoroEvent] {
    guard focusOpen else { return [] }
    let actual = elapsedFocusSeconds
    let finished = close(outcome: .abandoned, at: lastSampleT ?? 0, focusedSeconds: actual)
    // B3: the abandoned countdown is spent, not inherited — the next start runs a whole focus
    // instead of the tail of this one. That is the same idle focus a break parks in.
    parkIdleFocus()
    return [.abandoned(finished)]
  }

  /// A break is not a pomodoro, so skipping one is recorded on the pomodoro whose break it was and
  /// the session moves straight on to the next focus, honouring `autoStartFocus`.
  private mutating func skipBreak() -> [PomodoroEvent] {
    guard phase != .focus else { return [] }
    record.skippedBreak = true
    let skipped = phase
    var events: [PomodoroEvent] = [.breakSkipped(from: skipped)]
    events += enterNextFocus(at: lastSampleT ?? 0)
    return events
  }

  // MARK: - Clock

  /// Applies the sample clock to the countdown and reports a phase that ended because of it.
  ///
  /// Time is taken from `t - anchorT` rather than subtracted tick by tick, so the remaining value at
  /// a given sample is exact and a pause costs nothing. A single sample moves at most one phase:
  /// samples arrive at the camera tick, and a gap that could span several phases is not something
  /// the stream can express meaningfully.
  private mutating func advance(to t: TimeInterval) -> [PomodoroEvent] {
    // A focus suspended by an absence holds its countdown (B1): the sample clock goes on, the focus
    // clock does not, and the re-anchor on the way back is what makes the absence cost nothing.
    guard isRunning, absentSince == nil else { return [] }
    let anchor = anchorT ?? t
    anchorT = anchor
    remainingSeconds = max(0, remainingAtAnchor - (t - anchor))
    guard remainingSeconds > Self.completionTolerance else {
      remainingSeconds = 0

      switch phase {
      case .focus:
        return completeFocus(at: t)
      case .shortBreak, .longBreak:
        return enterNextFocus(at: t)
      }
    }
    return warnEndingSoon()
  }

  /// B4: the one-minute warning. Reported once per focus, on the first sample that finds the running
  /// focus inside its last minute, and never when the setting is off.
  private mutating func warnEndingSoon() -> [PomodoroEvent] {
    guard settings.remindBeforeEnd, phase == .focus, focusOpen, !warnedEndingSoon,
          remainingSeconds <= Self.endingSoonSeconds else { return [] }
    warnedEndingSoon = true
    return [.endingSoon(remainingSeconds: remainingSeconds)]
  }

  /// The command that restarts a countdown carries no time (a command is not a sample), so it is
  /// anchored on the last sample seen; before the first sample the sample clock is still at zero.
  private var resumeAnchor: TimeInterval { lastSampleT ?? 0 }

  private mutating func setCountdown(_ seconds: Double,
                                     anchoredAt t: TimeInterval?,
                                     running: Bool) {
    remainingSeconds = seconds
    remainingAtAnchor = seconds
    anchorT = running ? (t ?? lastSampleT) : nil
    isRunning = running
  }

  // MARK: - Absence

  /// B1: a running focus only burns time while a face is in frame.
  ///
  /// The absence is dated from the clock's anchor — the last sample time the countdown accounted
  /// for — so an interval the stream never confirmed as present is never credited as focus: the
  /// countdown freezes where it stood, and the sample that brings the face back re-anchors it there.
  /// The child carries on with exactly the time that was left.
  private mutating func applyPresence(at t: TimeInterval) {
    guard isRunning, phase == .focus, focusOpen else { return }

    if absentSince != nil {
      // Still away: the clock stays frozen.
      guard facePresent == true else { return }
      absentSince = nil
      anchorT = t
      return
    }

    guard facePresent == false else { return }
    // Dated from the sample that reports the face gone. Anchoring it on `anchorT`/`lastSampleT`
    // read as 0 whenever neither had been set yet, which made the B5 check compare the whole
    // session clock against a zero start and interrupt on the very first absent sample.
    absentSince = t
    remainingAtAnchor = remainingSeconds
    anchorT = nil
  }

  /// B5: the absence outlived the limit, so the focus ends as interrupted on the spot.
  ///
  /// No break is entered and nothing auto-starts: the engine is left on the idle focus a break parks
  /// in, so the child who comes back finds a still screen and starts the next focus themself. The
  /// interrupted focus never reached its break, so it is not counted in the long-break cadence
  /// either — the next start replays the same focus index.
  private mutating func interruptFocus(at t: TimeInterval) -> [PomodoroEvent] {
    let finished = close(outcome: .interrupted, at: t, focusedSeconds: elapsedFocusSeconds)
    parkIdleFocus()
    return [.interrupted(finished)]
  }

  /// Leaves the engine waiting on a full, unstarted focus: the idle state a break ends in.
  private mutating func parkIdleFocus() {
    setCountdown(Double(settings.focusMinutes * 60), anchoredAt: nil, running: false)
  }

  // MARK: - Phases

  private mutating func completeFocus(at t: TimeInterval) -> [PomodoroEvent] {
    // A completed focus counts as the full plan by definition: the countdown reached zero, and the
    // pauses it absorbed were never part of it.
    let finished = close(outcome: .completed, at: t, focusedSeconds: record.plannedSeconds)
    let needsLongBreak = focusIndex % max(1, settings.focusPerLongBreak) == 0
    let next: PomodoroPhase = needsLongBreak ? .longBreak : .shortBreak
    let minutes = needsLongBreak ? settings.longBreakMinutes : settings.shortBreakMinutes

    phase = next
    setCountdown(Double(minutes * 60), anchoredAt: t, running: settings.autoStartBreak)
    return [.completed(finished), .phaseChanged(to: next, index: focusIndex)]
  }

  private mutating func enterNextFocus(at t: TimeInterval) -> [PomodoroEvent] {
    phase = .focus
    focusIndex += 1
    setCountdown(Double(settings.focusMinutes * 60), anchoredAt: t, running: settings.autoStartFocus)
    if settings.autoStartFocus {
      openFocus(at: t)
    }
    return [.phaseChanged(to: .focus, index: focusIndex)]
  }

  private mutating func openFocus(at t: TimeInterval) {
    record = PomodoroRecord(startedAt: epoch(t),
                            plannedSeconds: Double(settings.focusMinutes * 60),
                            focusedSeconds: 0,
                            pausedSeconds: 0,
                            outcome: .abandoned,
                            focusIndex: focusIndex)
    focusOpen = true
    // B4: the warning belongs to a focus, so the new focus starts owing it again.
    warnedEndingSoon = false
  }

  private mutating func close(outcome: PomodoroOutcome,
                              at t: TimeInterval,
                              focusedSeconds: Double) -> PomodoroRecord {
    record.endedAt = epoch(t)
    record.outcome = outcome
    record.focusedSeconds = focusedSeconds
    focusOpen = false
    // Nothing is in flight any more, so no absence is being measured either.
    absentSince = nil
    return record
  }

  /// Focus time actually counted so far: the plan minus what is left. A pause does not move the
  /// remaining value and neither does an absence, so neither can be counted as focus time.
  private var elapsedFocusSeconds: Double {
    guard focusOpen else { return 0 }
    return min(record.plannedSeconds, max(0, record.plannedSeconds - remainingSeconds))
  }

  private func epoch(_ t: TimeInterval) -> Double { epochOrigin + t }
}
