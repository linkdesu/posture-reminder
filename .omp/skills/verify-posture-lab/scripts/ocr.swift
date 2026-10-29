import AppKit
import Vision

// 读出截图里的文字（Vision OCR），打印每行文字和归一化框。preflight 用它确认没有系统弹窗，
// 也用它确认「OCR」这种取证方法能拿到非空结果。
for path in CommandLine.arguments.dropFirst() {
  guard let image = NSImage(contentsOfFile: path),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("\(path): cannot read image")
    continue
  }
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["zh-Hans", "en-US"]
  request.usesLanguageCorrection = false
  let handler = VNImageRequestHandler(cgImage: cg, options: [:])
  do { try handler.perform([request]) } catch {
    print("\(path): OCR failed: \(error)")
    continue
  }
  print("--- \(path) \(cg.width)x\(cg.height) ---")
  let observations = (request.results ?? []).sorted { a, b in
    let ay = 1 - a.boundingBox.midY, by = 1 - b.boundingBox.midY
    if abs(ay - by) > 0.01 { return ay < by }
    return a.boundingBox.minX < b.boundingBox.minX
  }
  for observation in observations {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let x = Int(box.minX * CGFloat(cg.width))
    let y = Int((1 - box.maxY) * CGFloat(cg.height))
    let w = Int(box.width * CGFloat(cg.width))
    let h = Int(box.height * CGFloat(cg.height))
    print(String(format: "[%4d,%4d %4dx%-4d] %.2f  %@",
                 x, y, w, h, observation.confidence, candidate.string))
  }
}
