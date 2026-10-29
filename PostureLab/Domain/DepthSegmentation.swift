import Foundation

/// The pixels a depth frame says belong to one body, plus the box they occupy.
///
/// `cells` is a row-major bitmap in the frame's own grid. The mask is what the point cloud is built
/// from and what the joint estimator measures, so every point on the child's screen traces back to
/// a depth cell that passed the segmentation.
struct BodyMask: Equatable {
  let width: Int
  let height: Int
  /// Row major, `count == width * height`.
  let cells: [Bool]
  let minX: Int
  let minY: Int
  let maxX: Int
  let maxY: Int
  let count: Int

  func contains(x: Int, y: Int) -> Bool {
    guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
    return cells[y * width + x]
  }

  /// The horizontal extent of the mask on one row, or nil when that row has no body pixel.
  func rowExtent(y: Int) -> (minX: Int, maxX: Int)? {
    guard (0..<height).contains(y) else { return nil }
    var first = -1
    var last = -1
    for x in 0..<width where cells[y * width + x] {
      if first < 0 { first = x }
      last = x
    }
    guard first >= 0 else { return nil }
    return (first, last)
  }

  /// Normalized (0...1, y downwards) position of a pixel's centre.
  func normalized(x: Int, y: Int) -> CGPointLike {
    CGPointLike(x: (Double(x) + 0.5) / Double(width),
                y: (Double(y) + 0.5) / Double(height))
  }

  var boundingBox: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
    (minX, minY, maxX, maxY)
  }
}

/// A plain pair, so the domain layer keeps no dependency on CoreGraphics or SwiftUI.
struct CGPointLike: Equatable {
  var x: Double
  var y: Double
}

/// Splits a depth frame into "the person" and "everything else" without reading a single colour
/// byte.
///
/// The rule is the one a depth camera makes natural: the child is the nearest thing in an otherwise
/// farther room, so the segmentation starts from the nearest valid reading, keeps every pixel within
/// `depthSpan` of it, and then keeps the largest four-connected component of those pixels. A chair
/// back that happens to fall in the window is a separate component and is dropped; a desk that sits
/// behind the child is outside the span and never enters the mask.
enum DepthSegmentation {
  struct Options: Equatable {
    /// How far behind the nearest reading the body may reach. Deep enough for a lean over a desk,
    /// shallow enough to leave the wall behind a seated child out.
    var depthSpan: Double = 0.75
    /// A reading must come at least this far in front of the background to be the person.
    var minimumStandout: Double = 0.10
    /// Masks smaller than this share of the frame are noise, not a body.
    var minimumAreaFraction: Double = 0.01
    /// Component whose box is narrower or shorter than these fractions of the frame is dropped.
    var minimumWidthFraction: Double = 0.05
    var minimumHeightFraction: Double = 0.10
    /// The nearest reading is taken after dropping this share of the closest samples. Zero by
    /// default: a tilted head can genuinely put a large patch of pixels closer than the rest of the
    /// body, and cutting that patch off would disconnect the head from the torso. Isolated noise is
    /// handled by the component filter instead.
    var nearestIgnoreFraction: Double = 0

    init() {}
  }

