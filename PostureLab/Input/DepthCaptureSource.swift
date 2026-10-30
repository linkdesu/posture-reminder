import AVFoundation
import Accelerate
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
  /// 横滚校准有结论时回调一次：拿到基线给数值，样本不足给 nil。
  var onRollCalibration: ((Double?) -> Void)?

  private let vision = VisionJointSource()
  /// 固定网格 + 帧间平滑的点云。只有深度队列碰它。
  private var cloudStabilizer = CloudStabilizer()
  /// 横滚基线的静默校准（前 3 秒的 Vision 眼线/耳线中位数）。
  private var rollCalibrator = RollCalibrator()
  /// 在场判定的连续帧计数：头部（鼻）置信度过门槛、且同时有人脸（鼻）或双眼，连续
  /// `presenceStreakRequired` 帧才算在场；任何一帧不满足就归零。0.6.8 (17)：Vision 在近距离会整帧
  /// 不给 observation，单帧丢失不再直接当作「人不在」。
  private var presenceStreak = 0
  private static let presenceStreakRequired = 3
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

  /// 当前采集负载。热状态到 `serious` 时降到 Vision 5 Hz、点云 15 Hz（`CaptureLoad`）。
  private var load: CaptureLoad = .normal
  private var lastCloudAt: TimeInterval = 0
  /// 上一帧深度的呈现时刻与回调到达时刻，用来在逐帧日志里写分阶段间隔。
  private var lastDepthFrameTime: TimeInterval?
  private var lastDepthArrival: TimeInterval?

  private var startedAt: TimeInterval?
  private var lastEmittedAt: TimeInterval = 0
  private var watchdog: DispatchSourceTimer?
  private var isConfigured = false

  /// 一个深度帧的耗时（毫秒），只给性能埋点读。
  private(set) var lastDepthProcessing: TimeInterval = 0

  override init() {
    super.init()
    depthOutput.setDelegate(self, callbackQueue: depthQueue)
    // 深度滤波必须开着。0.6.8 (15) 的真机排查：关掉滤波后 TrueDepth 交出的 Float32 深度图整帧都是
    // NaN（`depth_valid` 0、`depth_nan` 1、最近读数 null），分割因此拿不到任何输入、点云恒为 0 点，
    // 而同一帧的彩色 Vision 还能看到人的五官。开着滤波时帧在 30 Hz 上稳定（逐帧日志实测间隔 33 ms），
    // 所以「关滤波省时间」这个假设是错的：省下的几毫秒买不到一张能用的深度图。
    depthOutput.isFilteringEnabled = true
    depthOutput.alwaysDiscardsLateDepthData = true
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true
    vision.minimumInterval = load.visionInterval
  }

  /// 热状态采样器的降级开关。Vision 的节流在 `VisionJointSource` 上，点云的节流在这里；深度帧本身
  /// 仍按传感器给的频率进来，只是降级时有一半点云不推给画布。
  func setLoad(_ load: CaptureLoad) {
    stateLock.lock()
    self.load = load
    stateLock.unlock()
    vision.minimumInterval = load.visionInterval
  }

  private var currentLoad: CaptureLoad {
    stateLock.lock()
    defer { stateLock.unlock() }
    return load
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
    cloudStabilizer.reset()
    #if DEBUG
    // 最后一帧可能还没上屏：写出去，别让它挂在内存里消失。
    FrameLog.shared.flushPending()
    #endif
    depthQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  // MARK: - Session

  private func run() {
    let start = ProcessInfo.processInfo.systemUptime
    startedAt = start
    lastEmittedAt = 0
    lastCloudAt = 0
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
    pinFrameRate(device)
    return true
  }

  /// 把深度与彩色的输出都钉到 30 fps。
  ///
  /// 默认的 `activeDepthDataMinFrameDuration` 会跟着预览预设走，真机上实测只有约 25 Hz；点云
  /// 的流畅门槛（未降级时 p95 ≤ 40 ms）就是按 30 Hz 的帧间隔定的，所以这里显式要求 30 fps。
  /// 设备不支持时保留默认值，不失败。
  private func pinFrameRate(_ device: AVCaptureDevice) {
    guard (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }
    let thirty = CMTime(value: 1, timescale: 30)
    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 }) {
      device.activeVideoMinFrameDuration = thirty
      device.activeVideoMaxFrameDuration = thirty
    }
    if device.activeDepthDataFormat != nil,
       device.activeDepthDataFormat?.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 }) == true {
      device.activeDepthDataMinFrameDuration = thirty
    }
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

  /// 这一帧 Vision 是否给出了「有一个人」的可靠证据：头部（鼻）置信度过门槛，并且鼻或双眼在。
  /// 只靠 `detected` 会把「模型报了人但所有关节都被门槛滤掉」也算在场；只靠鼻子又会在侧脸时抖。
  static func headEvidence(_ joints: [JointID: JointSample]) -> Bool {
    guard joints[.nose] != nil else { return false }
    return joints[.nose] != nil || (joints[.leftEye] != nil && joints[.rightEye] != nil)
  }

  /// 这一时刻的在场结论：Vision 最近一帧没有过期、且连续 `presenceStreakRequired` 帧都有头部证据。
  /// 过期时不下结论（nil，由样本的距离回退）。
  private func mouth(at t: TimeInterval) -> [CGPointLike] {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let frame = latestJoints,
          !VisionDepthPairing.isStale(visionT: frame.t, sampleT: t) else { return [] }
    return frame.mouth
  }

  private func personPresent(at t: TimeInterval) -> Bool? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let frame = latestJoints,
          !VisionDepthPairing.isStale(visionT: frame.t, sampleT: t) else { return nil }
    return presenceStreak >= Self.presenceStreakRequired
  }

  /// 这一时刻还能用的关节：最近一次配对结果没有过期，且双肩没有因为落在头上被作废。
  /// 横滚：优先用 Vision 的眼线/耳线，并按校准基线取相对角；两者都缺时才退回深度平面。
  private func calibratedRoll(joints: [JointID: JointSample],
                              fallback: Double?,
                              at t: TimeInterval) -> Double? {
    guard let visionRoll = VisionPoseMapping.eyeLineDegrees(joints)
      ?? VisionPoseMapping.earLineDegrees(joints) else { return fallback }
    let wasSettled = rollCalibrator.isSettled
    _ = rollCalibrator.observe(visionRoll, at: t)
    if !wasSettled, rollCalibrator.isSettled {
      let baseline = rollCalibrator.baseline
      DispatchQueue.main.async { [weak self] in self?.onRollCalibration?(baseline) }
    }
    return rollCalibrator.relative(visionRoll)
  }

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
                               // 眼线 → 耳线 → 深度平面；彩色给的横滚比深度平面准，并且减掉这个孩子
                               // 自己的横滚基线（前 3 秒中位数）。深度兜底不参与校准。
                               rollDeg: calibratedRoll(joints: joints, fallback: head.rollDeg, at: t),
                               joints: joints,
                               depth: observation?.mask == nil ? nil : observation?.image.downsampled(),
                               depthAvailable: observation?.mask != nil,
                               cloud: observation?.cloud ?? [],
                               unavailableJoints: Set(JointID.allCases).subtracting(joints.keys),
                               personPresent: personPresent(at: t),
                               mouth: mouth(at: t))
    DispatchQueue.main.async { [weak self] in
      self?.onSample?(sample)
    }
  }

  // MARK: - Depth

  /// 深度帧：每个都更新点云（降级时一半），样本按 10 Hz 发。
  private func handleDepth(_ depthData: AVDepthData, at t: TimeInterval, frameTime: TimeInterval) {
    let arrivalUptime = ProcessInfo.processInfo.systemUptime
    let captureStartedAt = arrivalUptime
    // Float32 是这条管线唯一能读的格式，转换是深度到深度。
    let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    // 一次缩放到处理宽度，省掉「先整帧拷进 Swift 数组、再缩放」的那一遍：640×480 的逐像素
    // 拷贝在 Debug 构建里就要 40 ms，正好把 30 Hz 拖成 15 Hz（0.6.8 真机实测）。
    guard let image = Self.depthImage(from: converted.depthDataMap,
                                      maxWidth: Self.processingWidth)
    else { return }
    let captureSeconds = ProcessInfo.processInfo.systemUptime - captureStartedAt

    let segmentationStartedAt = ProcessInfo.processInfo.systemUptime
    let mask = DepthSegmentation.segment(image)
    let segmentationSeconds = ProcessInfo.processInfo.systemUptime - segmentationStartedAt

    let cloudStartedAt = ProcessInfo.processInfo.systemUptime
    // 固定网格采样 + 距离平滑：位置不随遮罩变化，帧与帧之间按槽位配对（见 `CloudStabilizer`）。
    let cloud = cloudStabilizer.points(mask: mask, image: image, at: frameTime)
    let cloudSeconds = ProcessInfo.processInfo.systemUptime - cloudStartedAt

    let depthGap = lastDepthFrameTime.map { max(0, (frameTime - $0) * 1000) } ?? 0
    let arrivalGap = lastDepthArrival.map { max(0, (t - $0) * 1000) } ?? 0
    lastDepthFrameTime = frameTime
    lastDepthArrival = t

    let head = HeadGeometry.measure(depth: image, mask: mask)
    let observation = DepthObservation(t: t, image: image, mask: mask, cloud: cloud, head: head)

    lastDepthProcessing = captureSeconds + segmentationSeconds + cloudSeconds

    #if DEBUG
    // 分步耗时（每秒汇总）与逐帧原始记录各一份：汇总只给趋势，逐帧记录才是 QA 判证据的来源。
    PerfMonitor.shared.recordCapture(seconds: captureSeconds)
    PerfMonitor.shared.recordSegment(seconds: segmentationSeconds)
    PerfMonitor.shared.recordCloud(seconds: cloudSeconds, points: cloud.count)
    #endif

    stateLock.lock()
    history.append(observation)
    if history.count > Self.depthHistoryCount { history.removeFirst(history.count - Self.depthHistoryCount) }
    let cloudInterval = load.cloudInterval
    let cloudCap = load.cloudHz
    stateLock.unlock()

    // 点云推给画布：正常负载下**每个深度帧都推**（ADR-0008 第 4 条，不做 30 Hz 的二次节流——
    // 30 Hz 的节流按固定间隔卡帧，会把 33 ms 的正常间隔偶尔拖成 67 ms，反而破坏流畅）；降级时
    // 才按 15 Hz 的上限隔一帧推一次。间隔用深度帧自己的呈现时刻量，回调晚到不算掉帧。
    let shouldEmitCloud = cloudCap >= CaptureLoad.normal.cloudHz || frameTime - lastCloudAt >= cloudInterval * 0.85

    #if DEBUG
    // 逐帧原始记录：这一帧深度有没有读数、分割出多少格、点云多少点、上屏没有、上屏多久。
    stateLock.lock()
    let visionInfo = latestJoints
    stateLock.unlock()
    FrameLog.shared.begin(FrameLog.Record(
      ts: Int((Date().timeIntervalSince1970 * 1000).rounded()),
      frameS: frameTime,
      arrivalS: t,
      depthMS: captureSeconds * 1000,
      segmentMS: segmentationSeconds * 1000,
      cloudMS: cloudSeconds * 1000,
      points: cloud.count,
      maskCells: mask?.count ?? 0,
      depthValid: image.validFraction,
      depthNaN: image.nanFraction,
      nearestM: image.nearestDepth().map { Double($0) },
      degraded: cloudCap < CaptureLoad.normal.cloudHz,
      cloudEmitted: shouldEmitCloud,
      depthGapMS: depthGap,
      arrivalGapMS: arrivalGap,
      visionMS: visionInfo.map { $0.inferenceSeconds * 1000 },
      // 两个时刻都取会话时钟（`t` 与 Vision 的 `t`）；用 CMTime 的 frameTime 去减会得到上亿毫秒。
      visionAgeMS: visionInfo.map { max(0, (t - $0.t) * 1000) }),
      arrivalUptime: arrivalUptime)
    #endif

    if shouldEmitCloud {
      lastCloudAt = frameTime
      #if DEBUG
      PerfMonitor.shared.recordCloudFrame(at: frameTime)
      #endif
      DispatchQueue.main.async { [weak self] in
        self?.onCloud?(CloudFrame(t: t, points: cloud))
      }
    }

    guard t - lastEmittedAt >= Self.sampleInterval else { return }
    lastEmittedAt = t
    emit(observation, at: t)
  }

  /// Reads the depth plane straight into the processing grid, then drops the pixel buffer.
  ///
  /// vImage 直接从像素缓冲的基地址缩放到目标宽度（`kvImageNoFlags` 的线性插值，与
  /// `DepthImage.resampled` 同一条路径），所以整帧 640×480 的逐像素拷贝不再发生——那些拷贝在
  /// Debug 构建里就是 40 ms，把 30 Hz 的深度流拖成 15 Hz。不足目标宽度的帧直接拷这一片。
  /// 一次性读完、读完即解锁：没有第二遍读取，也没有第二块缓冲被保留。
  private static func depthImage(from map: CVPixelBuffer, maxWidth: Int) -> DepthImage? {
    let width = CVPixelBufferGetWidth(map)
    let height = CVPixelBufferGetHeight(map)
    guard width > 0, height > 0 else { return nil }

    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
    let targetWidth = min(width, max(1, maxWidth))
    let targetHeight = max(1, Int((Double(height) * Double(targetWidth) / Double(width)).rounded()))
    var metres = [Float](repeating: 0, count: targetWidth * targetHeight)

    let scaled = metres.withUnsafeMutableBufferPointer { destination -> Bool in
      guard let destinationBase = destination.baseAddress else { return false }
      var input = vImage_Buffer(data: base,
                                height: vImagePixelCount(height),
                                width: vImagePixelCount(width),
                                rowBytes: bytesPerRow)
      var output = vImage_Buffer(data: destinationBase,
                                 height: vImagePixelCount(targetHeight),
                                 width: vImagePixelCount(targetWidth),
                                 rowBytes: targetWidth * MemoryLayout<Float>.stride)
      return vImageScale_PlanarF(&input, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
    guard scaled else { return nil }
    return DepthImage(width: targetWidth, height: targetHeight, metres: metres)
  }
}

extension DepthCaptureSource: AVCaptureDepthDataOutputDelegate {
  func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                       didOutput depthData: AVDepthData,
                       timestamp: CMTime,
                       connection: AVCaptureConnection) {
    guard let startedAt else { return }
    handleDepth(depthData,
                at: ProcessInfo.processInfo.systemUptime - startedAt,
                frameTime: CMTimeGetSeconds(timestamp))
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
    var stale = true

    if let observation = nearestObservation(to: frame.t),
       !VisionDepthPairing.isStale(visionT: frame.t, sampleT: observation.t) {
      stale = false
      joints = VisionPoseMapping.attachDepth(frame.joints,
                                             depth: observation.image,
                                             mask: observation.mask)
    }

    let paired = VisionJointFrame(t: frame.t,
                                  joints: joints,
                                  detected: frame.detected,
                                  rawConfidence: frame.rawConfidence,
                                  shouldersInvalidated: frame.shouldersInvalidated,
                                  inferenceSeconds: frame.inferenceSeconds)
    stateLock.lock()
    latestJoints = paired
    if Self.headEvidence(paired.joints) {
      presenceStreak = min(Self.presenceStreakRequired, presenceStreak + 1)
    } else {
      presenceStreak = 0
    }
    stateLock.unlock()

    #if DEBUG
    PerfMonitor.shared.recordVision(seconds: frame.inferenceSeconds)
    var confidence: [String: Double] = [:]
    var visible: [String: Bool] = [:]
    for joint in VisionPoseMapping.deliveredJoints {
      let sample = joints[joint]
      confidence[joint.rawValue] = sample?.confidence
      visible[joint.rawValue] = sample != nil
    }
    // Vision 肩线：采集侧已经配对好的肩点，与遮罩肩线并排写进日志供对比（不做判定）。
    let visionShoulders = ShoulderLine.make(left: joints[.leftShoulder],
                                            right: joints[.rightShoulder],
                                            nose: joints[.nose])
    JointFrameLog.shared.write(JointFrameDebugSample(sessionT: frame.t,
                                                     detected: frame.detected,
                                                     stale: stale,
                                                     shouldersInvalidated: frame.shouldersInvalidated,
                                                     confidence: confidence,
                                                     rawConfidence: frame.rawConfidence,
                                                     visible: visible,
                                                     visionShoulders: visionShoulders))
    #endif
  }
}
