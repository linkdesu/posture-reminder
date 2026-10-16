import SwiftUI
import ARKit
import AVFoundation

@main struct PostureLabApp: App {
  var body: some Scene { WindowGroup { ContentView() } }
}

final class FaceModel: NSObject, ObservableObject, ARSessionDelegate {
  @Published var status = "请求相机权限…"
  @Published var distanceCM: Double?
  let session = ARSession()
  func start() {
    AVCaptureDevice.requestAccess(for: .video) { ok in
      DispatchQueue.main.async {
        guard ok else { self.status = "相机权限被拒绝"; return }
        guard ARFaceTrackingConfiguration.isSupported else { self.status = "本机不支持人脸追踪"; return }
        self.session.delegate = self
        self.session.run(ARFaceTrackingConfiguration())
        self.status = "人脸追踪中"
      }
    }
  }
  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard let f = anchors.compactMap({ $0 as? ARFaceAnchor }).first, f.isTracked else { return }
    let t = f.transform.columns.3
    let d = Double(simd_length(SIMD3<Float>(t.x, t.y, t.z))) * 100
    let depth = session.currentFrame?.capturedDepthData != nil
    DispatchQueue.main.async { self.distanceCM = d; self.status = depth ? "人脸追踪中（有深度数据）" : "人脸追踪中（无深度数据）" }
  }
}

struct ContentView: View {
  @StateObject var m = FaceModel()
  var body: some View {
    VStack(spacing: 16) {
      Text("PostureLab").font(.largeTitle)
      Text(m.status)
      if let d = m.distanceCM { Text(String(format: "脸到屏幕：%.1f cm", d)).font(.title).monospacedDigit() }
    }.onAppear { m.start() }
  }
}
