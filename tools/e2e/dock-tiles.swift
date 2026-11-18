// Read-only Dock probe for tools/e2e/app_icons.py. No input events, no Dock settings.
//   dock-tiles frames               -> JSON {trusted, scale, tiles: [{title, url, x, y, w, h}]} (points, top-left origin)
//   dock-tiles measure PNG X Y W H  -> JSON plate geometry of one tile in a screen capture (pixel rect)
// Measurement (pixels of the capture): each edge is the first clear colour step from outside (sum |dRGB| between
// neighbours >= 45 % of the window's largest step, or >= 24, then up to its local peak, parabolic sub-pixel fit). The plate's
// top is searched below the Dock's own glass border (18 % of the tile width), its sides on the plate's middle row.
// `corner`: the left edge's inset from the plate's left side, 1 ... 16 px below its top (the corner profile).
// `rim`: the brightest of the rows at the plate's top edge (-1, 0, +1; any sub-pixel phase) minus the plate 3-5 px in (middle 40 % of the top
// edge); `plate` is that inner luminance. macOS draws a light rim on every system-rendered icon; flat art has none.
// A bright plate shows little or no lighter rim (Safari about 0), so callers judge the rim on darker plates only.
import AppKit
import ApplicationServices

func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
let arguments = CommandLine.arguments

if arguments.count == 2 && arguments[1] == "frames" {
  guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("FAIL: the Dock is not running"); exit(1)
  }
  let app = AXUIElementCreateApplication(dock.processIdentifier)
  func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }
  var tiles: [[String: Any]] = []
  for list in (attribute(app, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
    for item in (attribute(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
      var point = CGPoint.zero, size = CGSize.zero
      if let value = attribute(item, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
      if let value = attribute(item, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
      let url = (attribute(item, kAXURLAttribute) as? URL)?.standardizedFileURL.path ?? ""
      tiles.append(["title": (attribute(item, kAXTitleAttribute) as? String) ?? "", "url": url,
                    "x": point.x, "y": point.y, "w": size.width, "h": size.height])
    }
  }
  print(json(["trusted": AXIsProcessTrusted(), "scale": NSScreen.main?.backingScaleFactor ?? 0, "tiles": tiles]))
  exit(0)
}

guard arguments.count == 7, arguments[1] == "measure", let image = NSImage(contentsOfFile: arguments[2]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let x0 = Int(arguments[3]), let y0 = Int(arguments[4]), let w = Int(arguments[5]), let h = Int(arguments[6]) else {
  print("usage: dock-tiles frames | measure PNG X Y W H"); exit(64)
}
// Copy the tile into an RGBA8 buffer in the capture's own colour space (geometry only; no colour conversion).
var pixels = [UInt8](repeating: 0, count: w * h * 4)
pixels.withUnsafeMutableBytes { buffer in
  let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(cg, in: CGRect(x: -x0, y: y0 + h - cg.height, width: cg.width, height: cg.height))
}
typealias RGB = (Double, Double, Double)
func pixel(_ x: Int, _ y: Int) -> RGB {
  let i = (y * w + x) * 4
  return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
}
func luminance(_ p: RGB) -> Double { 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2 }
func step(_ a: RGB, _ b: RGB) -> Double { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }
/// Sub-pixel position of the first clear colour step in `line` (walking from outside in).
func edge(_ line: [RGB], _ window: Int) -> Double {
  let g = (0..<min(window, line.count - 1)).map { step(line[$0], line[$0 + 1]) }
  // A dark plate on the dark Dock steps by about 40 per px, the Dock's backdrop by under 10.
  let big = min(0.45 * (g.max() ?? 0), 24)
  var i = g.firstIndex { $0 >= big } ?? 0
  while i + 1 < g.count && g[i + 1] > g[i] { i += 1 }
  var offset = 0.0
  if i > 0 && i < g.count - 1 {
    let denominator = g[i - 1] - 2 * g[i] + g[i + 1]
    if denominator != 0 { offset = 0.5 * (g[i - 1] - g[i + 1]) / denominator }
  }
  return Double(i) + 0.5 + offset
}
let cx = w / 2
let column = (0..<h).map { pixel(cx, $0) }
let t0 = Int((Double(w) * 0.18).rounded())
let top = Double(t0) + edge(Array(column[t0...]), 24)
// The plate is about 0.75 of the tile wide; search its bottom upward from just below it (above the running dot).
let start = min(h - 1, Int((top + Double(w) * 0.745 + 6).rounded()))
let bottom = Double(start) - edge(Array(column[...start].reversed()), 14)
let cy = Int(((top + bottom) / 2).rounded())
let row = (0..<w).map { pixel($0, cy) }
let left = edge(row, 24)
let right = Double(w) - edge(row.reversed(), 24)
// Pixel row y covers [y - 0.5, y + 0.5] relative to the edge positions above, so interpolate between the two rows
// around top + k: a 0.4 px difference in the plate's top would otherwise move the steep corner by about 1 px.
func inset(_ y: Int) -> Double { edge((0..<w).map { pixel($0, y) }, 30) - left }
let corner = [1.0, 2, 3, 4, 6, 8, 12, 16].map { k -> Double in
  let position = top + k - 0.5, below = Int(position.rounded(.down)), fraction = position - Double(below)
  return ((inset(below) * (1 - fraction) + inset(below + 1) * fraction) * 10).rounded() / 10
}
let t = Int(top + 0.5)
let xs = Int((left + (right - left) * 0.3).rounded())..<Int((left + (right - left) * 0.7).rounded())
func band(_ dy: Int) -> Double { xs.map { luminance(pixel($0, t + dy)) }.reduce(0, +) / Double(xs.count) }
let plate = (band(3) + band(4) + band(5)) / 3
let rim = max(band(-1), band(0), band(1)) - plate
func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
print(json(["width": r1(right - left), "height": r1(bottom - top), "left": r1(left), "top": r1(top),
            "corner": corner, "rim": r1(rim), "plate": r1(plate)]))
