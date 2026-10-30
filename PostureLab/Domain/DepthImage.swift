import Accelerate
import Foundation

/// One TrueDepth frame, already rotated into the display's portrait orientation.
///
/// `metres` is row major and every cell holds the distance to the camera; `0` means the sensor had
/// no reading there (the depth map's own invalid value). Nothing in this type knows about colour:
/// the buffer it comes from has exactly one plane.
struct DepthImage: Equatable {
  let width: Int
  let height: Int
  /// Row major, `count == width * height`.
  let metres: [Float]

  init?(width: Int, height: Int, metres: [Float]) {
    guard width > 0, height > 0, metres.count == width * height else { return nil }
    self.width = width
    self.height = height
    self.metres = metres
  }

  /// A frame of one constant distance. Only tests use it; a real frame always varies.
  static func plane(width: Int, height: Int, metres: Float) -> DepthImage? {
    DepthImage(width: width, height: height, metres: [Float](repeating: metres, count: width * height))
  }

  /// 0 both for a cell outside the image and for a cell without a reading.
  func value(x: Int, y: Int) -> Float {
    guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
    return metres[y * width + x]
  }

  /// Whether a cell holds a distance the pipeline can use. Zero is TrueDepth's "no reading"; a
  /// distance past five metres is not a child at a desk and is treated the same way.
  func isValid(x: Int, y: Int) -> Bool {
    let value = value(x: x, y: y)
    return value > 0.05 && value < 5
  }

  /// 有效读数占整帧的比例（0...1）。
  ///
  /// 它把两种「没有点云」分开：传感器这一帧真的没有读数（≈0）与传感器正常、只是画面里没有比背景
  /// 近的人（≈1 但分割失败）。逐帧日志靠它自证深度流在工作。
  var validFraction: Double {
    guard !metres.isEmpty else { return 0 }
    var valid = 0
    for value in metres where value > 0.05 && value < 5 { valid += 1 }
    return Double(valid) / Double(metres.count)
  }

  /// The median of a rect's valid readings, or nil when the rect has none.
  func median(in rect: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> Float? {
    let minX = max(0, rect.minX)
    let minY = max(0, rect.minY)
    let maxX = min(width - 1, rect.maxX)
    let maxY = min(height - 1, rect.maxY)
    guard minX <= maxX, minY <= maxY else { return nil }
    var values = [Float](repeating: 0, count: (maxX - minX + 1) * (maxY - minY + 1))
    var count = 0
    for y in minY...maxY {
      for x in minX...maxX where isValid(x: x, y: y) {
        values[count] = value(x: x, y: y)
        count += 1
      }
    }
    guard count > 0 else { return nil }
    if count > 1 { values[0..<count].sort() }
    let middle = count / 2
    if count % 2 == 0 {
      return (values[middle - 1] + values[middle]) / 2
    }
    return values[middle]
  }

  /// The nearest valid reading, ignoring the closest `ignoreFraction` of samples so a single stray
  /// pixel cannot decide where the body starts. Read off the depth histogram: 1 cm is well inside
  /// the 2 cm margin the segmentation uses, and it costs one pass over the pixels instead of a sort
  /// of seventy thousand readings on every frame.
  func nearestDepth(ignoreFraction: Double = 0.02) -> Float? {
    let bins = depthHistogram()
    return Self.percentile(bins, total: bins.reduce(0, +), fraction: ignoreFraction)
  }

  /// 有效读数的 1 cm 直方图，覆盖 0.05–5 m。一次扫描供最近值与背景分位数共用。
  func depthHistogram() -> [Int] {
    var bins = [Int](repeating: 0, count: Self.histogramBins)
    for value in metres where value > Self.histogramMinimum && value < Self.histogramMaximum {
      let bin = Int((value - Self.histogramMinimum) / Self.histogramBinWidth)
      if bin >= 0, bin < bins.count { bins[bin] += 1 }
    }
    return bins
  }

  /// 直方图里累计计数跨过 `fraction` 的那一格的中心值。
  static func percentile(_ bins: [Int], total: Int, fraction: Double) -> Float? {
    guard total > 0 else { return nil }
    let target = Int(Double(total) * min(1, max(0, fraction)))
    var cumulative = 0
    for (bin, count) in bins.enumerated() {
      cumulative += count
      if cumulative > target {
        return histogramMinimum + (Float(bin) + 0.5) * histogramBinWidth
      }
    }
    return nil
  }

  /// The coarse 24 by 32 grid the log and the classifier's geometry use. Each cell is the median of
  /// a 3 by 3 spread sample of its block, so a cell over the background stays background while a
  /// cell on a shoulder reads the shoulder — and a frame costs 768 small sorts, not 768 arrays.
  func downsampled() -> DepthFrame {
    var cells = [Float](repeating: 0, count: DepthFrame.width * DepthFrame.height)
    var sample = [Float](repeating: 0, count: 9)
    for cellY in 0..<DepthFrame.height {
      let minY = cellY * height / DepthFrame.height
      let maxY = max(minY, (cellY + 1) * height / DepthFrame.height - 1)
      for cellX in 0..<DepthFrame.width {
        let minX = cellX * width / DepthFrame.width
        let maxX = max(minX, (cellX + 1) * width / DepthFrame.width - 1)
        cells[cellY * DepthFrame.width + cellX] =
          spreadMedian(minX: minX, minY: minY, maxX: maxX, maxY: maxY, buffer: &sample) ?? 0
      }
    }
    return DepthFrame(metres: cells)
  }

  /// A smaller frame for the CPU-bound segmentation pass.
  ///
  /// The scaler is vImage: this is the one step that touches every pixel of a 640×480 frame, and a
  /// hand-written block median cost 158 ms per frame in a Debug build on an iPhone 13 — more than
  /// the whole rest of the pipeline. Linear interpolation of the depth plane keeps the silhouette
  /// (a boundary pixel blended toward the invalid 0 falls outside the segmentation window, so it
  /// cannot invent body), and it costs a couple of milliseconds.
  func resampled(maxWidth: Int) -> DepthImage {
    guard width > maxWidth, maxWidth > 0 else { return self }
    let targetWidth = maxWidth
    let targetHeight = max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded()))
    var output = [Float](repeating: 0, count: targetWidth * targetHeight)

