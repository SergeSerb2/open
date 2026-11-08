import AppKit
import QuartzCore
import OpenDesign
import OpenModel
import OpenOnboarding
import ImageIO

/// One original drawing is used for the live card and its exact 1200 x 750 PNG.
@MainActor struct OpenCardDrawing {
  let name: String
  let theme: SpaceTheme
  let date: Date
  let pattern: Int
  private var palette: [NSColor] {
    let style = SpaceThemeStyle(theme: theme, system: .dark)
    let colors: [RGBA] = switch style.fill { case .blended(let base, let overlay): base + overlay.filter { $0.alpha > 0 }; case .corners(let values): values }
    let fallback = [NSColor(srgbRed: 26/255, green: 63/255, blue: 208/255, alpha: 1), NSColor(srgbRed: 11/255, green: 26/255, blue: 92/255, alpha: 1)]
    let values = theme.style == nil && theme.importedArcThemeJSON == nil ? fallback:colors.map(\.nsColor)
    return values.count > 1 ? values:Array(repeating: values.first ?? fallback[0], count: 2)
  }
  private static func luminance(of gradient: NSGradient?) -> Double {
    guard let color = gradient?.interpolatedColor(atLocation: 0.5).usingColorSpace(.sRGB) else { return 0 }
    func linear(_ component: CGFloat) -> Double {
      let value = min(1, max(0, Double(component)))
      return value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055, 2.4)
    }
    return 0.2126*linear(color.redComponent) + 0.7152*linear(color.greenComponent) + 0.0722*linear(color.blueComponent)
  }
  var backgroundLuminance: Double { Self.luminance(of: NSGradient(colors: palette)) }
  var usesDarkText: Bool { backgroundLuminance > 0.55 }
  func draw(in rect: CGRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: rect.width/1200, y: rect.height/750)
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 750)
    NSBezierPath(roundedRect: bounds, xRadius: 36, yRadius: 36).addClip()
    let gradient = NSGradient(colors: palette)
    gradient?.draw(in: bounds, angle: 35)
    // Six deterministic patterns. No external art or random data is used.
    for index in 0..<9 {
      let seed = (index*173 + pattern*97 + 31)%997
      let x = CGFloat(seed%1200), y = CGFloat((seed*3+pattern*83)%750), radius = CGFloat(80+(seed%180))
      NSColor.white.withAlphaComponent(0.035+Double(index%3)*0.02).setFill()
      if pattern%2 == 0 { NSBezierPath(ovalIn: CGRect(x: x-radius/2, y: y-radius/2, width: radius, height: radius)).fill() }
      else { let line = NSBezierPath(); line.move(to: CGPoint(x: x, y: y)); line.line(to: CGPoint(x: x+280, y: y+180)); line.lineWidth = CGFloat(8+seed%12); NSColor.white.withAlphaComponent(0.07).setStroke(); line.stroke() }
    }
    if let grain = Grain.tile(noiseFactor: 0.6, scale: 1) {
      context.saveGState(); context.setAlpha(0.08)
      for y in stride(from: 0, to: 750, by: grain.height) { for x in stride(from: 0, to: 1200, by: grain.width) { context.draw(grain, in: CGRect(x: x, y: y, width: grain.width, height: grain.height)) } }
      context.restoreGState()
    }
    OnboardingBrandMark.draw(in: CGRect(x: 785, y: 80, width: 480, height: 650), opacity: 0.10)
    OnboardingBrandMark.draw(in: CGRect(x: 72, y: 535, width: 78, height: 110))
    let darkText = Self.luminance(of: gradient) > 0.55
    let nameColor = darkText ? NSColor.black.withAlphaComponent(0.82):NSColor.white
    let dateColor = darkText ? NSColor.black.withAlphaComponent(0.55):NSColor.white.withAlphaComponent(0.72)
    ((name.isEmpty ? "Open":name) as NSString).draw(in: CGRect(x: 72, y: 130, width: 1040, height: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: nameColor])
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "MMMM d, yyyy"
    (("Since " + formatter.string(from: date)) as NSString).draw(at: CGPoint(x: 76, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: dateColor])
  }
  func png() throws -> Data {
    // Largest explicitly requested bitmap: 1200 * 750 * 4 = 3,600,000 bytes.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 750, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 4800, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    draw(in: CGRect(x: 0, y: 0, width: 1200, height: 750)); NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }; return data
  }
}

