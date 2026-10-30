import AVFoundation
import Foundation

/// 真机输入：前置 TrueDepth 的深度流驱动点云与头几何，前置彩色流只交给 Vision 取关节。
///
/// 两路输出、两个 delegate、两条串行队列（不用 `AVCaptureDataOutputSynchronizer`：它按两个输出都
/// 到齐才回调，任何一路卡住都会让另一路一起停，而点云不该被推理的耗时绑住）。
///
/// - **深度队列（约 30 Hz）**：每个深度帧都重采样、分割、取点云、算头部几何，并把这一帧留在最近八
///   帧的环形缓冲里给关节配对用。点云经 `onCloud` 直接给画布，不再走 10 Hz 的样本。
/// - **彩色队列（约 30 fps，推理约 10 Hz）**：`VisionJointSource` 借这一帧推理，返回后立刻丢掉缓冲。
///   关节按采集时刻与最近一帧深度配对，差超过 150 ms 就整帧作废（`VisionDepthPairing`）。
/// - **样本（10 Hz）**：由深度帧的节流驱动，带配对后的关节、距离、俯仰与点云，喂给引擎与日志。
///
/// 彩色像素在这个类型里只是一个过手的指针：它不进字段、不进日志、不进画面。
final class DepthCaptureSource: NSObject, SampleSource {
  var onSample: ((PostureSample) -> Void)?
  var onCloud: ((CloudFrame) -> Void)?

  private let vision = VisionJointSource()
  private let session = AVCaptureSession()
  private let depthOutput = AVCaptureDepthDataOutput()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let depthQueue = DispatchQueue(label: "me.xieal.posturelab.depth", qos: .userInitiated)
  /// 彩色帧的 delegate 队列就是推理队列：一次只跑一次推理，忙时丢帧。
  private let videoQueue = DispatchQueue(label: "me.xieal.posturelab.vision", qos: .userInitiated)

  /// 状态机按 10 Hz 调；样本仍按这个间隔发。
  private static let sampleInterval: TimeInterval = 0.1
  /// 多久没有深度帧就发一个「没人」的样本，让缺席照样能暂停计时。
  private static let watchdogInterval: TimeInterval = 0.5
  /// 关节与深度配对用的最近深度帧数：八帧在 30 Hz 下约 266 ms，够盖住 150 ms 的配对窗口。
  private static let depthHistoryCount = 8
  /// 分割在 160 px 宽上跑：30 Hz 下这是 CPU 与轮廓精度的折中（与 0.6.7 的深度管线一致）。
  private static let processingWidth = 160

  /// 一帧深度观测：配对时的全部输入。
  private struct DepthObservation {
    var t: TimeInterval
    var image: DepthImage
    var mask: BodyMask?
    var cloud: [BodyPoint]
    var head: HeadGeometry.Reading
  }

  /// 深度队列写、彩色队列读的东西都在这个锁后面。
  private let stateLock = NSLock()
  private var history: [DepthObservation] = []
  private var latestJoints: VisionJointFrame?

  private var startedAt: TimeInterval?
  private var lastEmittedAt: TimeInterval = 0
  private var watchdog: DispatchSourceTimer?
  private var isConfigured = false

  /// 一个深度帧的耗时（毫秒），只给性能埋点读。
  private(set) var lastDepthProcessing: TimeInterval = 0

  override init() {
    super.init()
    depthOutput.setDelegate(self, callbackQueue: depthQueue)
    depthOutput.isFilteringEnabled = true
    depthOutput.alwaysDiscardsLateDepthData = true
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
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
    vision.reset()
    stateLock.lock()
    history.removeAll()
    latestJoints = nil
    stateLock.unlock()
    depthQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  // MARK: - Session

  private func run() {
    let start = ProcessInfo.processInfo.systemUptime
    startedAt = start
    lastEmittedAt = 0
    vision.reset()

    depthQueue.async { [weak self] in
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

  /// 建采集图。深度 30 Hz 驱动点云，彩色 30 fps 只喂 Vision。
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
    orient(depthOutput.connection(with: .depthData))
    orient(videoOutput.connection(with: .video))
    session.commitConfiguration()
    return true
  }

  /// 竖屏、像镜子一样镜像。尽力而为：连接不支持时保留传感器自己的方向，而不是让整次运行失败。
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
    let timer = DispatchSource.makeTimerSource(queue: depthQueue)
    timer.schedule(deadline: .now() + Self.watchdogInterval,
                   repeating: Self.watchdogInterval)
    timer.setEventHandler { [weak self] in
      guard let self, let startedAt = self.startedAt else { return }
      let t = ProcessInfo.processInfo.systemUptime - startedAt
      guard t - self.lastEmittedAt >= Self.watchdogInterval * 2 else { return }
      self.emit(nil, at: t)
    }
    watchdog = timer
    timer.resume()
  }

  /// 一帧都没有深度、或者根本没有传感器：计时器必须看到这个缺席。
  private func reportAbsent() {
    let t = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    emit(nil, at: t)
  }

  /// 时刻最近的深度观测。配对规则本身在 `VisionDepthPairing` 里，纯函数、可单测。
  private func nearestObservation(to t: TimeInterval) -> DepthObservation? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let index = VisionDepthPairing.nearestIndex(to: t, ticks: history.map(\.t)) else { return nil }
    return history[index]
  }

