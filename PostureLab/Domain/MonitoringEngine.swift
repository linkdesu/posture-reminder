import Foundation

/// Pure reminder state machine driven by externally injected time. Time comes only
/// from `PostureSample.t`, so replaying a recorded sample stream is reproducible.
///
/// v0.3 runs one identical episode machine per `PostureKind` over the breaching flags that
/// `PostureClassifier` produces, instead of a hand-written path per posture.
struct MonitoringEngine {
  struct Config: Equatable {
    var thresholds: PostureThresholds
    /// The calibrated reference the classifier measures deviations against.
    var baseline: PostureBaseline
    var gentleDelay: TimeInterval
    var voiceDelay: TimeInterval
    var cooldown: TimeInterval
    var absencePauseDelay: TimeInterval
    /// When on, the experimental tier may emit a level-1 reminder; it never reaches level 2
    /// because `PostureKind.voiceLine` is nil for those kinds. Default off: detect-and-log only.
    var speaksExperimentalPostures: Bool

    init(thresholds: PostureThresholds,
         baseline: PostureBaseline,
         gentleDelay: TimeInterval = 5,
         voiceDelay: TimeInterval = 15,
         cooldown: TimeInterval = 30,
         absencePauseDelay: TimeInterval = 3,
         speaksExperimentalPostures: Bool = false) {
      self.thresholds = thresholds
      self.baseline = baseline
      self.gentleDelay = gentleDelay
      self.voiceDelay = voiceDelay
      self.cooldown = cooldown
      self.absencePauseDelay = absencePauseDelay
      self.speaksExperimentalPostures = speaksExperimentalPostures
    }

    /// The v2 spellings of the two thresholds, read off the table.
    var distanceThresholdCM: Double { thresholds.distanceCM }
    var pitchThresholdDeg: Double { thresholds.pitchDeg }

    /// Thresholds plus the upright reference baseline, with no measured distance or pitch: for
    /// callers that inject the calibrated pair into `MonitoringEngine.init` themselves.
    static func forSensitivity(_ s: Sensitivity) -> Config {
      Config(thresholds: .forSensitivity(s),
             baseline: PostureBaseline(distanceCM: 0,
                                       pitchDeg: 0,
                                       rollDeg: 0,
                                       shoulderTiltDeg: 0,
                                       headHeight: PostureBaseline.uprightHeadHeight,
                                       headDepthM: PostureBaseline.uprightHeadDepthM,
                                       shoulderWidth: PostureBaseline.uprightShoulderWidth,
                                       neckToRoot: PostureBaseline.uprightNeckToRoot))
    }
  }

  private struct Episode {
    var inBreach = false
    /// Breach seconds accumulated from `dt`; a pause freezes it, and the sample that opens an
    /// episode contributes nothing.
    var breachSeconds: Double = 0
    /// `breachSeconds` when level 1 fired; nil means this episode has not spoken yet.
    var gentleAtBreachSeconds: Double?
    var hasFiredVoice = false
    /// Survives an episode reset, for the cooldown. Compared on the sample clock, not this one.
    var lastReminderAt: TimeInterval?
  }

  private struct EpisodeUpdate {
    var episode: Episode
    var reminder: MonitoringEvent?
    var firedGentle: Bool
  }

  /// One `features` line per this many samples: 5 samples at the 10 Hz tick is 2 Hz.
  private static let samplesPerFeatureLine = 5

  private let config: Config
  private let baseline: PostureBaseline
  /// One episode machine per posture; `PostureKind.allCases` is the roster.
  private var episodes: [PostureKind: Episode] = [:]
  /// Episodes that reached level 1 and reminder lines emitted, per posture. Kept per kind rather
  /// than only in the two `SessionSummary` fields so the log and the next slice can read them.
  private var episodeCounts: [PostureKind: Int] = [:]
  private var reminderCounts: [PostureKind: Int] = [:]
  private var samplesSeen = 0
  private var previousSample: PostureSample?
  private var previousAssessment: PostureAssessment?
  /// Whether the previous sample's interval started inside a pause. The dt ending at the first
  /// sample after a resume must not reach the breach accumulators.
  private var previousSampleWasPaused = false
  private var absentSince: TimeInterval?
  private var goodStreakSeconds: Double = 0
  private var lastEmittedStatus: PostureStatus = .good

