import Foundation
import ARKit
import AVFoundation

/// Head-down has to lower this value, and which sign does that is only confirmable
/// by calibrating on a real device (AC10).
private let pitchSign: Double = -1

private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

/// Real-device input: front TrueDepth face tracking, converted to distance and pitch.
final class ARFaceSampleSource: NSObject, SampleSource {
  var onSample: ((PostureSample) -> Void)?

  private let session: ARSession
  private var startedAt: TimeInterval?

  /// `session` is shared with the child's screen, which previews it: one camera, one preview and
  /// one sample stream, so what the child sees is what the classifier reads.
  init(session: ARSession = ARSession()) {
    self.session = session
    super.init()
    session.delegate = self
  }

  func start() {
    guard ARFaceTrackingConfiguration.isSupported else {
      reportAbsent()
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      runSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.runSession()
          } else {
            self.reportAbsent()
          }
        }
      }
    default:
      reportAbsent()
    }
  }

  func stop() {
    session.pause()
  }

  private func runSession() {
    startedAt = ProcessInfo.processInfo.systemUptime
    session.run(ARFaceTrackingConfiguration(), options: [])
  }

  /// With no session there are no samples at all, which would leave the screen on the
  /// engine's initial `.good`; one absent frame parks it at `.absent`.
  private func reportAbsent() {
    emit(PostureSample(t: elapsedTime(), distanceCM: nil, pitchDeg: nil))
  }

  private func emit(_ sample: PostureSample) {
    // ARSessionDelegate callbacks arrive off the main thread.
    DispatchQueue.main.async { [weak self] in
      self?.onSample?(sample)
    }
  }

  private func elapsedTime() -> TimeInterval {
    guard let startedAt else { return 0 }
    return ProcessInfo.processInfo.systemUptime - startedAt
  }
}

extension ARFaceSampleSource: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
      emit(PostureSample(t: elapsedTime(), distanceCM: nil, pitchDeg: nil))
      return
    }

    let m = face.transform
    let translation = m.columns.3
    let distanceCM = 100 * Double(simd_length(SIMD3<Float>(translation.x, translation.y, translation.z)))
    let pitchDeg = pitchSign * degrees(Double(atan2(m.columns.1.z, m.columns.1.y)))
    emit(PostureSample(t: elapsedTime(), distanceCM: distanceCM, pitchDeg: pitchDeg))
  }
}
