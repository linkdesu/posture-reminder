import AVFoundation
import Foundation

/// Plays reminder audio: a short generated tone for the gentle level, and a bundled pre-recorded
/// clip for the voice level.
///
/// Voice clips are serialized — one at a time, in `PostureKind.priority` order, the next starting
/// when the previous finishes. Gentle tones skip the queue and are never blocked by it.
///
/// The player knows nothing about pomodoro sessions or any other surface. A surface that wants
/// different behaviour (for example, no level-1 tone during focus) sets `playsGentleTones`,
/// `isVoiceEnabled` and `volume`; the engine still times, logs and counts every reminder.
@MainActor
final class ReminderPlayer: NSObject, AVAudioPlayerDelegate {
  /// The extension of the bundled placeholder clips. Each clip is named `<PostureKind.rawValue>.wav`;
  /// see `PostureLab/Resources/Audio/README.md`.
  private static let clipExtension = "wav"

  private let logger: DebugLogging
  private var tonePlayer: AVAudioPlayer?
  private var voicePlayer: AVAudioPlayer?
  private var pendingVoices: [PostureKind] = []
  /// True while a level-2 clip is in flight. Only one voice clip plays at a time.
  private var isPlayingVoice = false
  /// Ticks down while a clip is in flight; see `armWatchdog`.
  private var watchdog: Task<Void, Never>?
  /// The kind whose clip is in flight, so a late playback error can still name it in the log.
  private var currentKind: PostureKind?
  private var cachedTone: Data?
  private var didConfigureSession = false
  /// When the last gentle tone started; `playTone` drops anything inside `toneCoalesceWindow` of it.
  private var lastToneStart: TimeInterval = -TimeInterval.infinity
  private var storedVolume: Double = 0.8

  /// Whether level-2 posture clips are audible. The pomodoro settings switch maps onto this.
  var isVoiceEnabled = true

  /// Whether the level-1 tone is audible. With this off, a gentle reminder is still emitted, logged
  /// and counted by the engine; only the sound is dropped.
  var playsGentleTones = true

  /// Playback volume for both levels, clamped to 0...1.
  var volume: Double {
    get { storedVolume }
    set {
      storedVolume = min(max(newValue, 0), 1)
      tonePlayer?.volume = Float(storedVolume)
      voicePlayer?.volume = Float(storedVolume)
    }
  }

  /// `settings` is accepted for call-site compatibility; the surface that owns the session now
  /// drives `isVoiceEnabled`, `playsGentleTones` and `volume` directly.
  init(settings _: Settings, logger: DebugLogging) {
    self.logger = logger
    super.init()
  }

  func play(kind: PostureKind, level: ReminderLevel) {
    switch level {
    case .gentle:
      guard playsGentleTones else { return }
      configureSessionIfNeeded()
      playTone()
    case .voice:
      guard isVoiceEnabled else { return }
      enqueue(kind)
    }
  }

  func stop() {
    tonePlayer?.stop()
    tonePlayer = nil
    voicePlayer?.stop()
    voicePlayer = nil
    // Nothing is audible any more, so the next tone is not an overlap of the one just stopped.
    lastToneStart = -TimeInterval.infinity
    pendingVoices.removeAll()
    isPlayingVoice = false
    cancelWatchdog()
    currentKind = nil
  }