  /// The largest plausible body component, or nil when the frame has nobody in it.
  static func segment(_ image: DepthImage, options: Options = Options()) -> BodyMask? {
    // 一次直方图同时给出「最近读数」与「背景 75 分位」：每帧只扫一遍像素，不排序七万个读数。
    let histogram = image.depthHistogram()
    let validCount = histogram.reduce(0, +)
    guard validCount > 0,
          let nearest = DepthImage.percentile(histogram,
                                              total: validCount,
                                              fraction: options.nearestIgnoreFraction),
          let background = DepthImage.percentile(histogram, total: validCount, fraction: 0.75)
    else { return nil }
    // A flat wall fills the frame with one distance; without a near object standing out of it there
    // is nobody in the picture, and thresholding a wall would manufacture a body out of sensor noise.
    guard Double(nearest) < Double(background) - options.minimumStandout else { return nil }

    let near = Double(nearest) - 0.02
    let far = Double(nearest) + options.depthSpan

    var candidates = [Bool](repeating: false, count: image.width * image.height)
    let metres = image.metres
    for index in 0..<candidates.count {
      let reading = Double(metres[index])
      candidates[index] = reading > 0.05 && reading < 5 && reading >= near && reading <= far
    }

    // The background filter alone is not enough: a hand at the same distance is a separate
    // component. Keep the largest one.
    var visited = [Bool](repeating: false, count: candidates.count)
    var stack: [Int] = []
    stack.reserveCapacity(256)

    // 第一遍只数每个连通块的大小并记下它的起点，不复制整张位图：0.6.1 每遇到一个连通块就分配一个
    // 全尺寸数组，Debug 构建下这是关节推算里最贵的一段。
    var bestStart = -1
    var bestCount = 0
    for start in 0..<candidates.count where candidates[start] && !visited[start] {
      var count = 0
      var componentMinX = image.width
      var componentMinY = image.height
      var componentMaxX = -1
      var componentMaxY = -1
      stack.removeAll(keepingCapacity: true)
      stack.append(start)
      visited[start] = true
      while let index = stack.popLast() {
        count += 1
        let x = index % image.width
        let y = index / image.width
        componentMinX = min(componentMinX, x)
        componentMinY = min(componentMinY, y)
        componentMaxX = max(componentMaxX, x)
        componentMaxY = max(componentMaxY, y)
        // 4-connected: a body is one surface, and diagonal jumps across the background gap that
        // separates an arm from a chair would merge the two.
        if x > 0, candidates[index - 1], !visited[index - 1] {
          visited[index - 1] = true
          stack.append(index - 1)
        }
        if x + 1 < image.width, candidates[index + 1], !visited[index + 1] {
          visited[index + 1] = true
          stack.append(index + 1)
        }
        if y > 0, candidates[index - image.width], !visited[index - image.width] {
          visited[index - image.width] = true
          stack.append(index - image.width)
        }
        if y + 1 < image.height, candidates[index + image.width], !visited[index + image.width] {
          visited[index + image.width] = true
          stack.append(index + image.width)
        }
      }
      guard count > 0 else { continue }
      guard Double(count) >= options.minimumAreaFraction * Double(candidates.count) else { continue }
      guard Double(componentMaxX - componentMinX + 1) >= options.minimumWidthFraction * Double(image.width),
            Double(componentMaxY - componentMinY + 1) >= options.minimumHeightFraction * Double(image.height)
      else { continue }
      if count > bestCount {
        bestCount = count
        bestStart = start
      }
    }

    guard bestStart >= 0 else { return nil }
    // 第二遍只把赢家标出来，顺便拿到包围盒；`cells` 自己就是这一遍的已访问表。
    var cells = [Bool](repeating: false, count: candidates.count)
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    stack.removeAll(keepingCapacity: true)
    stack.append(bestStart)
    cells[bestStart] = true
    while let index = stack.popLast() {
      let x = index % image.width
      let y = index / image.width
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
      if x > 0, candidates[index - 1], !cells[index - 1] {
        cells[index - 1] = true
        stack.append(index - 1)
      }
      if x + 1 < image.width, candidates[index + 1], !cells[index + 1] {
        cells[index + 1] = true
        stack.append(index + 1)
      }
      if y > 0, candidates[index - image.width], !cells[index - image.width] {
        cells[index - image.width] = true
        stack.append(index - image.width)
      }
      if y + 1 < image.height, candidates[index + image.width], !cells[index + image.width] {
        cells[index + image.width] = true
        stack.append(index + image.width)
      }
    }

    guard Double(maxX - minX + 1) >= options.minimumWidthFraction * Double(image.width),
          Double(maxY - minY + 1) >= options.minimumHeightFraction * Double(image.height)
    else { return nil }

    return BodyMask(width: image.width,
                    height: image.height,
                    cells: cells,
                    minX: minX,
                    minY: minY,
                    maxX: maxX,
                    maxY: maxY,
                    count: bestCount)
  }
}
