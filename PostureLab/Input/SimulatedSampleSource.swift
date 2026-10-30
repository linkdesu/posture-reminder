import Foundation

/// Replays a `Scenario` on the wall clock at 10Hz, without a camera.
final class SimulatedSampleSource: SampleSource {
  var onSample: ((PostureSample) -> Void)?

  private let scenario: Scenario
  private var timer: Timer?
  private var t: TimeInterval = 0
  /// Wall time, in seconds after the clock restarts, during which the scripted camera stays silent.
  /// Debug-only reproduction of a sensor that answers late: the timer and the timeline run, no
  /// posture sample arrives, so the focus writes a real「识别中」段 instead of a synthetic one.
  var warmupAfterRestart: TimeInterval = 0
  private var warmupRemaining: TimeInterval = 0

  /// One tick of the source clock; the shared pomodoro clock keeps it in step after a restart.
  static let tickInterval: TimeInterval = 0.1

  init(scenario: Scenario) {
    self.scenario = scenario
  }

  func start() {
    guard timer == nil else { return }
    t = 0
    emitFrame()
    timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      self?.emitFrame()
    }
  }

  /// Puts the script back at its zero without a frame of its own. A scripted run anchors its script
  /// on the focus being recorded (AC7), so the controller restarts the clock at 开始 and the next
  /// timer tick is script time 0.
  func restartClock() {
    t = 0
    warmupRemaining = warmupAfterRestart
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Advances the nominal clock rather than reading the wall clock, so jitter in the
  /// timer never changes the timestamps the engine sees.
  private func emitFrame() {
    if warmupRemaining > 0 {
      warmupRemaining -= Self.tickInterval
      t += Self.tickInterval
      return
    }
    onSample?(scenario.sample(at: t))
    t += Self.tickInterval
  }
}