  // MARK: - AVAudioPlayerDelegate

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in
      // A finish reported after the watchdog gave up on it belongs to a clip the queue has
      // already moved past.
      guard player === self.voicePlayer else { return }
      self.finishCurrentVoice()
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in
      guard player === self.voicePlayer else { return }
      if let kind = self.currentKind {
        // The clip existed but could not be decoded; that is a missing reminder from the child's
        // point of view and must not pass silently.
        self.logger.log(.speechUnavailable(kind: kind))
      }
      self.finishCurrentVoice()
    }
  }

  /// A higher-priority kind jumps ahead of every lower-priority entry already queued; entries of
  /// equal priority keep arrival order.
  private func enqueue(_ kind: PostureKind) {
    let insertAt = pendingVoices.firstIndex { $0.priority > kind.priority } ?? pendingVoices.endIndex
    pendingVoices.insert(kind, at: insertAt)
    playNextVoice()
  }

  private func playNextVoice() {
    guard !isPlayingVoice, !pendingVoices.isEmpty else { return }
    let kind = pendingVoices.removeFirst()
    // An experimental posture has no clip (`voiceLine == nil`), and the right amount of audio for
    // it is none: the entry is dropped instead of being faked with a tone.
    guard kind.voiceLine != nil else {
      playNextVoice()
      return
    }
    guard let url = Bundle.main.url(forResource: kind.rawValue, withExtension: Self.clipExtension) else {
      // A missing asset is a deployment fault, not a reason to crash or to fall back to a tone.
      logger.log(.speechUnavailable(kind: kind))
      playNextVoice()
      return
    }
    guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else {
      logger.log(.speechUnavailable(kind: kind))
      playNextVoice()
      return
    }
    configureSessionIfNeeded()
    player.delegate = self
    player.volume = Float(storedVolume)
    player.prepareToPlay()
    guard player.play() else {
      logger.log(.speechUnavailable(kind: kind))
      playNextVoice()
      return
    }
    voicePlayer = player
    isPlayingVoice = true
    currentKind = kind
    armWatchdog(kind: kind, duration: player.duration)
  }

  /// The clip is done — normally, by decode error or by watchdog — so the next queued clip may start.
  private func finishCurrentVoice() {
    isPlayingVoice = false
    voicePlayer = nil
    currentKind = nil
    cancelWatchdog()
    playNextVoice()
  }

  /// `.playback` keeps the cue audible even with the ringer switch silenced.
  private func configureSessionIfNeeded() {
    guard !didConfigureSession else { return }
    didConfigureSession = true
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    try? session.setActive(true)
  }

  /// Tones deliberately skip the voice queue, so nothing below settles the reminders that land in the
  /// same tick — and the desk-lean scenario breaches desk-lean, near and head-down together, which is
  /// three gentle reminders at one instant. Layering them is a fault to the ear, not a stronger hint,
  /// so a tone that would start inside this window of the previous one is dropped instead. The window
  /// is the 0.15s tone plus a little slack, short enough that a reminder from a later tick still gets
  /// its own cue. Voices keep their own serialization and are not affected.
  private static let toneCoalesceWindow: TimeInterval = 0.25

  private func playTone() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastToneStart >= Self.toneCoalesceWindow else { return }
    guard let player = try? AVAudioPlayer(data: toneData()) else { return }
    player.volume = Float(storedVolume)
    player.prepareToPlay()
    player.play()
    tonePlayer = player
    lastToneStart = now
  }

  /// A missing finish callback would wedge the queue, so a clip gets a deadline.
  ///
  /// The asset's own duration is exact, unlike the old speech estimate; the extra 2s only has to
  /// cover a late delegate callback, so a normal clip is never cut short.
  private func armWatchdog(kind: PostureKind, duration: TimeInterval) {
    cancelWatchdog()
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(duration + 2))
      guard !Task.isCancelled, let self else { return }
      self.logger.log(.speechTimeout(kind: kind, level: .voice))
      // Stop the stalled clip so it cannot talk over the next one, then move on as if it had
      // reported its own finish.
      self.voicePlayer?.stop()
      self.finishCurrentVoice()
    }
  }

  private func cancelWatchdog() {
    watchdog?.cancel()
    watchdog = nil
  }

  private func toneData() -> Data {
    if let cachedTone { return cachedTone }
    let data = ReminderPlayer.makeTone()
    cachedTone = data
    return data
  }

  /// Builds a 0.15s 880Hz mono 16-bit WAV in memory with a fade-out to avoid a click.
  private static func makeTone() -> Data {
    let sampleRate = 44100.0
    let frequency = 880.0
    let frameCount = Int(sampleRate * 0.15)
    var samples = [Int16](repeating: 0, count: frameCount)
    for index in 0..<frameCount {
      let fade = 1 - Double(index) / Double(frameCount)
      let value = sin(2 * .pi * frequency * Double(index) / sampleRate) * fade
      samples[index] = Int16(value * Double(Int16.max))
    }
    return wav(from: samples, sampleRate: sampleRate)
  }

  private static func wav(from samples: [Int16], sampleRate: Double) -> Data {
    let channels = 1
    let bitsPerSample = 16
    let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = samples.count * MemoryLayout<Int16>.size

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.append(littleEndian(UInt32(36 + dataSize)))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    data.append(littleEndian(UInt32(16)))
    data.append(littleEndian(UInt16(1)))
    data.append(littleEndian(UInt16(channels)))
    data.append(littleEndian(UInt32(sampleRate)))
    data.append(littleEndian(UInt32(byteRate)))
    data.append(littleEndian(UInt16(blockAlign)))
    data.append(littleEndian(UInt16(bitsPerSample)))
    data.append("data".data(using: .ascii)!)
    data.append(littleEndian(UInt32(dataSize)))
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    return data
  }

  private static func littleEndian(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  private static func littleEndian(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }
}
