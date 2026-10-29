import Combine
import Foundation
import UIKit

/// The child-facing state of a pomodoro session, as one value type, so the main screen reads one
/// published value instead of five.
struct PomodoroSnapshot: Equatable {
  var phase: PomodoroPhase
  var isRunning: Bool
  /// Seconds left in the current phase.
  var remainingSeconds: Double
  /// The focus number (1-based); during a break it is the focus just finished.
  var focusIndex: Int
  /// Pomodoros completed today, off the persisted history.
  var completedToday: Int
  /// Whether this focus has been started and not closed yet. It is what separates a parked focus
  /// (before 开始专注, or after 离开 reset it) from one in flight: only a started focus has
  /// something to end early.
  var focusStarted: Bool
}

/// Which report the parent report screen shows; the in-page segmented control binds to this.
enum ReportScope: String, CaseIterable, Equatable {
  case day
  case week
  case month

  /// Calendar days the scope covers, oldest first.
  var dayCount: Int {
    switch self {
    case .day: return 1
    case .week: return 7
    case .month: return 30
    }
  }
}

#if DEBUG
/// `-autopause <seconds>:<holdSeconds>`: the plan behind the one manual pause the acceptance has to
/// photograph. A simulator has no scriptable tap, so a debug build issues the pause and the resume
/// itself, at those two points of the shared sample clock, and a scripted run catches the paused
/// state and the grey band the timeline draws for it.
///
/// Debug builds only: this type, the argument's name and every call site around it are compiled out
/// of a release build, which can neither read the argument nor act on it.
struct DebugAutoPause {
  /// Seconds into the run, on the shared sample clock, when the pause is issued.
  var at: TimeInterval
  /// Seconds the pause holds before the resume is issued.
  var hold: TimeInterval

  /// Parses the launch argument's value; nil when it is absent or malformed.
  init?(_ raw: String?) {
    guard let raw else { return nil }
    let parts = raw.split(separator: ":", maxSplits: 1)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2,
          let at = TimeInterval(parts[0]),
          let hold = TimeInterval(parts[1]),
          at >= 0, hold > 0
    else { return nil }
    self.at = at
    self.hold = hold
  }
}
#endif

@MainActor
final class SessionController: ObservableObject {
  enum Phase: Equatable {
    /// The child's screen. The countdown is the interaction, the point cloud is the subject, and
    /// nothing on it ever interrupts. It is also the app's root: the app launches here.
    case pomodoro
    /// The pomodoro settings, a phase of its own so a launch argument can open it directly. It is
    /// also a screen a parent opens from the child's screen.
    case pomodoroSettings
    /// The parent report.
    case report
  }

  @Published private(set) var phase: Phase = .pomodoro
  /// The latest sample's body geometry and its assessment, for the avatar and the debug overlay.
  /// Both are cleared when the run ends or the source stops.
  @Published private(set) var latestGeometry: PoseGeometry?
  @Published private(set) var latestAssessment: PostureAssessment?

  /// The child's screen.
  @Published private(set) var pomodoroSnapshot: PomodoroSnapshot?
  /// The report screen's scope: written by the in-page segmented control and by `-report`.
  @Published var reportScope: ReportScope = .day {
    didSet { refreshReport() }
  }
  /// The scope's days, oldest first; the day view draws `segments` and the week/month views draw the
  /// trend, so no view aggregates anything itself.
  @Published private(set) var reportDays: [ReportDay] = []
  /// The scope's totals, from the same aggregation pass as `reportDays`.
  @Published private(set) var reportTotals = ReportTotals(completedPomodoros: 0,
                                                          focusSeconds: 0,
                                                          goodRatio: 0,
                                                          postureSeconds: [:])

  let settings: Settings
  let logger: DebugLogging

  /// The pomodoro history the parent report reads and every closed pomodoro is written to.
  private let pomodoroStore: PomodoroStore
  /// The eleven pomodoro settings; the settings screen edits this very instance.
  private let pomodoroSettings: PomodoroSettingsStore

  /// Non-empty means scripted replay instead of the camera.
  let scenarios: [Scenario]

  private let player: ReminderPlayer

  private var engine: MonitoringEngine?
  private var inputSource: SampleSource?
  /// Last `view_mode` layer state written, so a settings change only logs when it actually changed
  /// the visible layers. Reset at the start of every focus.
  private var lastViewMode: (mode: String, overlay: Bool, avatar: Bool)?
  private var viewModeObservers: Set<AnyCancellable> = []
  private var pomodoroObservers: Set<AnyCancellable> = []