/// Original miniature scenes. Only the two-loop link uses a CA animation.
@MainActor final class OnboardingPreview: NSView {
  private var step = "name", name = ""
  private var favorites: [String] = []
  private var count = 0, report = false, blocker = true, reduced = false
  private var scene = CALayer()
  private let theme = ThemeBackgroundView()
  private let miniBrowser = OnboardingMiniBrowser()
  private let readyCard = OnboardingReadyCard()
  private let link = CALayer()
  private var linkStarted = false
  private var ads: [CALayer] = []
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true; layer?.addSublayer(scene)
    theme.isHidden = true; theme.wantsLayer = true; theme.layer?.cornerRadius = 14; theme.layer?.masksToBounds = true
    miniBrowser.frame = CGRect(x: 0, y: 0, width: 420, height: 280)
    miniBrowser.autoresizingMask = [.width, .height]; theme.addSubview(miniBrowser)
    addSubview(theme)
    addSubview(readyCard); readyCard.isHidden = true; readyCard.layer?.zPosition = 1
    link.backgroundColor = NSColor.systemBlue.cgColor; link.cornerRadius = 5
    for _ in 0..<3 { let ad = CALayer(); ad.backgroundColor = NSColor(white: 0.7, alpha: 1).cgColor; ad.cornerRadius = 5; ads.append(ad) }
    setAccessibilityElement(true); setAccessibilityRole(.image)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout(); scene.frame = bounds
    theme.frame = CGRect(x: bounds.midX-210, y: bounds.midY-140, width: 420, height: 280)
    readyCard.frame = cardRect
    if step == "defaultBrowser" { layoutLink() }
  }
  func update(step: String, name: String, favorites: [String], count: Int, report: Bool, blocker: Bool, card: OpenCardDrawing, reduceMotion: Bool) {
    let changed = self.step != step
    self.step = step; self.name = name; self.favorites = favorites; self.count = min(8, max(0, count)); self.report = report; self.blocker = blocker; reduced = reduceMotion
    theme.isHidden = step != "theme"
    readyCard.isHidden = step != "ready"; readyCard.card = card
    if step == "theme" {
      let style = SpaceThemeStyle(theme: card.theme, system: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark:.light)
      theme.style = style; theme.material = .window
      miniBrowser.tint = style.accent?.nsColor ?? style.tintedLightAccent?.nsColor ?? .systemBlue
    }
    link.isHidden = step != "defaultBrowser"; if changed { linkStarted = false; link.removeAllAnimations(); link.removeFromSuperlayer(); ads.forEach { $0.removeFromSuperlayer() } }
    if step == "defaultBrowser" && changed { scene.addSublayer(link); layoutLink() }
    if step == "blocker" {
      CATransaction.begin(); CATransaction.setAnimationDuration(reduceMotion || changed ? 0:0.4)
      for (index, ad) in ads.enumerated() { if ad.superlayer == nil { scene.addSublayer(ad) }; ad.frame = CGRect(x: bounds.midX-170+CGFloat(index)*117, y: bounds.midY-70, width: 100, height: blocker ? 0:68); ad.opacity = blocker ? 0:1 }
      CATransaction.commit()
    }
    setAccessibilityLabel(step == "ready" ? "Open card for \(name.isEmpty ? "Open":name)": "\(step) preview")
    needsDisplay = true
  }
  var cardRect: CGRect {
    let width = max(1, min(620, bounds.width-96))
    return CGRect(x: bounds.midX-width/2, y: bounds.midY-width*0.625/2, width: width, height: width*0.625)
  }
  func showConfetti(_ emitter: CAEmitterLayer) {
    emitter.frame = bounds
    emitter.emitterPosition = CGPoint(x: cardRect.midX, y: cardRect.maxY+12)
    emitter.emitterSize = CGSize(width: cardRect.width*0.85, height: 1)
    // The scene is below the readyCard subview's layer, including all its text.
    scene.addSublayer(emitter)
  }
  var confettiBehindCard: Bool {
    guard let emitter = scene.sublayers?.first(where: { $0 is CAEmitterLayer }) else { return false }
    return !readyCard.isHidden && emitter.superlayer === scene && scene.zPosition < (readyCard.layer?.zPosition ?? 0)
  }
  private func layoutLink() {
    guard link.superlayer != nil else { return }
    let start = CGPoint(x: bounds.midX-140, y: bounds.midY+30), end = CGPoint(x: bounds.midX+125, y: bounds.midY-40)
    link.bounds = CGRect(x: 0, y: 0, width: 36, height: 10); link.position = end
    guard !reduced, !linkStarted else { return }; linkStarted = true
    let motion = CAKeyframeAnimation(keyPath: "position"); motion.values = [NSValue(point: start), NSValue(point: start), NSValue(point: end), NSValue(point: end)]; motion.keyTimes = [0, 0.2, 0.7, 1]; motion.duration = 3; motion.repeatCount = 2; motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); link.add(motion, forKey: "link-travel")
  }
  private func text(_ value: String, in rect: CGRect, size: CGFloat = 15, color: NSColor = .white) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
  }
  override func draw(_ dirtyRect: NSRect) {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    switch step {
    case "name":
      OnboardingBrandMark.draw(in: CGRect(x: center.x-44, y: center.y, width: 88, height: 120))
      text(name.isEmpty ? "Hello":"Hello, \(name)", in: CGRect(x: center.x-300, y: center.y-75, width: 600, height: 44), size: 28)
    case "import", "favorites":
      let rect = CGRect(x: center.x-170, y: center.y-230, width: 340, height: 460)
      NSColor.white.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
      if step == "favorites" {
        for (index, value) in favorites.enumerated() { let r = CGRect(x: rect.minX+25+CGFloat(index%3)*100, y: rect.maxY-72-CGFloat(index/3)*56, width: 90, height: 40); NSColor.white.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill(); text(String(value.prefix(1)), in: r.insetBy(dx: 2, dy: 8), size: 19) }
      } else { for index in 0..<count { NSColor.white.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: CGRect(x: rect.minX+24, y: rect.maxY-60-CGFloat(index)*44, width: 292, height: 28), xRadius: 7, yRadius: 7).fill() }; if report { text("✓", in: CGRect(x: center.x-30, y: rect.minY+16, width: 60, height: 48), size: 38) } }
    case "theme": break // Real ThemeBackgroundView draws the chosen Space style.
    case "blocker":
      NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: center.x-210, y: center.y-150, width: 420, height: 300), xRadius: 14, yRadius: 14).fill()
      text("A quieter page", in: CGRect(x: center.x-180, y: center.y+70, width: 360, height: 40), size: 24, color: .darkGray)
      for index in 0..<3 { NSColor(white: 0.9, alpha: 1).setFill(); CGRect(x: center.x-170, y: center.y+32-CGFloat(index)*22, width: 340-CGFloat(index)*28, height: 9).fill() }
    case "defaultBrowser":
      NSColor.white.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: CGRect(x: center.x-220, y: center.y-10, width: 160, height: 110), xRadius: 16, yRadius: 16).fill()
      text("A link for you", in: CGRect(x: center.x-215, y: center.y+30, width: 150, height: 25), size: 17)
      NSColor.white.withAlphaComponent(0.22).setFill(); NSBezierPath(roundedRect: CGRect(x: center.x+50, y: center.y-120, width: 200, height: 150), xRadius: 14, yRadius: 14).fill()
      OnboardingBrandMark.draw(in: CGRect(x: center.x+130, y: center.y-90, width: 40, height: 60))
    case "ready": break // Separate foreground layer keeps confetti behind the card.
    default: break
    }
  }
}

