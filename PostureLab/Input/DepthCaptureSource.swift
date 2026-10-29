import AVFoundation
import Foundation

/// Real-device input: the front TrueDepth camera's depth stream plus the colour frame the pose model
/// runs on.
///
/// The session has two outputs for two reasons: iOS will not stream depth from the TrueDepth camera
/// unless a video output is attached, and the pose model needs pixels. The video output's delegate
/// keeps **the most recent frame only** — a borrowed `CVPixelBuffer` reference, no copy — and every
/// depth frame consumes it once and clears it. Nothing here draws it, encodes it, writes it to disk or
/// puts it in a log line; the engine's sample carries joints, a depth grid and depth points only. The
/// body mask and the point cloud still come from the depth frame (see `VisionPoseMapping`).
///
/// Depth frames arrive on `queue`; segmentation, pose and joint estimation run there, and only the
/// finished `PostureSample` hops to the main thread.
final class DepthCaptureSource: NSObject, SampleSource {
  var onSample: ((PostureSample) -> Void)?

  private let jointSource: JointSource
  private let session = AVCaptureSession()
  private let depthOutput = AVCaptureDepthDataOutput()
  /// One frame of colour, replaced by the next and dropped by the depth frame that uses it. It is
  /// the graph's second output, and the only thing that ever touches its bytes is the pose model.
  private let videoOutput = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "me.xieal.posturelab.vision", qos: .userInitiated)

  private var startedAt: TimeInterval?
  private var lastEmittedAt: TimeInterval = 0
  private var watchdog: DispatchSourceTimer?
  private var isConfigured = false

  /// The depth stream runs at 30 Hz and the state machine is tuned for 10 Hz; this is the sample
  /// rate the timer and the posture engine share.
  private static let sampleInterval: TimeInterval = 0.1
  /// How long without a depth frame before a "nobody there" sample is emitted, so an absent child
  /// still pauses the timer.
  private static let watchdogInterval: TimeInterval = 0.5

  init(jointSource: JointSource = VisionJointSource()) {
    self.jointSource = jointSource
    super.init()
    depthOutput.setDelegate(self, callbackQueue: queue)
    depthOutput.isFilteringEnabled = true
    depthOutput.alwaysDiscardsLateDepthData = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    // A backlog of colour frames would only mean a pose paired with a stale depth frame, so the
    // session drops late frames before they ever reach the delegate.
    videoOutput.alwaysDiscardsLateVideoFrames = true
  }

  func start() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      run()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.run()
        } else {
          self.reportAbsent()
        }
      }
    default:
      reportAbsent()
    }
  }

  func stop() {
    watchdog?.cancel()
    watchdog = nil
    latestColour = nil
    queue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  // MARK: - Session

  private func run() {
    let start = ProcessInfo.processInfo.systemUptime
    startedAt = start
    lastEmittedAt = 0

    queue.async { [weak self] in
      guard let self else { return }
      if !self.isConfigured {
        guard self.configure() else {
          self.reportAbsent()
          return
        }
        self.isConfigured = true
      }
      if !self.session.isRunning { self.session.startRunning() }
      self.startWatchdog()
    }
  }

  /// Builds the capture graph. The depth output is the only one with data flowing out of it.
  private func configure() -> Bool {
    guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera,
                                               for: .video,
                                               position: .front),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input)
    else { return false }

    session.beginConfiguration()
    session.sessionPreset = .vga640x480
    session.addInput(input)

    guard session.canAddOutput(depthOutput), session.canAddOutput(videoOutput) else {
      session.commitConfiguration()
      return false
    }
    session.addOutput(videoOutput)
    session.addOutput(depthOutput)
    // The video output feeds the pose model only: its delegate above keeps one frame for the next
    // depth frame and drops it. No colour pixel leaves this class.
    orient(depthOutput.connection(with: .depthData))
    orient(videoOutput.connection(with: .video))
    session.commitConfiguration()
    return true
  }

  /// Portrait, mirrored like a mirror. Best effort: an unsupported connection keeps the sensor's own
  /// orientation rather than failing the run.
  private func orient(_ connection: AVCaptureConnection?) {
    guard let connection else { return }
    if connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
    if connection.isVideoMirroringSupported {
      connection.isVideoMirrored = true
    }
  }

  private func startWatchdog() {
    guard watchdog == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.watchdogInterval,
                   repeating: Self.watchdogInterval)
    timer.setEventHandler { [weak self] in
      guard let self, let startedAt = self.startedAt else { return }
      let t = ProcessInfo.processInfo.systemUptime - startedAt
      guard t - self.lastEmittedAt >= Self.watchdogInterval * 2 else { return }
      self.emit(.empty, at: t)
    }
    watchdog = timer
    timer.resume()
  }

  /// A frame without a body, or no sensor at all: the timer has to see the absence.
  private func reportAbsent() {
    let t = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    emit(.empty, at: t)
  }

  private func emit(_ estimate: JointEstimate, at t: TimeInterval) {
    let depth = estimate.mask == nil ? nil : lastDepth?.downsampled()
    let sample = PostureSample(t: t,
                               distanceCM: estimate.distanceCM,
                               pitchDeg: estimate.pitchDeg,
                               rollDeg: estimate.rollDeg,
                               joints: estimate.joints,
                               depth: depth,
                               depthAvailable: estimate.mask != nil,
                               cloud: estimate.cloud,
                               unavailableJoints: estimate.unavailable)
    DispatchQueue.main.async { [weak self] in
      self?.onSample?(sample)
    }
  }

  /// The last processing frame, kept only long enough for `emit` to downsample it. It is a depth
  /// grid, never a colour image.
  private var lastDepth: DepthImage?

  /// The newest colour frame, alive only between two depth frames. It is never drawn, encoded or
  /// written: the one consumer is the pose request inside `jointSource`.
  private var latestColour: CVPixelBuffer?
}