  /// The timer. Its only clock is the sample stream, which is what makes it and the posture engine
  /// share one clock.
  private var pomodoro: PomodoroEngine?
  /// Epoch seconds of the timer's sample-time zero. Posture segments are stamped on the same origin,
  /// so a record and its segments land on the same spot of the report's time axis.
  private var pomodoroEpochOrigin: TimeInterval = 0
  /// The last sample time both engines saw, and the offset that keeps that clock monotonic: a source
  /// restarts its own clock at zero, and the child's screen gives the depth sensor up when the parent
  /// opens the report, so the controller maintains the shared clock rather than trusting the source.
  private var pomodoroLastT: TimeInterval = 0
  private var pomodoroClockOffset: TimeInterval = 0
  /// The last whole second of the shared clock a `pomodoro_tick` line was written for. The tick is
  /// the countdown's evidence, so it is one line per second, not one per sample.
  private var pomodoroTickSecond: Int?
  /// The id of the record in flight; a different id is exactly what an opened focus looks like.
  private var pomodoroRecordID: UUID?
  private var pomodoroFocusOpen = false
  /// Mirrors `pomodoroFocusPaused` so a pause is noticed exactly once, whichever way it arrived;
  /// see `syncPomodoroPause`.
  private var pomodoroPauseApplied = false
  /// Whether the run ever started a focus, and whether it is over.
  private var pomodoroStarted = false
  private var pomodoroRunFinished = false
  /// The focus's posture timeline: the segments already closed and the one still open.
  private var pomodoroSegments: [PostureSegment] = []
  private var pomodoroOpenSegment: (kind: String, start: TimeInterval)?
  /// A closed pomodoro waiting to be written. It waits one beat so a skipped break, which the engine
  /// reports after the completion, still lands on the record it belongs to.
  private var pomodoroPending: PomodoroRecord?
  private var pomodoroCompletedTodayCount = 0

  #if DEBUG
  /// The timer's proof hook, armed from `-autopause` in `App.swift` before the first frame: the plan
  /// for this run, whether its pause has gone out yet, and whether the run has used it up.
  var debugAutoPause: DebugAutoPause?
  private var debugAutoPausePaused = false
  private var debugAutoPauseFinished = false
  /// `-holdStart 1`: a scripted run that keeps its first focus parked, for the evidence that the
  /// point cloud and the silhouette are on screen before 开始专注. Debug builds only.
  var debugHoldStart = false
  #endif

  init(settings: Settings,
       logger: DebugLogging,
       scenarios: [Scenario] = [],
       pomodoroStore: PomodoroStore = PomodoroStore(),
       pomodoroSettings: PomodoroSettingsStore = PomodoroSettingsStore()) {
    self.settings = settings
    self.logger = logger
    self.scenarios = scenarios
    self.pomodoroStore = pomodoroStore
    self.pomodoroSettings = pomodoroSettings
    player = ReminderPlayer(settings: settings, logger: logger)

    // Both switches change the visible layers, so each logs a `view_mode` line while a session runs.
    for publisher in [settings.$avatarEnabled.eraseToAnyPublisher(),
                      settings.$debugEnabled.eraseToAnyPublisher()] {
      publisher
        .dropFirst()
        .sink { [weak self] _ in
          Task { @MainActor in self?.logViewModeChange() }
        }
        .store(in: &viewModeObservers)
    }

    // The pomodoro settings screen can change the voice switch or the volume mid-run, and the player
    // follows. The timer is re-read too, so a switch or a length changed mid-run is honoured by the
    // next focus rather than the next launch (the running countdown is fixed when its focus starts).
    pomodoroSettings.$settings
      .dropFirst()
      .sink { [weak self] values in
        Task { @MainActor in
          guard let self else { return }
          self.pomodoro?.update(settings: values)
          self.applyPomodoroAudio(values)
        }
      }
      .store(in: &pomodoroObservers)

    // A seeded history and the stored one both have to be on screen from the first frame.
    refreshReport()

    // The child's screen is the root, so the timer exists before the first frame. It is driven by
    // samples, not by the screen being visible.
    applyPomodoroAudio(pomodoroSettings.settings)
    startPomodoroTimer()
    refreshPomodoroSnapshot()
    // The child's screen is the root, so the depth sensor starts with it: the point cloud and the
    // silhouette are the screen's ground, not something a focus has to turn on.
    startPomodoroInput()
  }