  private(set) var status: PostureStatus
  private(set) var isPaused: Bool
  private(set) var summary: SessionSummary
  /// The most recent assessment, so the controller can hand the overlay/avatar the exact readings
  /// the engine judged from instead of re-running the classifier.
  private(set) var latestAssessment: PostureAssessment?

  /// The two baseline parameters are the calibrated face values; passing them overrides the ones
  /// already in `config.baseline`, and omitting them uses the config as given.
  init(config: Config,
       baselineDistanceCM: Double? = nil,
       baselinePitchDeg: Double? = nil,
       startedAt: Date = Date()) {
    var baseline = config.baseline
    if let baselineDistanceCM { baseline.distanceCM = baselineDistanceCM }
    if let baselinePitchDeg { baseline.pitchDeg = baselinePitchDeg }
    self.config = config
    self.baseline = baseline
    self.status = .good
    self.isPaused = false
    self.summary = SessionSummary(startedAt: startedAt,
                                  totalSeconds: 0,
                                  goodSeconds: 0,
                                  tooCloseSeconds: 0,
                                  headDownSeconds: 0,
                                  pausedSeconds: 0,
                                  tooCloseCount: 0,
                                  tooCloseRemindCount: 0,
                                  headDownCount: 0,
                                  headDownRemindCount: 0,
                                  longestGoodStreakSeconds: 0)
  }

  /// Episodes of `kind` that reached level 1, whether or not the line was voiced.
  func episodeCount(for kind: PostureKind) -> Int { episodeCounts[kind] ?? 0 }

  /// Reminder lines actually emitted for `kind`.
  func reminderCount(for kind: PostureKind) -> Int { reminderCounts[kind] ?? 0 }

  mutating func ingest(_ sample: PostureSample) -> [MonitoringEvent] {
    var events: [MonitoringEvent] = [
      .sample(t: sample.t, distanceCM: sample.distanceCM, pitchDeg: sample.pitchDeg)
    ]

    let dt = previousSample.map { sample.t - $0.t } ?? 0
    if let previous = previousSample, let priorAssessment = previousAssessment {
      credit(previous, assessment: priorAssessment, dt: dt)
    }

    // Reading time is credited per face tick, which is what the v2 pause rule and the QA
    // verifier (it only ever sees `distance_cm`/`pitch_deg`) agree on.
    if sample.facePresent {
      absentSince = nil
      if isPaused {
        isPaused = false
        events.append(.resumed(t: sample.t))
      }
    } else {
      if absentSince == nil {
        absentSince = sample.t
      }
      if !isPaused, let since = absentSince, sample.t - since >= config.absencePauseDelay {
        isPaused = true
        events.append(.paused(t: sample.t))
      }
    }

    let assessment = PostureClassifier.assess(sample,
                                              baseline: baseline,
                                              thresholds: config.thresholds)
    #if DEBUG
    // 每秒判定的次数：一次 ingest 正好判定一次，埋点贴在这里才不会漏掉暂停/无人之外的样本。
    PerfMonitor.shared.recordAssessment()
    #endif
    latestAssessment = assessment

    // A pause is a hard gate: while it lasts the screen says "nobody there" even when the body is
    // still in frame, because a face-less sample is not a measurement we trust.
    let next = isPaused
      ? .noPerson
      : status(for: assessment, personPresent: sample.facePresent || sample.bodyPresent)
    if next != lastEmittedStatus {
      lastEmittedStatus = next
      status = next
      events.append(.statusChanged(to: next,
                                   t: sample.t,
                                   distanceCM: sample.distanceCM,
                                   pitchDeg: sample.pitchDeg))
    }

    events += advance(sample,
                      assessment: assessment,
                      dt: dt,
                      previousSampleWasPaused: previousSampleWasPaused)

    if samplesSeen % Self.samplesPerFeatureLine == 0 {
      events.append(.features(t: sample.t,
                              readings: assessment.readings,
                              highlighted: assessment.highlighted))
    }
    samplesSeen += 1

    previousSample = sample
    previousAssessment = assessment
    previousSampleWasPaused = isPaused
    return events
  }

