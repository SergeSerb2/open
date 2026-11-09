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
  private enum Paint: String { case panel, sidebar, otherSidebar, row, active, canvas }
  let kind: Int
  private let scene = CALayer()
  private var tracks: [Track] = []
  private var fills: [(CALayer, Paint)] = []
  private var panels: [CALayer] = []
  private var textLayers: [(CATextLayer, Bool)] = []
  private var appliedBackground: NSColor?
  private var appliedTint: NSColor?
  private var appliedDark: Bool?
  private(set) var running = false
  var animationCount: Int { tracks.reduce(0) { $0 + ($1.layer.animationKeys()?.count ?? 0) } }
  #if OPEN_AUTOMATION
  var drawnLabels: [String] { textLayers.compactMap { $0.0.string as? String } }
  var drawnLabelFrames: [(String, CGRect)] {
    textLayers.compactMap { text, _ in
      guard let label = text.string as? String else { return nil }
      return (label, text.convert(text.bounds, to: layer))
    }
  }
  var paintColors: [String: NSColor] {
    var result: [String: NSColor] = [:]
    for (layer, paint) in fills where result[paint.rawValue] == nil {
      if let color = layer.backgroundColor { result[paint.rawValue] = NSColor(cgColor: color) }
    }
    if let color = layer?.backgroundColor { result["surface"] = NSColor(cgColor: color) }
    for (text, white) in textLayers {
      if let color = text.foregroundColor { result[white ? "activeText" : "text"] = NSColor(cgColor: color) }
    }
    return result
  }
  var sceneScale: [CGFloat] { [scene.transform.m11, scene.transform.m22] }
  #endif

  init(kind: Int) {
    self.kind = kind; super.init(frame: .zero); wantsLayer = true
    scene.anchorPoint = .zero; scene.bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
    layer?.addSublayer(scene); build(); finish()
    apply(background: .white, sidebarTint: .systemBlue, dark: false)
    setAccessibilityElement(false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let scale = min(bounds.width / 320, bounds.height / 200)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    scene.position = CGPoint(x: (bounds.width - 320 * scale) / 2, y: (bounds.height - 200 * scale) / 2)
    scene.transform = CATransform3DMakeScale(scale, scale, 1)
    CATransaction.commit()
  }
  private func box(_ rect: CGRect, paint: Paint, radius: CGFloat = 4, parent: CALayer? = nil) -> CALayer {
    let item = CALayer(); item.frame = rect; item.cornerRadius = radius
    fills.append((item, paint)); (parent ?? scene).addSublayer(item); return item
  }
  private func text(_ value: String, rect: CGRect, white: Bool = false, parent: CALayer) -> CATextLayer {
    let item = CATextLayer(); item.frame = rect; item.string = value
    item.font = NSFont.systemFont(ofSize: 9, weight: .medium); item.fontSize = 9
    item.contentsScale = 2; item.alignmentMode = .left
    parent.addSublayer(item); textLayers.append((item, white)); return item
  }
  private func track(_ item: CALayer, _ key: String, _ values: [Any], _ times: [Double]) {
    tracks.append(Track(layer: item, key: key, values: values, times: times.map(NSNumber.init(value:))))
  }
  private func opacity(_ item: CALayer, _ values: [Double], _ times: [Double]) { track(item, "opacity", values, times) }
  private func position(_ item: CALayer, _ values: [CGPoint], _ times: [Double]) {
    track(item, "position", values.map { NSValue(point: $0) }, times)
  }
  private func build() {
    let frame = box(CGRect(x: 24, y: 23, width: 272, height: 154), paint: .panel, radius: 9)
    panels.append(frame)
    frame.shadowPath = CGPath(roundedRect: frame.bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
    frame.shadowColor = NSColor.black.cgColor; frame.shadowOpacity = 0.12; frame.shadowRadius = 8
    frame.shadowOffset = CGSize(width: 0, height: -3)
    let sidebar = box(CGRect(x: 0, y: 0, width: 86, height: 154), paint: .sidebar, radius: 9, parent: frame)
    for i in 0..<3 { _ = box(CGRect(x: 8 + i * 9, y: 141, width: 5, height: 5), paint: .row, radius: 3, parent: sidebar) }
    for i in 0..<2 { _ = box(CGRect(x: 9, y: 119 - i * 14, width: 68 - i * 12, height: 7), paint: .row, radius: 3, parent: sidebar) }
    _ = box(CGRect(x: 9, y: 70, width: 68, height: 1), paint: .row, radius: 0, parent: sidebar)
    let row = box(CGRect(x: 7, y: 39, width: 72, height: 20), paint: .active, parent: sidebar)
    if kind == 0 {
      _ = text("+ New Tab", rect: CGRect(x: 7, y: 4, width: 60, height: 12), white: true, parent: row)
    } else {
      _ = box(CGRect(x: 9, y: 8, width: 47, height: 4), paint: .row, radius: 2, parent: row)
    }
    let page = box(CGRect(x: 94, y: 9, width: 170, height: 136), paint: .canvas, radius: 5, parent: frame)
    _ = box(CGRect(x: 14, y: 70, width: 142, height: 52), paint: .row, parent: page)
    _ = box(CGRect(x: 14, y: 52, width: 95, height: 5), paint: .row, radius: 2, parent: page)
    for i in 0..<3 { _ = box(CGRect(x: 14, y: 37 - i * 9, width: 135 - i * 9, height: 3), paint: .row, radius: 1, parent: page) }
    let cursor = box(CGRect(x: 0, y: 0, width: 9, height: 13), paint: .active, radius: 2, parent: frame)
    cursor.transform = CATransform3DMakeRotation(-0.35, 0, 0, 1)
    switch kind {
    case 0:
      let command = box(CGRect(x: 45, y: 68, width: 190, height: 49), paint: .panel, radius: 7, parent: frame)
      panels.append(command)
      _ = box(CGRect(x: 12, y: 31, width: 100, height: 4), paint: .row, radius: 2, parent: command)
      // Abstract typed marks preserve the demo without inventing a site label.
      for i in 0..<11 {
        let glyph = box(CGRect(x: 12 + i * 8, y: 13, width: 6, height: 3), paint: .row, radius: 1, parent: command)
        let t = 0.30 + Double(i) * 0.025
        opacity(glyph, [0, 0, 1, 1], [0, t, t + 0.01, 1])
      }
      // This is an active pill. Its white instruction stays opaque throughout.
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
      let second = box(sidebar.bounds.offsetBy(dx: 86, dy: 0), paint: .otherSidebar, radius: 9, parent: sidebar)
      _ = text("Home", rect: CGRect(x: 10, y: 119, width: 68, height: 12), parent: second)
      for i in 0..<4 { _ = box(CGRect(x: 9, y: 87 - i * 18, width: 68, height: 12), paint: .row, parent: second) }
      position(second, [second.position, second.position, CGPoint(x: 43, y: 77), CGPoint(x: 43, y: 77)], [0, 0.25, 0.62, 1])
      let dots = CALayer(); dots.frame = CGRect(x: 27, y: 8, width: 33, height: 5); sidebar.addSublayer(dots)
      for i in 0..<3 { _ = box(CGRect(x: i * 12, y: 0, width: 5, height: 5), paint: .row, radius: 3, parent: dots) }
      let dot = box(CGRect(x: 0, y: 0, width: 5, height: 5), paint: .active, radius: 3, parent: dots)
      position(dot, [dot.position, dot.position, CGPoint(x: 14.5, y: 2.5), CGPoint(x: 14.5, y: 2.5)], [0, 0.25, 0.62, 1])
      opacity(cursor, [0, 0], [0, 1])
    default:
      let secondPage = box(CGRect(x: 182, y: 9, width: 82, height: 136), paint: .canvas, radius: 5, parent: frame)
      _ = box(CGRect(x: 9, y: 72, width: 64, height: 50), paint: .row, parent: secondPage)
      for i in 0..<4 { _ = box(CGRect(x: 9, y: 54 - i * 10, width: 62 - i * 5, height: 3), paint: .row, radius: 1, parent: secondPage) }
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
  func apply(background: NSColor, sidebarTint: NSColor, dark: Bool) {
    guard appliedDark != dark || appliedBackground?.isEqual(background) != true || appliedTint?.isEqual(sidebarTint) != true else { return }
    appliedDark = dark; appliedBackground = background; appliedTint = sidebarTint
    let contrast: NSColor = dark ? .white : .black
    let surface = WelcomeColors.surface(background, dark: dark)
    let blue = WelcomeTextColors.illustrationBlue
    let row = contrast.withAlphaComponent(dark ? 0.14 : 0.10)
    let otherTint = sidebarTint.blended(withFraction: 0.35, of: blue) ?? sidebarTint
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer?.backgroundColor = surface.cgColor
    for (item, paint) in fills {
      let color: NSColor
      switch paint {
      case .panel: color = surface
      case .sidebar: color = sidebarTint.withAlphaComponent(0.55)
      case .otherSidebar: color = otherTint.withAlphaComponent(0.55)
      case .row: color = row
      case .active: color = blue
      case .canvas: color = background
      }
      item.backgroundColor = color.cgColor
    }
    for (text, active) in textLayers {
      text.foregroundColor = (active ? NSColor.white : contrast.withAlphaComponent(0.75)).cgColor
    }
    for panel in panels { panel.borderWidth = 1; panel.borderColor = row.cgColor }
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