  var isSimulating: Bool { !scenarios.isEmpty }

  private var simulatedScenario: Scenario? { scenarios.first }

  // MARK: - Navigation

  /// Back to the child's pomodoro screen. The timer keeps running: it is driven by samples, not by
  /// the screen being visible.
  func showPomodoro() {
    phase = .pomodoro
    startPomodoroInput()
    refreshPomodoroSnapshot()
  }

  /// The pomodoro settings. A phase of its own rather than a sheet, so a launch argument opens it
  /// directly and the capture script has a screen name to photograph.
  func showPomodoroSettings() {
    phase = .pomodoroSettings
    startPomodoroInput()
    refreshPomodoroSnapshot()
  }

  func showReport() {
    showReport(scope: reportScope)
  }

  /// The parent report. It reads the persisted history, so a pomodoro still in flight is not in it.
  func showReport(scope: ReportScope) {
    reportScope = scope  // the observer refreshes the report
    flushPomodoroPending()
    // A parent-facing screen needs no depth, so the sensor stops here; returning to the child's
    // screen starts a fresh source on the shared clock.
    stopInput()
    phase = .report
  }

  /// The end sound the settings name, played for a preview from the settings page. It is deliberately
  /// the settings' own switch being heard, so it neither starts a focus nor writes a `cue_played`
  /// line: that line is evidence of the timer's sound, and a preview is not the timer.
  func previewEndSound() {
    guard let cue = Self.cue(for: pomodoroSettings.settings.endSound) else { return }
    player.preview(cue: cue)
  }

  /// The clip behind an end-sound choice; `none` is a real choice and has no clip.
  private static func cue(for sound: EndSound) -> PomodoroCue? {
    switch sound {
    case .soft: return .endSoft
    case .chime: return .endChime
    case .none: return nil
    }
  }

