import Foundation

/// 归一化图像坐标 + 深度 → 相机坐标系里的米制点。
///
/// TrueDepth 不向应用交出深度图的内参：`AVDepthData.cameraCalibrationData` 是彩色相机那一侧
/// 的标定，而本构建不读彩色通路。所以这里用一条写在明处的假设——前置深度视场水平 60°、竖持
/// 画幅 3:4——把归一化坐标换成米。两肩的三维距离、肩宽与头宽的比值约束都按这条假设换算；它在
/// 20–45 cm 的判定窗口里够用，但它是估计值，不是标定值。
///
/// 纯函数、无状态：同一个关节永远换算出同一个米制点。
struct DepthCamera: Equatable {
  /// 前置深度相机的水平视场，度。
  var horizontalFOVDegrees: Double
  /// 竖持画幅的宽高比（宽 / 高）。
  var widthToHeight: Double

  init(horizontalFOVDegrees: Double = 60, widthToHeight: Double = Double(DepthFrame.width) / Double(DepthFrame.height)) {
    self.horizontalFOVDegrees = horizontalFOVDegrees
    self.widthToHeight = widthToHeight
  }

  /// 归一化 x 从画面中心到边缘对应的米制宽度，除以深度：
  /// `X = (x - 0.5) · horizontalScale · z`。y 按像素等比，所以纵向系数多除以宽高比。
  var horizontalScale: Double {
    2 * tan(horizontalFOVDegrees * .pi / 360)
  }

  /// 相机坐标系里的点，米。z 就是深度，正值离开相机。
  func metric(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double) {
    ((x - 0.5) * horizontalScale * z,
     (y - 0.5) * horizontalScale / widthToHeight * z,
     z)
  }

  /// 两个带深度的关节之间的三维距离，米；任一点没有深度就没有答案。
  func distance(_ a: JointSample, _ b: JointSample) -> Double? {
    guard let aDepth = a.depthM, let bDepth = b.depthM else { return nil }
    let p = metric(x: a.x, y: a.y, z: aDepth)
    let q = metric(x: b.x, y: b.y, z: bDepth)
    let dx = p.x - q.x
    let dy = p.y - q.y
    let dz = p.z - q.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
  }
}