  /// 这一时刻还能用的关节：最近一次配对结果没有过期，且双肩没有因为落在头上被作废。
  private func joints(at t: TimeInterval) -> [JointID: JointSample] {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let frame = latestJoints else { return [:] }
    guard !VisionDepthPairing.isStale(visionT: frame.t, sampleT: t) else { return [:] }
    return frame.joints
  }

  /// 一个样本。`observation` 是这一帧深度（缺席样本为 nil），关节按采集时刻取还新鲜的那一份。
  private func emit(_ observation: DepthObservation?, at t: TimeInterval) {
    let joints = joints(at: t)
    let head = observation?.head ?? HeadGeometry.Reading(distanceCM: nil, pitchDeg: nil, rollDeg: nil)
    let sample = PostureSample(t: t,
                               distanceCM: head.distanceCM,
                               pitchDeg: head.pitchDeg,
                               // 眼线 → 耳线 → 深度平面：彩色给的横滚比深度平面准。
                               rollDeg: VisionPoseMapping.eyeLineDegrees(joints)
                                 ?? VisionPoseMapping.earLineDegrees(joints)
                                 ?? head.rollDeg,
                               joints: joints,
                               depth: observation?.mask == nil ? nil : observation?.image.downsampled(),
                               depthAvailable: observation?.mask != nil,
                               cloud: observation?.cloud ?? [],
                               unavailableJoints: Set(JointID.allCases).subtracting(joints.keys))
    DispatchQueue.main.async { [weak self] in
      self?.onSample?(sample)
    }
  }

  // MARK: - Depth

  /// 深度帧：每个都更新点云，样本按 10 Hz 发。
  private func handleDepth(_ depthData: AVDepthData, at t: TimeInterval) {
    let processingStartedAt = ProcessInfo.processInfo.systemUptime
    // Float32 是这条管线唯一能读的格式，转换是深度到深度。
    let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    guard let image = Self.depthImage(from: converted.depthDataMap)?
      .resampled(maxWidth: Self.processingWidth)
    else { return }

    let mask = DepthSegmentation.segment(image)
    let cloud = mask.map { DepthCloud.points(mask: $0, image: image) } ?? []
    let head = HeadGeometry.measure(depth: image, mask: mask)
    let observation = DepthObservation(t: t, image: image, mask: mask, cloud: cloud, head: head)
    lastDepthProcessing = ProcessInfo.processInfo.systemUptime - processingStartedAt

    stateLock.lock()
    history.append(observation)
    if history.count > Self.depthHistoryCount { history.removeFirst(history.count - Self.depthHistoryCount) }
    stateLock.unlock()

    // 30 Hz 点云：每个深度帧都推给画布，不等样本节流。
    DispatchQueue.main.async { [weak self] in
      self?.onCloud?(CloudFrame(t: t, points: cloud))
    }

    guard t - lastEmittedAt >= Self.sampleInterval else { return }
    lastEmittedAt = t
    emit(observation, at: t)
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

extension DepthCaptureSource: AVCaptureDepthDataOutputDelegate {
  func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                       didOutput depthData: AVDepthData,
                       timestamp: CMTime,
                       connection: AVCaptureConnection) {
    guard let startedAt else { return }
    handleDepth(depthData, at: ProcessInfo.processInfo.systemUptime - startedAt)
  }
}

extension DepthCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
  /// 彩色帧的完整生命周期就在这两个调用之间：取缓冲、推理、丢掉引用。
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let startedAt else { return }
    let t = ProcessInfo.processInfo.systemUptime - startedAt
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    guard let frame = vision.joints(in: buffer, at: t) else { return }

    // 关节的位置来自彩色，距离与俯仰来自同帧深度：配最近的一帧，超过 150 ms 就整帧作废。
    var joints: [JointID: JointSample] = [:]
    if let observation = nearestObservation(to: frame.t),
       !VisionDepthPairing.isStale(visionT: frame.t, sampleT: observation.t) {
      joints = VisionPoseMapping.attachDepth(frame.joints,
                                             depth: observation.image,
                                             mask: observation.mask)
    }

    let paired = VisionJointFrame(t: frame.t,
                                  joints: joints,
                                  shouldersInvalidated: frame.shouldersInvalidated,
                                  inferenceSeconds: frame.inferenceSeconds)
    stateLock.lock()
    latestJoints = paired
    stateLock.unlock()
  }
}