extension DepthCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
  /// Keeps the newest frame and returns. The previous one is released here — it is replaced, not
  /// accumulated — so at most one colour frame exists in memory at a time.
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    latestColour = CMSampleBufferGetImageBuffer(sampleBuffer)
  }
}

extension DepthCaptureSource: AVCaptureDepthDataOutputDelegate {
  func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                       didOutput depthData: AVDepthData,
                       timestamp: CMTime,
                       connection: AVCaptureConnection) {
    guard let startedAt else { return }
    let t = ProcessInfo.processInfo.systemUptime - startedAt
    guard t - lastEmittedAt >= Self.sampleInterval else { return }

    // Float32 is the only format this pipeline can read; the conversion is depth-to-depth.
    let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let map = converted.depthDataMap
    guard let image = Self.depthImage(from: map) else { return }

    lastEmittedAt = t
    lastDepth = image
    // The colour frame this depth frame is paired with, handed over once and dropped: `takeColour`
    // clears the reference before the estimate returns.
    let colour = takeColour()
    emit(jointSource.estimate(from: image, colour: colour), at: t)
  }

  /// Hands the most recent colour frame to one estimate and drops it. The buffer is a borrowed
  /// reference: no copy is made here and none is kept after the call.
  private func takeColour() -> CVPixelBuffer? {
    let colour = latestColour
    latestColour = nil
    return colour
  }

  /// Copies the depth plane into a Swift array, then drops the pixel buffer. One plane, one read:
  /// there is no second plane to read even if someone wanted to.
  private static func depthImage(from map: CVPixelBuffer) -> DepthImage? {
    let width = CVPixelBufferGetWidth(map)
    let height = CVPixelBufferGetHeight(map)
    guard width > 0, height > 0 else { return nil }

    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
    let floatCount = bytesPerRow / MemoryLayout<Float>.size
    let buffer = base.assumingMemoryBound(to: Float.self)
    var metres = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
      let row = buffer.advanced(by: y * floatCount)
      for x in 0..<width {
        metres[y * width + x] = row[x]
      }
    }
    return DepthImage(width: width, height: height, metres: metres)
  }
}
