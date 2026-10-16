import Foundation

/// Pure reminder state machine driven by externally injected time. Time comes only
/// from `PostureSample.t`, so replaying a recorded sample stream is reproducible.
struct MonitoringEngine {
  struct Config: Equatable {
    var distanceThresholdCM: Double
    var pitchThresholdDeg: Double
    var gentleDelay: TimeInterval
    var voiceDelay: TimeInterval
    var cooldown: TimeInterval
    var absencePauseDelay: TimeInterval

    init(distanceThresholdCM: Double,
         pitchThresholdDeg: Double,
         gentleDelay: TimeInterval = 5,
         voiceDelay: TimeInterval = 15,
         cooldown: TimeInterval = 30,
         absencePauseDelay: TimeInterval = 3) {
      self.distanceThresholdCM = distanceThresholdCM
      self.pitchThresholdDeg = pitchThresholdDeg
      self.gentleDelay = gentleDelay
      self.voiceDelay = voiceDelay
      self.cooldown = cooldown
      self.absencePauseDelay = absencePauseDelay
    }

    static func forSensitivity(_ s: Sensitivity) -> Config {
      Config(distanceThresholdCM: s.distanceThresholdCM,
             pitchThresholdDeg: s.pitchThresholdDeg)
    }
  }

  private struct Episode {
    var inBreach = false
    var breachStart: TimeInterval?
    var gentleFiredAt: TimeInterval?
    var hasFiredVoice = false
    var lastReminderAt: TimeInterval?
  }

  private struct EpisodeUpdate {
    var episode: Episode
    var reminder: MonitoringEvent?
    var firedGentle: Bool
  }

  private let config: Config
  private let baselineDistanceCM: Double
  private let baselinePitchDeg: Double
  private var tooCloseEpisode = Episode()
  private var headDownEpisode = Episode()
  private var previousSample: PostureSample?
  private var absentSince: TimeInterval?
  private var goodStreakSeconds: Double = 0
  private var lastEmittedStatus: PostureStatus = .good

  private(set) var status: PostureStatus
  private(set) var isPaused: Bool
  private(set) var summary: SessionSummary

  init(config: Config,
       baselineDistanceCM: Double,
       baselinePitchDeg: Double,
       startedAt: Date = Date()) {
    self.config = config
    self.baselineDistanceCM = baselineDistanceCM
    self.baselinePitchDeg = baselinePitchDeg
    self.status = .good
    self.isPaused = false
    self.summary = SessionSummary(startedAt: startedAt,
                                  totalSeconds: 0,
                                  goodSeconds: 0,
                                  tooCloseSeconds: 0,
                                  headDownSeconds: 0,
                                  pausedSeconds: 0,
                                  tooCloseCount: 0,
                                  longestGoodStreakSeconds: 0)
  }

  mutating func ingest(_ sample: PostureSample) -> [MonitoringEvent] {
    var events: [MonitoringEvent] = [
      .sample(t: sample.t, distanceCM: sample.distanceCM, pitchDeg: sample.pitchDeg)
    ]

    if let previous = previousSample {
      credit(previous, dt: sample.t - previous.t)
    }

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

    let next = status(for: sample)
    if next != lastEmittedStatus {
      lastEmittedStatus = next
      status = next
      events.append(.statusChanged(to: next,
                                   t: sample.t,
                                   distanceCM: sample.distanceCM,
                                   pitchDeg: sample.pitchDeg))
    }

    if let reminder = advanceTooClose(sample) {
      events.append(reminder)
    }
    if let reminder = advanceHeadDown(sample) {
      events.append(reminder)
    }

    previousSample = sample
    return events
  }

  mutating func finish(at t: TimeInterval) -> [MonitoringEvent] {
    if let previous = previousSample {
      credit(previous, dt: t - previous.t)
      previousSample = nil
    }
    return [.sessionEnded(summary: summary)]
  }

  private func isTooCloseViolation(_ sample: PostureSample) -> Bool {
    guard let distance = sample.distanceCM else { return false }
    return distance < config.distanceThresholdCM
  }