  /// A scripted run has nobody to tap 开始, so it starts its own first focus and ends when the script
  /// runs out.
  func autoStartIfSimulating() {
    guard isSimulating else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      self?.autoStartParkedFocusIfSimulating()
    }
  }

  /// Every focus of a scripted run starts here and nowhere else: the one answer to "who presses 开始
  /// when there is nobody to press it".
  ///
  /// `autoStartFocus` is off by default for a reason that belongs to the child: each pomodoro is the
  /// child's to begin, and the domain spec does not want them running back to back on their own. That
  /// reason is about the child's experience, and a scripted run has no child in it - nobody can tap
  /// 开始, so a scenario would park on the wait after its first focus and finish with a single record.
  /// The replay presses the button instead. A real run is left alone: there the setting governs and
  /// the child taps.
  private func autoStartParkedFocusIfSimulating() {
    #if DEBUG
    // The preview-evidence run keeps the first focus parked on purpose, so 开始专注 and the absence
    // of 离开 can both be photographed.
    guard !debugHoldStart else { return }
    #endif
    guard isSimulating, !pomodoroRunFinished, let pomodoro else { return }
    // Parked means a focus whose countdown is stopped and whose record was not opened: where
    // `enterNextFocus` leaves it at the end of every break, and where a run sits before its first
    // focus. A focus that was started and then paused is open, and is not this.
    guard pomodoro.phase == .focus, !pomodoro.isRunning, !pomodoroFocusOpen else { return }
    pomodoroCommand(.start)
  }

  // MARK: - Pomodoro

  /// Start / pause / resume / abandon / skipBreak, straight through to the timer.
  func pomodoroCommand(_ command: PomodoroCommand) {
    if command == .start { restartPomodoroRunIfFinished() }
    guard var pomodoro else { return }
    let events = pomodoro.command(command)
    self.pomodoro = pomodoro
    syncPomodoroFocus()
    for event in events { handlePomodoroEvent(event, at: pomodoroLastT) }
    syncPomodoroPause()
    refreshPomodoroSnapshot()
  }

  /// A run that already wound down can be started again, with a fresh timer on a fresh clock, so the
  /// child's screen never offers a button that cannot work.
  private func restartPomodoroRunIfFinished() {
    guard pomodoroRunFinished else { return }
    pomodoroRunFinished = false
    pomodoroStarted = false
    pomodoroLastT = 0
    pomodoroClockOffset = 0
    startPomodoroTimer()
  }

  /// Recomputes the parent report from the persisted history. Called when a pomodoro is written, when
  /// the scope changes and when the history is cleared; the launch path runs it once through `init`.
  func refreshReport() {
    let period = PomodoroHistory.period(pomodoroStore.records,
                                        endingAt: Date(),
                                        count: reportScope.dayCount,
                                        calendar: Calendar.current)
    reportDays = period.days
    reportTotals = period.totals

    // The child's screen shows today's count, so it rides along with the same store change.
    let calendar = Calendar.current
    let now = Date()
    pomodoroCompletedTodayCount = pomodoroStore.records.reduce(0) { count, record in
      guard record.outcome == .completed else { return count }
      let started = Date(timeIntervalSince1970: record.startedAt)
      return calendar.isDate(started, inSameDayAs: now) ? count + 1 : count
    }
  }

  /// The report screen's 清空历史 button. The history is on this device only, and the parent is the
  /// one who decides when it goes.
  func clearPomodoroHistory() {
    pomodoroStore.clear()
    pomodoroPending = nil
    refreshReport()
    refreshPomodoroSnapshot()
  }

  // MARK: - Pomodoro run

  private func startPomodoroTimer() {
    let startedAt = Date()
    pomodoroEpochOrigin = startedAt.timeIntervalSince1970
    let engine = PomodoroEngine(settings: pomodoroSettings.settings, startedAt: startedAt)
    pomodoro = engine
    // The engine's first record is not a focus in flight, so its id is adopted without opening one.
    pomodoroRecordID = engine.record.id
    pomodoroFocusOpen = false
    pomodoroSegments = []
    pomodoroOpenSegment = nil
    pomodoroPending = nil
    // A fresh timer runs on a fresh clock, so the first second of it is due again.
    pomodoroTickSecond = nil
    // Nothing is in flight on a fresh timer, and no pause decision survives from the run before.
    pomodoroPauseApplied = false
  }

  /// One tick of a pomodoro run: one shared clock, the posture engine while posture is monitored,
  /// and the timeline the parent will later read.
  private func handlePomodoro(_ rawSample: PostureSample) {
    guard var pomodoro else { return }
    var sample = rawSample
    sample.t = pomodoroClockOffset + rawSample.t
    pomodoroLastT = sample.t

    // A scripted run ends with its script, not with a tap. Checked before the timer can open the
    // focus that follows the last break: the script's final tick would otherwise be credited to a
    // fourth pomodoro nobody asked for, and the parent would see a zero-second record.
    if let scenario = simulatedScenario,
       rawSample.t + SimulatedSampleSource.tickInterval >= scenario.duration {
      finishPomodoroRun()
      return
    }

    // The timer always gets the sample - it is the clock - while the posture engine gets it only
    // while posture is monitored. A manual pause is the hard gate (ADR-0003) and stops the feed; an
    // absence pause does not, because the engine is what times the three-second no-person rule and
    // writes the `paused`/`resumed` pair the log contract names (B1, B2).
    let monitoring = monitorsPomodoroPosture
    let manualPause = pomodoroFocusOpen && !pomodoro.isRunning
    if monitoring, !manualPause {
      feedPosture(sample)
    } else {
      // No engine in flight — a parked focus, a break, a pause — so this sample feeds only the
      // mirror. The point cloud is the child's screen from launch, not something 开始专注 turns on.
      latestGeometry = PoseGeometry(joints: sample.joints,
                                    depth: sample.depth,
                                    cloud: sample.cloud,
                                    unavailableJoints: sample.unavailableJoints)
    }

    let events = pomodoro.ingest(sample)
    self.pomodoro = pomodoro
    syncPomodoroFocus()
    for event in events { handlePomodoroEvent(event, at: sample.t) }
    syncPomodoroPause()
    // An absence still feeds the engine, so its own no-face frame must not become the avatar's
    // subject: the child is not there, and the last frame is dropped exactly as before.
    if pomodoro.isPausedByAbsence {
      latestGeometry = nil
      latestAssessment = nil
    }
    // After the events, so a phase that ended on this sample is reported as the phase the countdown
    // has already moved on to.
    logPomodoroTickIfDue(at: sample.t)

    if monitoring, pomodoroFocusOpen { accumulatePomodoroSegment(at: sample.t) }
    refreshPomodoroSnapshot()

    #if DEBUG
    // `-autopause`: a debug-only proof hook, driven here on the sample this run just ticked, so the
    // command lands on the timer that sample was accounted for rather than on a stale copy of it.
    applyDebugAutoPauseIfDue(at: sample.t)
    #endif

  }

  #if DEBUG
  /// `-autopause <seconds>:<holdSeconds>`: issues the 暂停 and the 继续 a scripted acceptance run
  /// cannot tap, measured on the sample clock the countdown itself runs on so the run stays
  /// deterministic, and through the same `pomodoroCommand` path the two buttons use so the pause and
  /// its grey band land in the history exactly as a manual one does. One pair per run: the pause goes
  /// out once, and the resume retires the plan.
  ///
  /// Debug builds only; see `DebugAutoPause`. A release build has neither the plan nor this method.
  private func applyDebugAutoPauseIfDue(at t: TimeInterval) {
    guard let plan = debugAutoPause, !debugAutoPauseFinished else { return }
    if t >= plan.at + plan.hold {
      debugAutoPauseFinished = true
      pomodoroCommand(.resume)
    } else if t >= plan.at, !debugAutoPausePaused {
      debugAutoPausePaused = true
      pomodoroCommand(.pause)
    }
  }
  #endif

  /// Writes the countdown, once per second of the shared clock, while a phase is running.
  ///
  /// The countdown is anchored on a sample time instead of being counted down tick by tick, so the
  /// series of lines is the only thing a reader can check: a `phase` that stays put while
  /// `remaining_seconds` falls in step with the `ts` gap between two lines. One line per second is
  /// enough for that; one per sample (10 Hz) would bury the log. A phase that is not running -
  /// parked before its 开始, or paused by the child - writes nothing, because a frozen countdown and a
  /// stopped one would otherwise look alike. An absence pause is the one exception: the timer is still
  /// running, so it keeps ticking where it stopped, and the flat `remaining_seconds` is that freeze.
  private func logPomodoroTickIfDue(at t: TimeInterval) {
    guard let pomodoro, pomodoro.isRunning else { return }
    let second = Int(t.rounded(.down))
    guard second != pomodoroTickSecond else { return }
    pomodoroTickSecond = second
    logger.log(.pomodoroTick(remainingSeconds: pomodoro.remainingSeconds,
                             phase: pomodoro.phase.rawValue))
  }

  /// Whether the posture engine takes a sample: every focus, and a break only when the pomodoro
  /// settings ask for it, because a break is otherwise a rest from being watched too.
  private var monitorsPomodoroPosture: Bool {
    guard let pomodoro else { return false }
    if pomodoro.phase == .focus { return pomodoroFocusOpen }
    return pomodoroSettings.settings.monitorDuringBreak
  }

  /// A focus that is not being counted is paused, and the two ways it gets there are one state: the
  /// child tapped 暂停, or the child is not in frame (B1, B2). Both stop the posture feed, both
  /// silence the player, and both take a band of their own on the timeline; keeping them apart would
  /// hand the parent two vocabularies for the same missing minute.
  ///
  /// A focus parked before its 开始 is not open, so it is not a pause; and the pomodoro engine, not
  /// this controller, is what suspends the countdown when the face goes and decides when the absence
  /// has lasted long enough to end the focus (B5). Breaks are outside the question: a break is not
  /// the focus's timeline and was never an open focus, so `monitorDuringBreak` keeps meaning what it
  /// says for a break that is paused or not yet started.
  private var pomodoroFocusPaused: Bool {
    guard let pomodoro, pomodoroFocusOpen else { return false }
    return !pomodoro.isRunning || pomodoro.isPausedByAbsence
  }

  /// Everything a pause takes away from a running focus, applied once per transition so a manual
  /// pause and an absence pause cannot drift apart (B1, B2).
  ///
  /// The player stops: the clip in flight belongs to a sitting session that is over, and a paused
  /// pomodoro is silent. An absence also drops the last frame, because that frame is a child who is
  /// no longer in front of the camera, whereas a pause the child pressed keeps it — they are still
  /// sitting there, only the timer stopped. The mirror is what stops either of those from being
  /// applied once per sample.
  private func syncPomodoroPause() {
    let paused = pomodoroFocusPaused
    guard paused != pomodoroPauseApplied else { return }
    pomodoroPauseApplied = paused
    guard paused else { return }
    player.stop()
    if pomodoro?.isPausedByAbsence == true {
      latestGeometry = nil
      latestAssessment = nil
    }
  }

  /// Feeds the posture engine and logs the events, plays what speaks, and publishes the latest frame
  /// for the avatar.
  private func feedPosture(_ sample: PostureSample) {
    if engine == nil { engine = makePostureEngine() }
    guard var engine else { return }
    let events = engine.ingest(sample)
    self.engine = engine

    for event in events {
      logger.log(event)
      if case let .reminder(kind, level, _, _, _, _) = event {
        player.play(kind: kind, level: level)
      }
    }

    latestGeometry = PoseGeometry(joints: sample.joints,
                                  depth: sample.depth,
                                  cloud: sample.cloud,
                                  unavailableJoints: sample.unavailableJoints)
    latestAssessment = engine.latestAssessment
  }

  /// A fresh engine per focus: one pomodoro is one posture session, so the break in between can never
  /// be credited as sitting time and the reminder counts belong to a single record.
  private func makePostureEngine() -> MonitoringEngine {
    MonitoringEngine(config: settings.engineConfig,
                     baselineDistanceCM: settings.baselineDistanceCM ?? 0,
                     baselinePitchDeg: settings.baselinePitchDeg ?? 0)
  }

  /// A focus is what a record covers, so its posture session starts and ends with it. A different
  /// record id is exactly what an opened focus looks like; the engine keeps the id while it sits in
  /// the break that follows.
  private func syncPomodoroFocus() {
    guard let pomodoro, pomodoro.record.id != pomodoroRecordID else { return }
    let firstFocusOfRun = !pomodoroStarted
    pomodoroRecordID = pomodoro.record.id
    pomodoroFocusOpen = true
    pomodoroStarted = true
    pomodoroSegments = []
    pomodoroOpenSegment = nil
    engine = nil
    latestAssessment = nil
    flushPomodoroPending()  // the pomodoro before this one is settled, skipped break and all
    logPomodoroFocusStarted()
    startPomodoroInput()
    if firstFocusOfRun, isSimulating {
      // AC7: a scripted run anchors its script on the focus it records. The script clock starts with
      // the source, while a scripted run parks for a beat before pressing 开始, so without this the
      // script's first fifteen good seconds begin 1.4 s before the focus does and the timeline's
      // head is short by exactly that beat. From here on the script's t = 0 is the focus.
      rebaseSimulatedClock()
    }
  }

  /// Restarts the scripted source's own clock at its zero and keeps the shared clock monotonic: the
  /// source's next tick lands one sample after the start command rather than repeating its time.
  private func rebaseSimulatedClock() {
    guard let source = inputSource as? SimulatedSampleSource else { return }
    pomodoroClockOffset = pomodoroLastT + SimulatedSampleSource.tickInterval
    source.restartClock()
  }

  private func handlePomodoroEvent(_ event: PomodoroEvent, at t: TimeInterval) {
    switch event {
    case .phaseChanged(let to, _):
      guard to == .focus else { return }
      // A break is over, so the pomodoro that finished before it can no longer gain a skipped break
      // and its record is final.
      flushPomodoroPending()
      // The focus that follows is parked, waiting for a 开始 no scripted run can tap; a simulated run
      // presses it, and a real one leaves it to the child (`autoStartParkedFocusIfSimulating`).
      autoStartParkedFocusIfSimulating()
    case .finishedAll:
      break
    case .completed(let record):
      // The focus is over, which is the one moment the end sound exists for.
      playEndSound()
      // Waits one beat: a skipped break is reported after the completion, and the flag belongs on this
      // record. The break that follows ends with a `phaseChanged(to: .focus)` that writes it.
      closePomodoroFocus(record: record, at: t)
    case .abandoned(let record):
      closePomodoroFocus(record: record, at: t)
      // Nothing can change an abandoned pomodoro, so it goes in the history at once.
      flushPomodoroPending()
    case .interrupted(let record):
      // B5: the child was away long enough for the pomodoro to be over. It is not a completion, so it
      // is never celebrated with the end sound, and the engine parks afterwards instead of starting a
      // break.
      closePomodoroFocus(record: record, at: t)
      flushPomodoroPending()
    case .breakSkipped:
      // The engine marks the pomodoro whose break was skipped, and that record is the one still
      // waiting to be written, so the skip goes into the history with the rest of its evidence.
      pomodoroPending?.skippedBreak = true
    }
  }

  /// The end-of-focus sound the settings name. `.none` is a real choice — a parent who wants a silent
  /// timer — so it plays nothing and logs nothing rather than a cue nobody asked for. Whether the clip
  /// really started, and hence whether a `cue_played` line is written at all, is the player's call.
  private func playEndSound() {
    guard let cue = Self.cue(for: pomodoroSettings.settings.endSound) else { return }
    player.play(cue: cue)
  }

  /// Closes the focus: the timeline ends at `t` and the record takes the segments, the reminders and
  /// the real focus time with it.
  private func closePomodoroFocus(record: PomodoroRecord, at t: TimeInterval) {
    closePomodoroSegment(at: t)

    var finished = record
    finished.postureSegments = pomodoroSegments
    finished.reminderCounts = pomodoroReminderCounts()
    pomodoroPending = finished
    pomodoroFocusOpen = false

    // A pomodoro is one posture session, so it gets its own summary line. A focus that closed before
    // its first sample still gets an (empty) summary, so every logged `session_started` has an
    // `session_ended` to pair with.
    let summary = engine?.summary ?? makePostureEngine().summary
    logger.log(.sessionEnded(summary: summary))
    engine = nil
    latestAssessment = nil
  }

  /// The reminders the focus collected, one entry per posture kind, so a stored record carries its own
  /// evidence.
  private func pomodoroReminderCounts() -> [String: Int] {
    guard let engine else { return [:] }
    var counts: [String: Int] = [:]
    for kind in PostureKind.allCases {
      counts[kind.rawValue] = engine.reminderCount(for: kind)
    }
    return counts
  }

  /// The parent-facing timeline, and the thing this wiring has to get right: every status change
  /// closes the open segment at the current sample time and opens the next one, so a child who sits
  /// well writes a `"good"` segment like any other posture. Emitting only the bad postures would
  /// leave the good-posture ratio at zero for ever, which reads as a charting bug when it is in fact
  /// a missing segment.
  ///
  /// A paused focus writes `PosturePalette.pausedKind` instead: the time is not the child sitting in
  /// some posture, it is time the pomodoro did not count, and the band has to say so (B1 and B2).
  private func accumulatePomodoroSegment(at t: TimeInterval) {
    let kind: String? = pomodoroFocusPaused ? PosturePalette.pausedKind : engine?.status.rawValue
    guard let kind else { return }
    guard let open = pomodoroOpenSegment else {
      pomodoroOpenSegment = (kind: kind, start: t)
      return
    }
    guard open.kind != kind else { return }
    pomodoroSegments.append(PostureSegment(kind: open.kind,
                                          start: pomodoroEpoch(open.start),
                                          end: pomodoroEpoch(t)))
    pomodoroOpenSegment = (kind: kind, start: t)
  }

  /// Closes the segment in flight. A gap with nobody in frame reaches this the same way every other
  /// status does: the engine reports `.no_person` and the segment is written as `"no_person"`.
  private func closePomodoroSegment(at t: TimeInterval) {
    guard let open = pomodoroOpenSegment else { return }
    pomodoroSegments.append(PostureSegment(kind: open.kind,
                                          start: pomodoroEpoch(open.start),
                                          end: pomodoroEpoch(t)))
    pomodoroOpenSegment = nil
  }

  /// Sample time to epoch seconds, on the same origin as the timer's records.
  private func pomodoroEpoch(_ t: TimeInterval) -> Double { pomodoroEpochOrigin + t }

  /// Writes the pomodoro that finished, once a skipped break can no longer change it.
  private func flushPomodoroPending() {
    guard let pending = pomodoroPending else { return }
    pomodoroPending = nil
    pomodoroStore.add(pending)
    refreshReport()
    refreshPomodoroSnapshot()
  }

  /// Ends the run: a focus still in flight is closed as abandoned so its real focus time is not lost,
  /// and the finished record is written.
  private func endPomodoroRun() {
    guard !pomodoroRunFinished, var pomodoro else {
      flushPomodoroPending()
      return
    }
    pomodoroRunFinished = true
    let t = pomodoroLastT
    let events = pomodoro.finish(at: t)
    self.pomodoro = pomodoro
    for event in events { handlePomodoroEvent(event, at: t) }
    flushPomodoroPending()
  }

  /// The scripted run is over: the record is written and the child's screen stays where it is. The
  /// runner kills the app when it has what it needs.
  private func finishPomodoroRun() {
    endPomodoroRun()
    stopInput()
    restoreScreen()
    refreshPomodoroSnapshot()
  }

  private func startPomodoroInput() {
    // The depth sensor is the child's screen, not the focus's: it runs before the first 开始 so the
    // cloud is already there, and it is only the parent-facing report that gives the sensor up.
    guard phase != .report, !pomodoroRunFinished, inputSource == nil else { return }
    let source = makeSource()
    source.onSample = { [weak self] sample in self?.handlePomodoro(sample) }
    inputSource = source
    // A source counts from zero; the shared clock carries on where the last one stopped. Without this
    // a second source would rewind the countdown and the posture clock with it.
    pomodoroClockOffset = pomodoroLastT
    if pomodoroSettings.settings.keepScreenAwake {
      UIApplication.shared.isIdleTimerDisabled = true
    }
    source.start()
  }

  private var pomodoroRunLive: Bool { pomodoroStarted && !pomodoroRunFinished }

  /// The whole child-facing state, as one value, refreshed per sample so the countdown moves with the
  /// shared clock instead of a timer of its own.
  private func refreshPomodoroSnapshot() {
    guard let pomodoro else {
      pomodoroSnapshot = nil
      return
    }
    let snapshot = PomodoroSnapshot(phase: pomodoro.phase,
                                    isRunning: pomodoro.isRunning,
                                    remainingSeconds: pomodoro.remainingSeconds,
                                    focusIndex: pomodoro.focusIndex,
                                    completedToday: pomodoroCompletedTodayCount,
                                    focusStarted: pomodoroFocusOpen)
    if snapshot != pomodoroSnapshot { pomodoroSnapshot = snapshot }
  }

  /// The child's screen never plays the level-1 tone (`GLOSSARY.md`: zero attention interruption) and
  /// speaks only when the pomodoro settings allow it. The engine still times, logs and counts every
  /// reminder; only the sound is dropped.
  private func applyPomodoroAudio(_ chosen: PomodoroSettings) {
    player.playsGentleTones = false
    player.isVoiceEnabled = chosen.postureVoiceEnabled
    player.volume = chosen.postureVoiceVolume
  }

  /// Each focus is logged as a posture session of its own, so the log reads as one
  /// `session_started` / `session_ended` pair per pomodoro record.
  private func logPomodoroFocusStarted() {
    logger.log(.sessionStarted(scenario: simulatedScenario?.rawValue))
    let config = settings.engineConfig
    logger.log(.config(sensitivity: settings.sensitivity,
                       distanceThresholdCM: config.distanceThresholdCM,
                       pitchThresholdDeg: config.pitchThresholdDeg))
    // A fresh session starts with a fresh layer baseline, so the first `view_mode` line always lands.
    lastViewMode = nil
    logViewModeChange()
  }

  // MARK: - Screens

  /// Writes a `view_mode` line when the visible layers change, so the avatar/overlay switches are
  /// captured without a line per sample.
  private func logViewModeChange() {
    let mode = settings.avatarEnabled ? "avatar" : "board"
    let current = (mode: mode, overlay: settings.debugEnabled, avatar: settings.avatarEnabled)
    guard lastViewMode == nil || lastViewMode! != current else { return }
    lastViewMode = current
    logger.log(.viewMode(mode: mode, overlay: current.overlay, avatar: current.avatar))
  }

  func didShow(_ screen: String) {
    logger.log(.screenShown(name: screen))
    Task {
      try? await Task.sleep(for: .seconds(0.4))
      logger.screenshot(screen)
    }
  }

  // MARK: - Input plumbing

  private func makeSource() -> SampleSource {
    if let scenario = simulatedScenario {
      return SimulatedSampleSource(scenario: scenario)
    }
    return DepthCaptureSource()
  }

  private func stopInput() {
    inputSource?.stop()
    inputSource = nil
    // No source means no fresh geometry; drop the last frame so a stale avatar cannot linger.
    latestGeometry = nil
    latestAssessment = nil
  }

  private func restoreScreen() {
    UIApplication.shared.isIdleTimerDisabled = false
  }
}
