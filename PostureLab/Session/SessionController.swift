import Combine
import Foundation
import UIKit

struct CalibrationResult: Equatable {
  var distanceCM: Double
  var pitchDeg: Double
}

@MainActor
final class SessionController: ObservableObject {
  enum Phase: Equatable {
    case home
    case calibration
    case monitoring
    case summary
    case settings
  }

  enum CalibrationState: Equatable {
    case idle
    case countingDown(Int)          // 3, 2, 1
    case sampling(progress: Double) // 0...1
    case done(CalibrationResult)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .home
  @Published private(set) var status: PostureStatus = .good
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var elapsedSeconds: Double = 0
  @Published private(set) var calibrationState: CalibrationState = .idle
  @Published private(set) var lastSummary: SessionSummary?
  /// The latest sample's body geometry and its assessment, for the avatar and the debug overlay.
  /// Both are cleared when the run ends or the source stops.
  @Published private(set) var latestGeometry: PoseGeometry?
  @Published private(set) var latestAssessment: PostureAssessment?

  let settings: Settings
  let store: SessionStore
  let logger: DebugLogging

  /// Non-empty means scripted replay instead of the camera.
  let scenarios: [Scenario]

  /// Scripted runs only hop to 设置 after the summary when the launch argument asked for it.
  let captureSettings: Bool

  private let player: ReminderPlayer

  private var engine: MonitoringEngine?
  private var inputSource: SampleSource?
  /// Last `view_mode` layer state written, so a settings change only logs when it actually changed
  /// the visible layers. Reset at the start of every run.
  private var lastViewMode: (mode: String, overlay: Bool, avatar: Bool)?
  private var viewModeObservers: Set<AnyCancellable> = []
  private var calibrationTask: Task<Void, Never>?
  private var calibrationDistances: [Double] = []
  private var calibrationPitches: [Double] = []
  private var didCaptureReminderScreenshot = false
  private var didCaptureHighlightScreenshot = false
  private var lastSampleT: TimeInterval = 0
  /// Wall-clock position in the scripted stream, independent of the engine's credited time.
  private var simulationClock: TimeInterval = 0
  private var savedBrightness: Double?

  init(settings: Settings,
       store: SessionStore,
       logger: DebugLogging,
       scenarios: [Scenario] = [],
       captureSettings: Bool = false) {
    self.settings = settings
    self.store = store
    self.logger = logger
    self.scenarios = scenarios
    self.captureSettings = captureSettings
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
  }

  var isSimulating: Bool { !scenarios.isEmpty }

  /// The last summary: this session's if there is one, otherwise the stored one.
  var previousSummary: SessionSummary? { lastSummary ?? store.last }

  private var simulatedScenario: Scenario? { scenarios.first }

  // MARK: - Navigation

  func showHome() {
    stopInput()
    cancelCalibration()
    restoreScreen()
    phase = .home
  }

  func showSettings() {
    phase = .settings
  }

  func showCalibration() {
    stopInput()
    cancelCalibration()
    calibrationState = .idle
    phase = .calibration
    beginCalibration()
  }

  func startReading() {
    if isSimulating {
      beginCalibration()
    } else if settings.isCalibrated {
      beginMonitoring()
    } else {
      calibrationState = .idle
      phase = .calibration
      beginCalibration()
    }
  }

  /// A scripted run walks 校准 -> 监测 -> 小结 on its own so QA can launch and walk away;
  /// a real run waits for the 开始阅读 tap.
  func autoStartIfSimulating() {
    guard isSimulating else { return }
    Task { [weak self] in
      // Let the home screen render and its screenshot land before the first transition.
      try? await Task.sleep(for: .seconds(1.2))
      guard let self, self.phase == .home else { return }
      self.startReading()
    }
  }

  // MARK: - Calibration

  func beginCalibration() {
    stopInput()
    cancelCalibration()
    phase = .calibration
    calibrationDistances = []
    calibrationPitches = []
    runCountdown()
  }

  func retryCalibration() {
    calibrationState = .idle
    beginCalibration()
  }

  func acceptCalibration() {
    guard case let .done(result) = calibrationState else { return }
    settings.setBaseline(distanceCM: result.distanceCM, pitchDeg: result.pitchDeg)
    logger.log(.calibrated(baselineDistanceCM: result.distanceCM, baselinePitchDeg: result.pitchDeg))
    stopInput()
    if isSimulating {
      beginMonitoring()
    } else {
      phase = .home
    }
  }

  private func runCountdown() {
    calibrationTask = Task { [weak self] in
      guard let self else { return }
      for remaining in stride(from: 3, through: 1, by: -1) {
        self.calibrationState = .countingDown(remaining)
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
      }
      self.startCalibrationSampling()
    }
  }

  private func startCalibrationSampling() {
    calibrationState = .sampling(progress: 0)

    let source = makeSource()
    source.onSample = { [weak self] sample in
      guard let self else { return }
      if let distance = sample.distanceCM { self.calibrationDistances.append(distance) }
      if let pitch = sample.pitchDeg { self.calibrationPitches.append(pitch) }
    }
    inputSource = source
    source.start()

    let steps = 30 // 3 seconds at 0.1s resolution
    calibrationTask = Task { [weak self] in
      guard let self else { return }
      for step in 1...steps {
        try? await Task.sleep(for: .seconds(0.1))
        if Task.isCancelled { return }
        self.calibrationState = .sampling(progress: Double(step) / Double(steps))
      }
      self.finishCalibrationSampling()
    }
  }