  mutating func finish(at t: TimeInterval) -> [MonitoringEvent] {
    if let previous = previousSample, let priorAssessment = previousAssessment {
      credit(previous, assessment: priorAssessment, dt: t - previous.t)
      previousSample = nil
      previousAssessment = nil
    }
    return [.sessionEnded(summary: summary)]
  }

  /// The displayed state is the highest-priority breaching posture, `good` when nothing breaches,
  /// and `no_person` when neither the face nor the body is in frame.
  private func status(for assessment: PostureAssessment, personPresent: Bool) -> PostureStatus {
    guard personPresent else { return .noPerson }
    guard let dominant = assessment.dominant else { return .good }
    return .posture(dominant)
  }

  /// Steps every posture's episode machine over this sample's breach flags and returns the
  /// reminders the child gets to hear.
  ///
  /// A pause is a hard gate: while it lasts no episode moves at all, so a face-lost-but-body-present
  /// breach can neither escalate nor fire behind it. Entering a pause does not reset an episode —
  /// stopping the clock must not throw away how long the child had already been breaching.
  ///
  /// Every breaching, speakeable posture emits its own reminder and keeps its own clock, so each
  /// kind is timed, logged and counted independently; the reminders of one tick are ordered by
  /// `PostureKind.priority` ascending. Keeping them from overlapping is the player's job, not the
  /// engine's. The experimental tier joins the stream only when `canSpeak` allows it, and never
  /// gets past level 1 (see `advanced`).
  private mutating func advance(_ sample: PostureSample,
                                assessment: PostureAssessment,
                                dt: TimeInterval,
                                previousSampleWasPaused: Bool) -> [MonitoringEvent] {
    guard !isPaused else { return [] }

    let breached = Set(PostureKind.allCases.filter { assessment.breached[$0] == true })

    var events: [MonitoringEvent] = []
    for kind in PostureKind.allCases.sorted(by: { $0.priority < $1.priority }) {
      let update = advanced(episodes[kind] ?? Episode(),
                            breached: breached.contains(kind),
                            kind: kind,
                            sample: sample,
                            dt: dt,
                            canAccrue: !previousSampleWasPaused)
      episodes[kind] = update.episode
      guard update.firedGentle || update.reminder != nil else { continue }
      if update.firedGentle { episodeCounts[kind, default: 0] += 1 }
      if let reminder = update.reminder, canSpeak(kind) {
        reminderCounts[kind, default: 0] += 1
        events.append(reminder)
      }
    }

    // v0.3 keeps the two v2 summary fields; the rest of the per-kind counters stay above.
    summary.tooCloseCount = episodeCounts[.near] ?? 0
    summary.tooCloseRemindCount = reminderCounts[.near] ?? 0
    summary.headDownCount = episodeCounts[.headDown] ?? 0
    summary.headDownRemindCount = reminderCounts[.headDown] ?? 0

    // The same counters reach the summary once per posture, so the log and the summary screen read
    // one number each. Only `episodes`/`reminders` are written here: `credit` owns the seconds half
    // of every entry, and merging field by field leaves what it accumulated in place.
    for kind in PostureKind.allCases {
      var stat = summary.postureStats[kind.rawValue]
        ?? PostureStat(episodes: 0, reminders: 0, seconds: 0)
      stat.episodes = episodeCounts[kind] ?? 0
      stat.reminders = reminderCounts[kind] ?? 0
      summary.postureStats[kind.rawValue] = stat
    }
    return events
  }

  /// The experimental tier is display-and-log only unless the experimental flag is on. This is the
  /// single place that keeps a kind out of the reminder stream: a non-experimental kind always may
  /// speak, an experimental one only when the flag is set. It still breaches, still moves `status`,
  /// still reaches `features` either way.
  private func canSpeak(_ kind: PostureKind) -> Bool {
    kind.tier == .experimental ? config.speaksExperimentalPostures : true
  }

