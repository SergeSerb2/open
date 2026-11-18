import AppKit
import QuartzCore

/// Palette and metrics of the light basics page. Our own values, matched by
/// measurement to the reference page at 1280 × 800 (docs/re/onboarding.md §6).
@MainActor
enum WelcomeStyle {
  static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
  static let ink = rgb(0x14153D)
  static let secondary = rgb(0x5C5F86)
  static let accent = rgb(0x3438E0)
  static let cardFill = rgb(0xFFFFFF)
  static let collapsedFill = rgb(0xFFFFFF, 0.42)
  static let hoverFill = rgb(0xFFFFFF, 0.62)
  static let cardBorder = rgb(0x14153D, 0.12)
  static let keyFill = rgb(0xD9DAFF)
  static let keyEdge = rgb(0x8C8EF2)
  static let keyShade = rgb(0x7C7FE6)

  static let cardRadius: CGFloat = 12
  static let collapsedHeight: CGFloat = 72
  static let cardGap: CGFloat = 8
  static let progressHeight: CGFloat = 3
  static let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
  static let bodyFont = NSFont.systemFont(ofSize: 17, weight: .regular)
  static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)

  /// Accordion change: a critically damped spring that settles in about 0.25 s,
  /// measured on the reference accordion (60 fps capture).
  static func spring(_ keyPath: String) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: keyPath)
    spring.mass = 1; spring.stiffness = 1600; spring.damping = 80; spring.initialVelocity = 0
    spring.duration = spring.settlingDuration
    return spring
  }
}

/// One step of the accordion. The step's frame changes only when the active
/// step changes; Core Animation carries the motion. The body copy is laid out
/// once at its final position and is revealed by the growing card.
@MainActor
final class WelcomeStepView: NSControl {
  struct Copy { let title: String; let detail: String; let symbol: String; let keys: [String] }

  let index: Int
  let copy: Copy
  var press: (() -> Void)?
  private let number = NSTextField(labelWithString: "")
  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  let detail = NSTextField(wrappingLabelWithString: "")
  private var keycaps: [WelcomeKeycapView] = []
  private let progress = CALayer()
  private var tracking: NSTrackingArea?
  private(set) var isHovered = false
  private var keyboardFocused = false
  private(set) var isActive = false
  var ownTrackingAreaCount: Int { tracking.map { area in trackingAreas.filter { $0 === area }.count } ?? 0 }

  init(index: Int, copy: Copy) {
    self.index = index; self.copy = copy
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.cornerRadius = WelcomeStyle.cardRadius; layer?.cornerCurve = .continuous
    layer?.masksToBounds = true; layer?.borderWidth = 1
    number.stringValue = "\(index + 1)"; number.font = WelcomeStyle.numberFont
    title.stringValue = copy.title; title.font = WelcomeStyle.titleFont; title.textColor = WelcomeStyle.ink
    title.lineBreakMode = .byTruncatingTail
    detail.stringValue = copy.detail; detail.font = WelcomeStyle.bodyFont; detail.textColor = WelcomeStyle.ink
    icon.image = NSImage(systemSymbolName: copy.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
    icon.contentTintColor = WelcomeStyle.accent
    for view in [number, icon, title, detail] as [NSView] { addSubview(view) }
    for key in copy.keys { let cap = WelcomeKeycapView(glyph: key); keycaps.append(cap); addSubview(cap) }
    progress.backgroundColor = WelcomeStyle.accent.cgColor
    progress.anchorPoint = CGPoint(x: 0, y: 0.5)
    progress.isHidden = true
    layer?.addSublayer(progress)
    setAccessibilityElement(true); setAccessibilityRole(.button)
    setAccessibilityLabel("\(copy.title). \(copy.detail)")
    setAccessibilityChildren([])
    setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Replay", target: self, selector: #selector(accessibilityPerformPress))])
    // One hover area for the step's life (see the earlier card note: a
    // replaced area synthesizes a new enter event under a resting pointer).
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area); tracking = area
    applyState(animated: false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  /// A focus ring only for keyboard focus (Tab), never for a click or a page load.
  override var focusRingType: NSFocusRingType { get { keyboardFocused ? .exterior : .none } set {} }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: WelcomeStyle.cardRadius, yRadius: WelcomeStyle.cardRadius).fill()
  }