    let scaled = metres.withUnsafeBufferPointer { source -> Bool in
      output.withUnsafeMutableBufferPointer { destination -> Bool in
        guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else {
          return false
        }
        var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sourceBase),
                                  height: vImagePixelCount(height),
                                  width: vImagePixelCount(width),
                                  rowBytes: width * MemoryLayout<Float>.stride)
        var destinationBuffer = vImage_Buffer(data: destinationBase,
                                              height: vImagePixelCount(targetHeight),
                                              width: vImagePixelCount(targetWidth),
                                              rowBytes: targetWidth * MemoryLayout<Float>.stride)
        return vImageScale_PlanarF(&input, &destinationBuffer, nil,
                                   vImage_Flags(kvImageNoFlags)) == kvImageNoError
      }
    }
    guard scaled else { return self }
    return DepthImage(width: targetWidth, height: targetHeight, metres: output)
      ?? DepthImage(width: 1, height: 1, metres: [0])!
  }

  // MARK: - Block medians

  /// 块内 3×3 均匀取样的中位数：粗网格只服务日志与分类器的几何，不需要整块中位数，而 768 个
  /// 整块中位数（每块约 400 个读数）在 Debug 构建里足够贵。
  private func spreadMedian(minX: Int, minY: Int, maxX: Int, maxY: Int,
                            buffer: inout [Float]) -> Float? {
    var count = 0
    for row in 0..<3 {
      let y = minY + (maxY - minY) * row / 2
      for column in 0..<3 {
        let x = minX + (maxX - minX) * column / 2
        guard isValid(x: x, y: y) else { continue }
        buffer[count] = value(x: x, y: y)
        count += 1
      }
    }
    guard count > 0 else { return nil }
    if count > 1 { buffer[0..<count].sort() }
    return buffer[count / 2]
  }

  private static let histogramBinWidth: Float = 0.01
  private static let histogramMinimum: Float = 0.05
  private static let histogramMaximum: Float = 5
  private static let histogramBins = 495
}
