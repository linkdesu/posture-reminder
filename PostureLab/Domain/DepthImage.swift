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

  /// Every reading inside `rect`, clamped to the image. Empty when the rect misses the image.
  func values(in rect: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> [Float] {
    let minX = max(0, rect.minX)
    let minY = max(0, rect.minY)
    let maxX = min(width - 1, rect.maxX)
    let maxY = min(height - 1, rect.maxY)
    guard minX <= maxX, minY <= maxY else { return [] }
    var values: [Float] = []
    values.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
    for y in minY...maxY {
      for x in minX...maxX where isValid(x: x, y: y) {
        values.append(value(x: x, y: y))
      }
    }
    return values
  }

  /// The median of a rect's valid readings, or nil when the rect has none.
  func median(in rect: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> Float? {
    let values = values(in: rect).sorted()
    guard !values.isEmpty else { return nil }
    let middle = values.count / 2
    if values.count % 2 == 0 {
      return (values[middle - 1] + values[middle]) / 2
    }
    return values[middle]
  }

  /// The nearest valid reading, ignoring the closest `ignoreFraction` of samples so a single stray
  /// pixel cannot decide where the body starts.
  func nearestDepth(ignoreFraction: Double = 0.02) -> Float? {
    var valid = metres.filter { $0 > 0.05 && $0 < 5 }
    guard !valid.isEmpty else { return nil }
    valid.sort()
    let index = min(valid.count - 1, Int(Double(valid.count) * ignoreFraction))
    return valid[index]
  }

  /// The coarse 24 by 32 grid the avatar's projection, the log and the classifier's geometry use.
  /// Each cell is the median of its block, so a cell over the background stays background while a
  /// cell on a shoulder reads the shoulder.
  func downsampled() -> DepthFrame {
    var cells = [Float](repeating: 0, count: DepthFrame.width * DepthFrame.height)
    for cellY in 0..<DepthFrame.height {
      let minY = cellY * height / DepthFrame.height
      let maxY = max(minY, (cellY + 1) * height / DepthFrame.height - 1)
      for cellX in 0..<DepthFrame.width {
        let minX = cellX * width / DepthFrame.width
        let maxX = max(minX, (cellX + 1) * width / DepthFrame.width - 1)
        cells[cellY * DepthFrame.width + cellX] =
          median(in: (minX: minX, minY: minY, maxX: maxX, maxY: maxY)) ?? 0
      }
    }
    return DepthFrame(metres: cells)
  }

  /// A smaller frame for the CPU-bound segmentation pass, taken by block median. Nearest-neighbour
  /// sampling would punch holes in a thin arm; the median keeps the silhouette intact.
  func resampled(maxWidth: Int) -> DepthImage {
    guard width > maxWidth, maxWidth > 0 else { return self }
    let scale = Double(maxWidth) / Double(width)
    let targetWidth = maxWidth
    let targetHeight = max(1, Int((Double(height) * scale).rounded()))
    var cells = [Float](repeating: 0, count: targetWidth * targetHeight)
    for y in 0..<targetHeight {
      let minY = y * height / targetHeight
      let maxY = max(minY, (y + 1) * height / targetHeight - 1)
      for x in 0..<targetWidth {
        let minX = x * width / targetWidth
        let maxX = max(minX, (x + 1) * width / targetWidth - 1)
        cells[y * targetWidth + x] = median(in: (minX: minX, minY: minY, maxX: maxX, maxY: maxY)) ?? 0
      }
    }
    return DepthImage(width: targetWidth, height: targetHeight, metres: cells)
      ?? DepthImage(width: 1, height: 1, metres: [0])!
  }
}