  private func finishCalibrationSampling() {
    stopInput()
    guard let distance = Self.median(calibrationDistances),
          let pitch = Self.median(calibrationPitches) else {
      calibrationState = .failed("没检测到人，请让孩子坐正后重试")
      return
    }

    calibrationState = .done(CalibrationResult(distanceCM: distance, pitchDeg: pitch))
    didShow("calibration_result")

    guard isSimulating else { return }
    // Nobody taps 完成 in a scripted run; hold the result long enough for `didShow` to capture it,
    // then carry on by itself.
    calibrationTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      self?.acceptCalibration()
    }
  }

  /// Median of the non-empty samples; an even count averages the middle pair.
  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  // MARK: - Monitoring

  func beginMonitoring() {
    stopInput()
    cancelCalibration()

    phase = .monitoring
    status = .good
    isPaused = false
    elapsedSeconds = 0
    lastSampleT = 0
    simulationClock = 0
    didCaptureReminderScreenshot = false
    didCaptureHighlightScreenshot = false

    logger.log(.sessionStarted(scenario: simulatedScenario?.rawValue))
    // A fresh run starts with a fresh layer baseline, so the first `view_mode` line always lands.
    lastViewMode = nil
    logViewModeChange()
    let config = settings.engineConfig
    logger.log(.config(sensitivity: settings.sensitivity,
                       distanceThresholdCM: config.distanceThresholdCM,
                       pitchThresholdDeg: config.pitchThresholdDeg))

    engine = MonitoringEngine(config: config,
                              baselineDistanceCM: settings.baselineDistanceCM ?? 0,
                              baselinePitchDeg: settings.baselinePitchDeg ?? 0)

    UIApplication.shared.isIdleTimerDisabled = true
    savedBrightness = UIScreen.main.brightness
    UIScreen.main.brightness = 0.1

    let source = makeSource()
    source.onSample = { [weak self] sample in self?.handle(sample) }
    inputSource = source
    source.start()
  }

  func finishMonitoring() {
    guard phase == .monitoring, var engine else { return }
    stopInput()

    let events = engine.finish(at: lastSampleT)
    self.engine = engine
    for event in events {
      logger.log(event)
    }

    let summary = engine.summary
    store.add(summary)
    lastSummary = summary
    elapsedSeconds = summary.totalSeconds

    restoreScreen()
    phase = .summary

    // QA precondition P2 wants a screenshot of every key screen, and a scripted run never
    // opens 设置 on its own, so that detour is opt-in via `-captureSettings`; a scripted run
    // still returns home once the summary shot has landed.
    guard isSimulating else { return }
    calibrationTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.6))
      guard let self, !Task.isCancelled else { return }
      if self.captureSettings {
        self.phase = .settings
        try? await Task.sleep(for: .seconds(1.6))
        guard !Task.isCancelled else { return }
      }
      self.phase = .home
    }
  }

  private func handle(_ sample: PostureSample) {
    guard var engine else { return }
    let events = engine.ingest(sample)
    self.engine = engine
    lastSampleT = sample.t

    for event in events {
      logger.log(event)
      if case let .reminder(kind, level, _, _, _, _) = event {
        if level == .gentle, !didCaptureReminderScreenshot {
          // Direct capture, no `screen_shown`: the monitoring screen's `screen` value must survive.
          didCaptureReminderScreenshot = true
          logger.screenshot("reminder")
        }
        player.play(kind: kind, level: level)
      }
    }

    status = engine.status
    isPaused = engine.isPaused
    // One shot of the overlay's first highlighted feature per run. Experimental postures
    // never fire a reminder, so without this they would have no screenshot at the moment
    // their feature is actually over threshold, and AC13 asks for one.
    if let highlighted = latestAssessment?.highlighted, !didCaptureHighlightScreenshot {
      didCaptureHighlightScreenshot = true
      logger.screenshot("highlight")
    }
    elapsedSeconds = engine.summary.totalSeconds
    latestGeometry = PoseGeometry(joints: sample.joints, depth: sample.depth)
    latestAssessment = engine.latestAssessment

    // Pauses adding up past five minutes end the session on their own (PRD v0.2).
    if engine.summary.pausedSeconds > 300 {
      finishMonitoring()
      return
    }

    guard let scenario = simulatedScenario else { return }
    simulationClock = max(simulationClock, sample.t)
    if max(simulationClock, elapsedSeconds) >= scenario.duration {
      finishMonitoring()
    }
  }

  // MARK: - Screens

  /// Writes a `view_mode` line when the visible layers change during a run, so the avatar/overlay
  /// switches are captured without a line per sample. No-op outside monitoring.
  private func logViewModeChange() {
    guard phase == .monitoring else { return }
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
    return ARFaceSampleSource()
  }

  private func stopInput() {
    inputSource?.stop()
    inputSource = nil
    // No source means no fresh geometry; drop the last frame so a stale avatar cannot linger.
    latestGeometry = nil
    latestAssessment = nil
  }

  private func cancelCalibration() {
    calibrationTask?.cancel()
    calibrationTask = nil
  }

  private func restoreScreen() {
    UIApplication.shared.isIdleTimerDisabled = false
    if let savedBrightness {
      UIScreen.main.brightness = savedBrightness
      self.savedBrightness = nil
    }
  }
}
