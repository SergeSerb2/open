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
    let top = NSBezierPath(); top.move(to: CGPoint(x: 36,y: 749)); top.line(to: CGPoint(x: 1164,y: 749))
    NSColor.white.withAlphaComponent(0.28).setStroke(); top.lineWidth = 1200/rect.width; top.stroke()
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
    ((name.isEmpty ? "Open":name) as NSString).draw(in: CGRect(x: 72, y: 130, width: 1040, height: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 22*1200/min(620,rect.width), weight: .semibold), .foregroundColor: nameColor])
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "MMMM d, yyyy"
    (("Since " + formatter.string(from: date)) as NSString).draw(at: CGPoint(x: 76, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 11.5*1200/min(620,rect.width)), .foregroundColor: dateColor])
  }
  func png() throws -> Data {
    // Largest explicitly requested bitmap: 1200 * 750 * 4 = 3,600,000 bytes.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 750, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 4800, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    draw(in: CGRect(x: 0, y: 0, width: 1200, height: 750)); NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }; return data
  }
}

/// Every setup scene shares the room and the real in-memory browser miniature.
@MainActor final class OnboardingPreview: NSView {
  private var step = "name"
  private let room = OnboardingRoomView(frame: .zero)
  private let favoriteMiniature = OnboardingMiniature()
  var lifetimeMiniature: OnboardingMiniature { favoriteMiniature }
  private let progress = OnboardingProgressView(frame: .zero)
  private let scene = CALayer()
  private let readyCard = OnboardingReadyCard()
  private let mail = OnboardingMailChip(frame: .zero)
  private let flyingLink = OnboardingMailChip(frame: .zero)
  private var linkTask: Task<Void,Never>?
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    addSubview(room); layer?.addSublayer(scene)
    favoriteMiniature.perspective = true
    addSubview(favoriteMiniature); addSubview(progress)
    addSubview(readyCard); readyCard.isHidden = true; readyCard.layer?.zPosition = 1
    addSubview(mail); addSubview(flyingLink); mail.isHidden = true; flyingLink.isHidden = true
    setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityChildren([])
  }
  required init?(coder: NSCoder) { nil }
  isolated deinit { linkTask?.cancel() }
  override func layout() {
    super.layout(); scene.frame = bounds; room.frame = bounds
    readyCard.frame = cardRect
    favoriteMiniature.frame = CGRect(x: 44,y: bounds.height*0.12,width: 480,height: 544)
    progress.frame = CGRect(x: 40,y: 36,width: 104,height: 6)
    progress.selected = ["name","import","favorites","theme","blocker","defaultBrowser","ready"].firstIndex(of: step) ?? 0
    mail.frame = CGRect(x: 58,y: bounds.height-126,width: 184,height: 48)
    flyingLink.frame = CGRect(x: 112,y: bounds.height-184,width: 160,height: 40)
  }
  func update(step: String,name: String,favorites: [(String,OnboardingFavicons.Tile)],count: Int,report: Bool,blocker: Bool,card: OpenCardDrawing,reduceMotion: Bool,source: BrowserModel) {
    let changed = self.step != step; self.step = step
    room.isHidden = false; favoriteMiniature.isHidden = step == "ready"
    favoriteMiniature.reduceMotion = reduceMotion
    if step != "import" || !report { favoriteMiniature.setName(name) }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua
    favoriteMiniature.apply(theme: card.theme,dark: dark)
    favoriteMiniature.setFavorites(favorites,reduceMotion: reduceMotion)
    let style = SpaceThemeStyle(theme: card.theme,system: .dark)
    room.tint = card.theme.style == nil && card.theme.importedArcThemeJSON == nil ? nil:style.accent?.nsColor
    readyCard.isHidden = step != "ready"; readyCard.card = card; readyCard.reduced = reduceMotion
    mail.isHidden = step != "defaultBrowser"
    if step != "defaultBrowser" || changed { flyingLink.isHidden = true }
    if changed { linkTask?.cancel(); linkTask = nil; flyingLink.layer?.removeAllAnimations() }
    if step != "blocker" { favoriteMiniature.clearBlocker() }
    switch step {
    case "name": favoriteMiniature.setEditorial(title: name.isEmpty ? "A place to call your own":"Welcome, \(name)",subtitle: "Make a little room for your world.")
    case "import": favoriteMiniature.setImportedSource(source,completed: report,count: count)
    case "favorites": favoriteMiniature.setEditorial(title: "Welcome to Open",subtitle: "Make yourself at home.")
    case "theme": favoriteMiniature.setEditorial(title: "A Space that feels like you",subtitle: "Choose a colour. Set the mood.")
    case "blocker":
      favoriteMiniature.setEditorial(title: "A quieter page",subtitle: "More room for what you came to read.")
      favoriteMiniature.setBlocker(blocker,animated: !changed)
    case "defaultBrowser":
      favoriteMiniature.setEditorial(title: "A home for every link",subtitle: "From a message to your next good read.")
      if changed {
        needsLayout = true; layoutSubtreeIfNeeded(); flyingLink.isHidden = reduceMotion
        if reduceMotion { favoriteMiniature.receiveLink() }
        else {
          let start = flyingLink.layer?.position ?? .zero
          let end = CGPoint(x: 165,y: 440)
          flyingLink.layer?.position = end
          let travel = CAKeyframeAnimation(keyPath: "position"); travel.values = [NSValue(point: start),NSValue(point: start),NSValue(point: end),NSValue(point: end)]
          travel.keyTimes = [0,0.2,0.7,1]; travel.duration = 3; travel.repeatCount = 2
          travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); flyingLink.layer?.add(travel,forKey: "link-travel")
          linkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.1)); guard !Task.isCancelled,let self else { return }
            favoriteMiniature.receiveLink()
            try? await Task.sleep(for: .seconds(3.9)); guard !Task.isCancelled else { return }; flyingLink.isHidden = true
          }
        }
      }
    default: break
    }
    setAccessibilityLabel(step == "ready" ? "Open card for \(name.isEmpty ? "Open":name)":"\(step) preview")
    needsLayout = true
  }
  var favoriteState: [String:Any] { favoriteMiniature.favoriteState }
  #if OPEN_AUTOMATION
  var artworkState: [String:Any] {
    ["step":step,"miniature":favoriteMiniature.demoState,"miniatureHidden":favoriteMiniature.isHidden,
     "cardVisible":!readyCard.isHidden,"progress":progress.selected]
  }
  #endif
  var cardRect: CGRect {
    let width = max(1,min(620,bounds.width-96))
    return CGRect(x: bounds.midX-width/2,y: bounds.midY-width*0.625/2,width: width,height: width*0.625)
  }
  func showConfetti(_ emitter: CAEmitterLayer) {
    emitter.frame = bounds; emitter.emitterPosition = CGPoint(x: cardRect.midX,y: cardRect.maxY+12)
    emitter.emitterSize = CGSize(width: cardRect.width*0.85,height: 1); scene.addSublayer(emitter)
  }
  var confettiBehindCard: Bool {
    guard let emitter = scene.sublayers?.first(where: { $0 is CAEmitterLayer }) else { return false }
    return !readyCard.isHidden && emitter.superlayer === scene && scene.zPosition < (readyCard.layer?.zPosition ?? 0)
  }
}