  /// An interval belongs to the sample at its start; the sample without a face accrues paused time
  /// instead of reading time.
  ///
  /// Per-posture breach seconds follow the same interval rule and a pause stops them: `isPaused`
  /// here is the state the interval started in, so an interval that opens inside a pause adds zero.
  private mutating func credit(_ sample: PostureSample,
                              assessment: PostureAssessment,
                              dt: TimeInterval) {
    if !isPaused {
      for kind in PostureKind.allCases where assessment.breached[kind] == true {
        let zero = PostureStat(episodes: 0, reminders: 0, seconds: 0)
        summary.postureStats[kind.rawValue, default: zero].seconds += dt
      }
    }
    guard sample.facePresent else {
      summary.pausedSeconds += dt
      return
    }
    summary.totalSeconds += dt
    let tooClose = assessment.breached[.near] == true
    let headDown = assessment.breached[.headDown] == true
    if tooClose { summary.tooCloseSeconds += dt }
    if headDown { summary.headDownSeconds += dt }
    // Good reading time is "the face is present and nothing breaches at all" — the same condition
    // as `status == .good`. Judging it from the two v2 kinds alone made every session in a newer
    // posture read back as perfect in exactly the sessions the app had intervened in.
    if assessment.dominant != nil {
      goodStreakSeconds = 0
    } else {
      summary.goodSeconds += dt
      goodStreakSeconds += dt
      if goodStreakSeconds > summary.longestGoodStreakSeconds {
        summary.longestGoodStreakSeconds = goodStreakSeconds
      }
    }
  }

  private func advanced(_ episode: Episode,
                        breached: Bool,
                        kind: PostureKind,
                        sample: PostureSample,
                        dt: TimeInterval,
                        canAccrue: Bool) -> EpisodeUpdate {
    var next = episode

    guard breached else {
      // A good sample ends the episode; `breachSeconds` restarts with the next one.
      next.inBreach = false
      next.breachSeconds = 0
      next.gentleAtBreachSeconds = nil
      next.hasFiredVoice = false
      return EpisodeUpdate(episode: next, reminder: nil, firedGentle: false)
    }

    if next.inBreach {
      // The sample that opens an episode contributes nothing: `dt` belongs to the interval before
      // it, which was not breaching. A paused interval (`canAccrue == false`) adds nothing either,
      // so the clock resumes where it stopped instead of counting the pause.
      if canAccrue { next.breachSeconds += dt }
    } else {
      next.inBreach = true
      next.breachSeconds = 0
      next.gentleAtBreachSeconds = nil
      next.hasFiredVoice = false
    }

    if next.gentleAtBreachSeconds == nil {
      // The breach clock stops during a pause; the cooldown clock does not — it is sample time, so
      // being away longer than `cooldown` lets the next reminder through as soon as it is needed.
      // Cooldown gates only an episode's first reminder, never the gentle-to-voice escalation:
      // the acceptance test requires voice at 15s of sustained breach, which a 30s gap between
      // the two levels would contradict.
      let cooledDown = next.lastReminderAt.map { sample.t - $0 >= config.cooldown } ?? true
      if next.breachSeconds >= config.gentleDelay, cooledDown {
        next.gentleAtBreachSeconds = next.breachSeconds
        next.lastReminderAt = sample.t
        let reminder = MonitoringEvent.reminder(kind: kind,
                                                level: .gentle,
                                                t: sample.t,
                                                breachSeconds: next.breachSeconds,
                                                distanceCM: sample.distanceCM,
                                                pitchDeg: sample.pitchDeg)
        return EpisodeUpdate(episode: next, reminder: reminder, firedGentle: true)
      }
    } else if !next.hasFiredVoice, let gentleAt = next.gentleAtBreachSeconds,
              next.breachSeconds - gentleAt >= config.voiceDelay - config.gentleDelay {
      // Level 2 exists only to speak. A kind without a voice line (the experimental tier) is
      // capped at level 1 here, so the tier never has to be special-cased a second time.
      guard kind.voiceLine != nil else {
        next.hasFiredVoice = true
        return EpisodeUpdate(episode: next, reminder: nil, firedGentle: false)
      }
      next.hasFiredVoice = true
      next.lastReminderAt = sample.t
      let reminder = MonitoringEvent.reminder(kind: kind,
                                              level: .voice,
                                              t: sample.t,
                                              breachSeconds: next.breachSeconds,
                                              distanceCM: sample.distanceCM,
                                              pitchDeg: sample.pitchDeg)
      return EpisodeUpdate(episode: next, reminder: reminder, firedGentle: false)
    }

    return EpisodeUpdate(episode: next, reminder: nil, firedGentle: false)
  }
}
