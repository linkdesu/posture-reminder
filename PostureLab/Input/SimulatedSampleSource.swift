import Foundation

/// Replays a `Scenario` on the wall clock at 10Hz, without a camera.
final class SimulatedSampleSource: SampleSource {
  var onSample: ((PostureSample) -> Void)?

  /// Length of the replayed scenario; the coordinator ends the run with it.
  var duration: TimeInterval { scenario.duration }

  private let scenario: Scenario
  private var timer: Timer?
  private var t: TimeInterval = 0

  private static let tickInterval: TimeInterval = 0.1

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

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Advances the nominal clock rather than reading the wall clock, so jitter in the
  /// timer never changes the timestamps the engine sees.
  private func emitFrame() {
    onSample?(scenario.sample(at: t))
    t += Self.tickInterval
  }
}