  private func isHeadDownViolation(_ sample: PostureSample) -> Bool {
    guard let pitch = sample.pitchDeg else { return false }
    return baselinePitchDeg - pitch > config.pitchThresholdDeg
  }

  private func status(for sample: PostureSample) -> PostureStatus {
    guard sample.facePresent else { return .absent }
    if isTooCloseViolation(sample) { return .tooClose }
    if isHeadDownViolation(sample) { return .headDown }
    return .good
  }

  /// An interval belongs to the sample at its start; the sample without a face accrues paused time
  /// instead of reading time.
  private mutating func credit(_ sample: PostureSample, dt: TimeInterval) {
    guard sample.facePresent else {
      summary.pausedSeconds += dt
      return
    }
    summary.totalSeconds += dt
    let tooClose = isTooCloseViolation(sample)
    let headDown = isHeadDownViolation(sample)
    if tooClose { summary.tooCloseSeconds += dt }
    if headDown { summary.headDownSeconds += dt }
    if tooClose || headDown {
      goodStreakSeconds = 0
    } else {
      summary.goodSeconds += dt
      goodStreakSeconds += dt
      if goodStreakSeconds > summary.longestGoodStreakSeconds {
        summary.longestGoodStreakSeconds = goodStreakSeconds
      }
    }
  }

  private mutating func advanceTooClose(_ sample: PostureSample) -> MonitoringEvent? {
    let update = advanced(tooCloseEpisode,
                          breached: sample.facePresent && isTooCloseViolation(sample),
                          kind: .tooClose,
                          sample: sample)
    tooCloseEpisode = update.episode
    if update.firedGentle { summary.tooCloseCount += 1 }
    return update.reminder
  }

  private mutating func advanceHeadDown(_ sample: PostureSample) -> MonitoringEvent? {
    let update = advanced(headDownEpisode,
                          breached: sample.facePresent && isHeadDownViolation(sample),
                          kind: .headDown,
                          sample: sample)
    headDownEpisode = update.episode
    return update.reminder
  }

  private func advanced(_ episode: Episode,
                        breached: Bool,
                        kind: ReminderKind,
                        sample: PostureSample) -> EpisodeUpdate {
    var next = episode

    guard breached else {
      next.inBreach = false
      next.breachStart = nil
      next.gentleFiredAt = nil
      next.hasFiredVoice = false
      return EpisodeUpdate(episode: next, reminder: nil, firedGentle: false)
    }

    if !next.inBreach {
      next.inBreach = true
      next.breachStart = sample.t
      next.gentleFiredAt = nil
      next.hasFiredVoice = false
    }

    let breachStart = next.breachStart ?? sample.t

    if next.gentleFiredAt == nil {
      // Cooldown gates only an episode's first reminder, never the gentle-to-voice escalation:
      // the acceptance test requires voice at 15s of sustained breach, which a 30s gap between
      // the two levels would contradict.
      let cooledDown = next.lastReminderAt.map { sample.t - $0 >= config.cooldown } ?? true
      if sample.t - breachStart >= config.gentleDelay, cooledDown {
        next.gentleFiredAt = sample.t
        next.lastReminderAt = sample.t
        let reminder = MonitoringEvent.reminder(kind: kind,
                                                level: .gentle,
                                                t: sample.t,
                                                breachSeconds: sample.t - breachStart,
                                                distanceCM: sample.distanceCM,
                                                pitchDeg: sample.pitchDeg)
        return EpisodeUpdate(episode: next, reminder: reminder, firedGentle: true)
      }
    } else if !next.hasFiredVoice, let gentleFiredAt = next.gentleFiredAt,
              sample.t - gentleFiredAt >= config.voiceDelay - config.gentleDelay {
      next.hasFiredVoice = true
      next.lastReminderAt = sample.t
      let reminder = MonitoringEvent.reminder(kind: kind,
                                              level: .voice,
                                              t: sample.t,
                                              breachSeconds: sample.t - breachStart,
                                              distanceCM: sample.distanceCM,
                                              pitchDeg: sample.pitchDeg)
      return EpisodeUpdate(episode: next, reminder: reminder, firedGentle: false)
    }

    return EpisodeUpdate(episode: next, reminder: nil, firedGentle: false)
  }
}