@MainActor private final class OnboardingMailChip: NSView {
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 12; layer?.backgroundColor = OnboardingTokens.Room.white.withAlphaComponent(0.95).cgColor; layer?.shadowOpacity = 0.24; layer?.shadowRadius = 18 }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    let icon = NSImage(systemSymbolName: "envelope.fill",accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [OnboardingTokens.Room.space]))
    icon?.draw(in: CGRect(x: 14,y: bounds.midY-8,width: 20,height: 16))
    ("Mail · A link for you" as NSString).draw(at: CGPoint(x: 43,y: bounds.midY-8),withAttributes: [.font:NSFont.systemFont(ofSize: 12,weight: .medium),.foregroundColor:OnboardingTokens.Room.ink])
  }
}

@MainActor private final class OnboardingReadyCard: NSView {
  var card: OpenCardDrawing? { didSet { needsDisplay = true } }
  var reduced = false
  private let highlight = CAGradientLayer()
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 32; layer?.shadowOffset = CGSize(width: 0, height: -12)
    highlight.type = .radial; highlight.startPoint = CGPoint(x: 0.35,y: 0.75); highlight.endPoint = CGPoint(x: 1,y: 1)
    highlight.colors = [OnboardingTokens.Room.white.withAlphaComponent(0.23).cgColor,OnboardingTokens.Room.white.withAlphaComponent(0).cgColor]
    layer?.addSublayer(highlight)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    let radius = bounds.width*36/1200
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    highlight.frame = bounds; highlight.cornerRadius = radius
    CATransaction.commit()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds,options: [.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow],owner: self))
  }
  override func mouseMoved(with event: NSEvent) {
    guard !reduced else { return }; let p = convert(event.locationInWindow,from: nil)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    highlight.startPoint = CGPoint(x: p.x/max(1,bounds.width),y: p.y/max(1,bounds.height)); CATransaction.commit()
  }
  override func draw(_ dirtyRect: NSRect) { card?.draw(in: bounds) }
}

@MainActor private final class OnboardingProgressView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    // Keep the dots above the room's layer-backed planes.
    wantsLayer = true; setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    var x: CGFloat = 0
    for i in 0..<7 {
      let width: CGFloat = i == selected ? 20:6
      OnboardingTokens.Room.white.withAlphaComponent(i == selected ? 1:0.28).setFill()
      NSBezierPath(roundedRect: CGRect(x: x,y: 0,width: width,height: 6),xRadius: 3,yRadius: 3).fill()
      x += width+7
    }
  }
}