@MainActor private final class OnboardingReadyCard: NSView {
  var card: OpenCardDrawing? { didSet { needsDisplay = true } }
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 35; layer?.shadowOffset = CGSize(width: 0, height: -12)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    let radius = bounds.width*36/1200
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }
  override func draw(_ dirtyRect: NSRect) { card?.draw(in: bounds) }
}

@MainActor private final class OnboardingMiniBrowser: NSView {
  var tint = NSColor.systemBlue { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { color.withAlphaComponent(0.8).setFill(); NSBezierPath(ovalIn: CGRect(x: 12+index*15, y: 12, width: 8, height: 8)).fill() }
    NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: CGRect(x: 120, y: 8, width: bounds.width-128, height: bounds.height-16), xRadius: 8, yRadius: 8).fill()
    for index in 0..<4 { tint.withAlphaComponent(index == 1 ? 0.4:0.15).setFill(); NSBezierPath(roundedRect: CGRect(x: 12, y: 52+index*34, width: 96, height: 20), xRadius: 5, yRadius: 5).fill() }
    NSColor.gray.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: CGRect(x: 140, y: 18, width: 250, height: 18), xRadius: 6, yRadius: 6).fill()
    NSColor.gray.withAlphaComponent(0.18).setFill()
    for index in 0..<3 { NSBezierPath(roundedRect: CGRect(x: 145, y: 64+index*22, width: 220-index*20, height: 9), xRadius: 4, yRadius: 4).fill() }
  }
}
