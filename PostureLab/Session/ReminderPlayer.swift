import AVFoundation
import Foundation

/// Plays reminder audio: a short tone for the gentle level, Chinese speech for the voice level.
///
/// Voice lines are serialized — one at a time, `near` ahead of `head_down`, the next starting when
/// the previous finishes. Gentle tones skip the queue and are never blocked by it.
@MainActor
final class ReminderPlayer: NSObject, AVSpeechSynthesizerDelegate {
  private let settings: Settings
  private var player: AVAudioPlayer?
  private let synthesizer = AVSpeechSynthesizer()
  private var pendingVoices: [ReminderKind] = []
  private var isSpeaking = false
  private var cachedTone: Data?
  private var didConfigureSession = false

  init(settings: Settings) {
    self.settings = settings
    super.init()
    synthesizer.delegate = self
  }

  func play(kind: ReminderKind, level: ReminderLevel) {
    guard shouldPlay(level) else { return }
    configureSessionIfNeeded()
    switch level {
    case .gentle:
      playTone()
    case .voice:
      enqueue(kind)
    }
  }

  func stop() {
    player?.stop()
    player = nil
    pendingVoices.removeAll()
    isSpeaking = false
    synthesizer.stopSpeaking(at: .immediate)
  }

  // MARK: - AVSpeechSynthesizerDelegate

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.playNextVoice() }
  }

  /// `near` jumps ahead of any queued `head_down`; within one kind arrival order is kept.
  private func enqueue(_ kind: ReminderKind) {
    if kind == .tooClose, let headDown = pendingVoices.firstIndex(of: .headDown) {
      pendingVoices.insert(kind, at: headDown)
    } else {
      pendingVoices.append(kind)
    }
    playNextVoice()
  }

  private func playNextVoice() {
    guard !isSpeaking, !pendingVoices.isEmpty else { return }
    isSpeaking = true
    speak(pendingVoices.removeFirst())
  }

  private func shouldPlay(_ level: ReminderLevel) -> Bool {
    switch settings.reminderMode {
    case .sound: return level == .gentle
    case .voice: return level == .voice
    case .both: return true
    }
  }

  /// `.playback` keeps the tone audible even with the ringer switch silenced.
  private func configureSessionIfNeeded() {
    guard !didConfigureSession else { return }
    didConfigureSession = true
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    try? session.setActive(true)
  }

  private func playTone() {
    guard let player = try? AVAudioPlayer(data: toneData()) else { return }
    player.prepareToPlay()
    player.play()
    self.player = player
  }

  private func speak(_ kind: ReminderKind) {
    let text: String
    switch kind {
    case .tooClose: text = "离书太近啦，坐直一点哦"
    case .headDown: text = "头抬起来一点哦"
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    synthesizer.speak(utterance)
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
