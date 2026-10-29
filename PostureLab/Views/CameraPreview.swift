import ARKit
import SceneKit
import SwiftUI

/// The camera feed under the child's screen's point cloud.
///
/// It is the same `ARSession` the face source reads, displayed by an `ARSCNView` with an empty scene:
/// ARKit's camera image is the background and no virtual content is added. The view never captures,
/// records or saves a frame — the picture exists on the screen for as long as the screen shows it,
/// and the app has no path that could write it to disk or send it anywhere.
///
/// On a simulator the face-tracking configuration does not run, so the view stays black; the scripted
/// point cloud is the visual there, exactly as the feature docs describe.
struct CameraPreview: UIViewRepresentable {
  let session: ARSession

  func makeUIView(context: Context) -> ARSCNView {
    let view = ARSCNView(frame: .zero)
    view.session = session
    view.scene = SCNScene()
    view.backgroundColor = .black
    view.automaticallyUpdatesLighting = false
    view.isUserInteractionEnabled = false
    view.antialiasingMode = .none
    return view
  }

  func updateUIView(_ view: ARSCNView, context: Context) {
    if view.session !== session { view.session = session }
  }
}
