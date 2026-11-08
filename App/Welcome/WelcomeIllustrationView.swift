import AppKit
import QuartzCore

/// Original miniature browser drawings. The render server runs finite keyframes;
/// there is no display link, frame callback, video, image, or repeating animation.
@MainActor
final class WelcomeIllustrationView: NSView {
  private struct Track {
    let layer: CALayer
    let key: String
    let values: [Any]
    let times: [NSNumber]
  }
  let kind: Int
  private let scene = CALayer()
  private var tracks: [Track] = []
  private var panels: [CALayer] = []
  private var textLayers: [(CATextLayer, NSColor)] = []
  private var spacePanel: CALayer?
  private(set) var running = false
  private var dark = false
  var animationCount: Int { tracks.reduce(0) { $0 + ($1.layer.animationKeys()?.count ?? 0) } }

  init(kind: Int) {
    self.kind = kind; super.init(frame: .zero); wantsLayer = true
    scene.anchorPoint = .zero; scene.bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
    layer?.addSublayer(scene); build(); finish()
    setAccessibilityElement(false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    scene.position = .zero
    scene.transform = CATransform3DMakeScale(bounds.width / 320, bounds.height / 200, 1)
    CATransaction.commit()
  }
  private func box(_ rect: CGRect, color: NSColor, radius: CGFloat = 4, parent: CALayer? = nil) -> CALayer {
    let item = CALayer(); item.frame = rect; item.backgroundColor = color.cgColor; item.cornerRadius = radius
    (parent ?? scene).addSublayer(item); return item
  }
  private func text(_ value: String, rect: CGRect, size: CGFloat = 8, color: NSColor = .white, parent: CALayer? = nil) -> CATextLayer {
    let item = CATextLayer(); item.frame = rect; item.string = value
    item.font = NSFont.systemFont(ofSize: size, weight: .medium); item.fontSize = size
    item.foregroundColor = color.cgColor; item.contentsScale = 2; item.alignmentMode = .left
    (parent ?? scene).addSublayer(item); textLayers.append((item, color)); return item
  }
  private func track(_ item: CALayer, _ key: String, _ values: [Any], _ times: [Double]) {
    tracks.append(Track(layer: item, key: key, values: values, times: times.map(NSNumber.init(value:))))
  }
  private func opacity(_ item: CALayer, _ values: [Double], _ times: [Double]) { track(item, "opacity", values, times) }
  private func position(_ item: CALayer, _ values: [CGPoint], _ times: [Double]) {
    track(item, "position", values.map { NSValue(point: $0) }, times)
  }
  private func build() {
    let blue = NSColor(srgbRed: 0.19, green: 0.35, blue: 0.88, alpha: 1)
    let purple = NSColor(srgbRed: 0.52, green: 0.36, blue: 0.76, alpha: 1)
    let mint = NSColor(srgbRed: 0.31, green: 0.63, blue: 0.54, alpha: 1)
    let frame = box(CGRect(x: 24, y: 23, width: 272, height: 154), color: .white, radius: 9)
    panels.append(frame)
    frame.shadowPath = CGPath(roundedRect: frame.bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
    frame.shadowColor = NSColor.black.cgColor; frame.shadowOpacity = 0.12; frame.shadowRadius = 8
    frame.shadowOffset = CGSize(width: 0, height: -3)
    let sidebar = box(CGRect(x: 0, y: 0, width: 86, height: 154), color: blue.withAlphaComponent(0.17), radius: 9, parent: frame)
    for i in 0..<3 { _ = box(CGRect(x: 8 + i * 9, y: 141, width: 5, height: 5), color: blue.withAlphaComponent(0.45), radius: 3, parent: sidebar) }
    _ = text("Open", rect: CGRect(x: 10, y: 119, width: 58, height: 12), size: 9, color: blue, parent: sidebar)
    for i in 0..<3 {
      _ = box(CGRect(x: 10 + i * 22, y: 104, width: 14, height: 14), color: [blue, purple, mint][i].withAlphaComponent(0.42), parent: sidebar)
    }
    _ = box(CGRect(x: 9, y: 70, width: 68, height: 1), color: blue.withAlphaComponent(0.22), radius: 0, parent: sidebar)
    let row = box(CGRect(x: 7, y: 39, width: 72, height: 20), color: blue.withAlphaComponent(0.14), parent: sidebar)
    if kind != 0 { _ = box(CGRect(x: 6, y: 6, width: 8, height: 8), color: blue, radius: 3, parent: row) }
    _ = text(kind == 0 ? "+ New Tab" : "A favorite site", rect: CGRect(x: kind == 0 ? 7 : 19, y: 4, width: 55, height: 12), color: blue, parent: row)
    let page = box(CGRect(x: 94, y: 9, width: 170, height: 136), color: blue.withAlphaComponent(0.04), radius: 5, parent: frame)
    let hero = box(CGRect(x: 14, y: 70, width: 142, height: 52), color: blue.withAlphaComponent(0.15), radius: 4, parent: page)
    let line = box(CGRect(x: 14, y: 52, width: 95, height: 5), color: blue.withAlphaComponent(0.24), radius: 2, parent: page)
    _ = line
    for i in 0..<3 { _ = box(CGRect(x: 14, y: 37 - i * 9, width: 135 - i * 9, height: 3), color: blue.withAlphaComponent(0.12), radius: 1, parent: page) }
    let cursor = box(CGRect(x: 0, y: 0, width: 9, height: 13), color: blue, radius: 2, parent: frame)
    cursor.transform = CATransform3DMakeRotation(-0.35, 0, 0, 1)
    switch kind {
    case 0:
      let command = box(CGRect(x: 45, y: 68, width: 190, height: 49), color: .white, radius: 7, parent: frame)
      command.borderWidth = 1; command.borderColor = blue.withAlphaComponent(0.2).cgColor; panels.append(command)
      _ = text("Search or enter a URL", rect: CGRect(x: 12, y: 29, width: 166, height: 12), color: blue.withAlphaComponent(0.65), parent: command)
      let typed = "example.com"
      for (i, letter) in typed.enumerated() {
        let glyph = text(String(letter), rect: CGRect(x: 12 + i * 8, y: 9, width: 9, height: 14), size: 11, color: blue, parent: command)
        let t = 0.30 + Double(i) * 0.025
        opacity(glyph, [0, 0, 1, 1], [0, t, t + 0.01, 1])
      }
      opacity(row, [0.35, 1, 1, 0.35, 0.35], [0, 0.12, 0.22, 0.30, 1])
      position(command, [CGPoint(x: 140, y: 125), CGPoint(x: 140, y: 125), command.position, command.position], [0, 0.18, 0.28, 1])
      opacity(command, [0, 0, 1, 1, 0, 0], [0, 0.18, 0.26, 0.66, 0.75, 1])
      opacity(page, [0, 0, 1, 1], [0, 0.65, 0.80, 1])
      position(cursor, [CGPoint(x: 55, y: 20), row.position, row.position, CGPoint(x: 176, y: 68), CGPoint(x: 176, y: 68)], [0, 0.12, 0.25, 0.52, 1])
    case 1:
      let destination = CGPoint(x: row.position.x, y: 87)
      position(row, [row.position, row.position, destination, destination], [0, 0.20, 0.65, 1])
      track(row, "transform.scale", [1, 1, 1.08, 1.08, 1, 1], [0, 0.18, 0.25, 0.59, 0.69, 1])
      position(cursor, [CGPoint(x: 110, y: 18), CGPoint(x: 57, y: 57), CGPoint(x: 57, y: 57), CGPoint(x: 57, y: 92), CGPoint(x: 110, y: 18)], [0, 0.18, 0.25, 0.65, 1])
    case 2:
      let mask = CALayer(); mask.frame = sidebar.bounds; mask.backgroundColor = NSColor.white.cgColor; sidebar.mask = mask
      let second = box(sidebar.bounds.offsetBy(dx: 86, dy: 0), color: NSColor(srgbRed: 0.88, green: 0.82, blue: 0.96, alpha: 1), radius: 9, parent: sidebar)
      spacePanel = second
      _ = text("Home", rect: CGRect(x: 10, y: 119, width: 68, height: 12), size: 9, color: purple, parent: second)
      for i in 0..<4 {
        _ = box(CGRect(x: 9, y: 87 - i * 18, width: 68, height: 12), color: purple.withAlphaComponent(0.18), parent: second)
      }
      position(second, [second.position, second.position, CGPoint(x: 43, y: 77), CGPoint(x: 43, y: 77)], [0, 0.25, 0.62, 1])
      let dots = box(CGRect(x: 27, y: 8, width: 33, height: 5), color: .clear, parent: sidebar)
      for i in 0..<3 { _ = box(CGRect(x: i * 12, y: 0, width: 5, height: 5), color: blue.withAlphaComponent(0.25), radius: 3, parent: dots) }
      let dot = box(CGRect(x: 0, y: 0, width: 5, height: 5), color: blue, radius: 3, parent: dots)
      position(dot, [dot.position, dot.position, CGPoint(x: 14.5, y: 2.5), CGPoint(x: 14.5, y: 2.5)], [0, 0.25, 0.62, 1])
      track(hero, "backgroundColor", [blue.withAlphaComponent(0.15).cgColor, blue.withAlphaComponent(0.15).cgColor, purple.withAlphaComponent(0.24).cgColor, purple.withAlphaComponent(0.24).cgColor], [0, 0.25, 0.62, 1])
      opacity(cursor, [0, 0], [0, 1])
    default:
      let secondPage = box(CGRect(x: 182, y: 9, width: 82, height: 136), color: mint.withAlphaComponent(0.2), radius: 5, parent: frame)
      _ = box(CGRect(x: 9, y: 72, width: 64, height: 50), color: mint.withAlphaComponent(0.4), parent: secondPage)
      for i in 0..<4 { _ = box(CGRect(x: 9, y: 54 - i * 10, width: 62 - i * 5, height: 3), color: mint.withAlphaComponent(0.35), radius: 1, parent: secondPage) }
      opacity(secondPage, [0, 0, 1, 1], [0, 0.52, 0.70, 1])
      track(page, "bounds.size.width", [170, 170, 82, 82], [0, 0.45, 0.70, 1])
      page.anchorPoint = CGPoint(x: 0, y: 0.5); page.position.x = 94; page.masksToBounds = true
      let target = CGPoint(x: 221, y: 80)
      position(row, [row.position, row.position, target, target], [0, 0.20, 0.57, 1])
      opacity(row, [1, 1, 0, 0], [0, 0.56, 0.68, 1])
      position(cursor, [CGPoint(x: 110, y: 18), CGPoint(x: 54, y: 57), target, target], [0, 0.18, 0.57, 1])
    }
    if kind != 2 { opacity(cursor, [1, 1, 0, 0], [0, 0.76, 0.87, 1]) }
  }
  func apply(dark: Bool) {
    guard self.dark != dark else { return }; self.dark = dark
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (text, color) in textLayers {
      text.foregroundColor = (dark ? color.blended(withFraction: 0.55, of: .white) ?? color : color).cgColor
    }
    spacePanel?.backgroundColor = (dark ? NSColor(srgbRed: 0.26, green: 0.23, blue: 0.36, alpha: 1)
      : NSColor(srgbRed: 0.88, green: 0.82, blue: 0.96, alpha: 1)).cgColor
    for panel in panels { panel.backgroundColor = (dark ? NSColor(srgbRed: 0.19, green: 0.21, blue: 0.27, alpha: 1) : .white).cgColor }
    CATransaction.commit()
  }
  func play(duration: Double) {
    freeze(); running = true
    CATransaction.begin(); CATransaction.setDisableActions(true)
    let start = CACurrentMediaTime()
    for (i, track) in tracks.enumerated() {
      track.layer.setValue(track.values.last, forKeyPath: track.key)
      let animation = CAKeyframeAnimation(keyPath: track.key)
      animation.values = track.values; animation.keyTimes = track.times; animation.duration = duration
      animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: track.values.count - 1)
      animation.beginTime = track.layer.convertTime(start, from: nil)
      track.layer.add(animation, forKey: "welcome-\(i)")
    }
    CATransaction.commit()
  }
  func freeze() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    // Read every animated property before removing any animation on its layer.
    let frozen = tracks.map { ($0, $0.layer.presentation()?.value(forKeyPath: $0.key)) }
    for (track, value) in frozen {
      if let value { track.layer.setValue(value, forKeyPath: track.key) }
      track.layer.removeAllAnimations()
    }
    CATransaction.commit(); running = false
  }
  func finish() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for track in tracks { track.layer.removeAllAnimations(); track.layer.setValue(track.values.last, forKeyPath: track.key) }
    CATransaction.commit(); running = false
  }
}