  /// The height this step needs when it is the active step, for a width.
  func expandedHeight(width: CGFloat) -> CGFloat {
    let textWidth = max(40, width - 47 - 20)
    let body = (copy.detail as NSString).boundingRect(with: NSSize(width: textWidth, height: 1000),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: WelcomeStyle.bodyFont]).height
    var height = 24 + 24 + 6 + ceil(body) + 24
    if !keycaps.isEmpty { height += 14 + 44 }
    return max(WelcomeStyle.collapsedHeight, height)
  }

  override func layout() {
    super.layout()
    // Lay out at the expanded geometry; the card's height only reveals it.
    let width = bounds.width
    number.frame = CGRect(x: 20, y: 26, width: 22, height: 19)
    icon.frame = CGRect(x: 18, y: 24, width: 22, height: 22)
    title.frame = CGRect(x: 47, y: 22, width: max(0, width - 47 - 16), height: 26)
    let textWidth = max(40, width - 47 - 20)
    let body = ceil((copy.detail as NSString).boundingRect(with: NSSize(width: textWidth, height: 1000),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: WelcomeStyle.bodyFont]).height)
    detail.frame = CGRect(x: 47, y: 54, width: textWidth, height: body + 2)
    var x: CGFloat = 47
    for cap in keycaps { cap.frame = CGRect(x: x, y: 54 + body + 14, width: 42, height: 44); x += 48 }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    progress.bounds = CGRect(x: 0, y: 0, width: width, height: WelcomeStyle.progressHeight)
    progress.position = CGPoint(x: 0, y: bounds.height - WelcomeStyle.progressHeight / 2)
    CATransaction.commit()
  }

  func setActive(_ active: Bool, animated: Bool) {
    guard active != isActive else { return }
    isActive = active; applyState(animated: animated)
  }

  private func applyState(animated: Bool) {
    let shows: CGFloat = isActive ? 1 : 0
    for view in [detail] + keycaps as [NSView] {
      let from = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
      // alphaValue is the model value AppKit keeps; the spring runs on the layer.
      view.alphaValue = shows
      if animated, let layer = view.layer {
        let fade = WelcomeStyle.spring("opacity")
        fade.fromValue = from; fade.toValue = Float(shows)
        layer.add(fade, forKey: "fade")
      } else { view.layer?.removeAnimation(forKey: "fade") }
    }
    number.isHidden = isActive; icon.isHidden = !isActive
    title.textColor = WelcomeStyle.ink
    number.textColor = WelcomeStyle.secondary
    updateSurface()
  }

  private func updateSurface() {
    let fill = isActive ? WelcomeStyle.cardFill : (isHovered || keyboardFocused) ? WelcomeStyle.hoverFill : WelcomeStyle.collapsedFill
    layer?.backgroundColor = fill.cgColor
    layer?.borderColor = WelcomeStyle.cardBorder.cgColor
  }

  // MARK: Progress (one GPU animation per play; no timer)

  var progressAnimating: Bool { progress.animation(forKey: "progress") != nil }

  func startProgress(duration: Double, from offset: Double = 0) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    progress.isHidden = false
    progress.removeAnimation(forKey: "progress")
    progress.transform = CATransform3DIdentity
    let grow = CABasicAnimation(keyPath: "transform.scale.x")
    grow.fromValue = max(0.0001, offset / duration); grow.toValue = 1; grow.duration = max(0.05, duration - offset)
    grow.timingFunction = CAMediaTimingFunction(name: .linear)
    progress.add(grow, forKey: "progress")
    CATransaction.commit()
  }
  /// Freeze at the presented value (pause) or hide (step left).
  func stopProgress(hide: Bool) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if let presented = progress.presentation()?.transform, !hide { progress.transform = presented }
    progress.removeAnimation(forKey: "progress")
    if hide { progress.isHidden = true; progress.transform = CATransform3DIdentity }
    CATransaction.commit()
  }
  func finishProgress() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    progress.removeAnimation(forKey: "progress"); progress.transform = CATransform3DIdentity
    progress.isHidden = true
    CATransaction.commit()
  }

  // MARK: Input

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking, !trackingAreas.contains(where: { $0 === tracking }) { addTrackingArea(tracking) }
  }
  func resetHover() { isHovered = false; updateSurface() }
  override func viewDidHide() { super.viewDidHide(); resetHover() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { resetHover() } }
  override func mouseEntered(with event: NSEvent) { isHovered = true; updateSurface() }
  override func mouseExited(with event: NSEvent) { resetHover() }
  override func becomeFirstResponder() -> Bool {
    let event = NSApp.currentEvent
    keyboardFocused = event?.type == .keyDown && event?.keyCode == 48
    noteFocusRingMaskChanged(); updateSurface(); return true
  }
  override func resignFirstResponder() -> Bool { keyboardFocused = false; noteFocusRingMaskChanged(); updateSurface(); return true }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); press?() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 { press?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool { press?(); return true }
}

/// Our own keycap: a soft lavender cap with a deeper lower edge.
@MainActor
final class WelcomeKeycapView: NSView {
  private let glyph: String
  init(glyph: String) {
    self.glyph = glyph; super.init(frame: .zero); wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
    WelcomeStyle.keyShade.setFill(); outer.fill()
    let face = NSBezierPath(roundedRect: CGRect(x: 0.75, y: 0.75, width: bounds.width - 1.5, height: bounds.height - 4.5), xRadius: 8, yRadius: 8)
    WelcomeStyle.keyFill.setFill(); face.fill()
    WelcomeStyle.keyEdge.setStroke(); face.lineWidth = 1.5; face.stroke()
    let font = NSFont.systemFont(ofSize: 19, weight: .bold)
    let text = glyph as NSString
    let size = text.size(withAttributes: [.font: font])
    text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - 4 - size.height) / 2),
      withAttributes: [.font: font, .foregroundColor: WelcomeStyle.accent])
  }
}
