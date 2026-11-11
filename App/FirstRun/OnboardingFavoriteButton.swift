import AppKit
import QuartzCore

/// The tile's layout never moves. Layers outside its bounds own focus and badge.
@MainActor final class OnboardingFavoriteButton: OnboardingButton {
  let iconView = OnboardingSiteIconView(frame: NSRect(x: 28, y: 12, width: 32, height: 32))
  private let surface = CALayer()
  private let selection = CALayer()
  private let focus = CALayer()
  private let badge = OnboardingFavoriteBadge(frame: .zero)
  private let label = OnboardingFavoriteLabel(frame: .zero)
  private var hovered = false
  var selected = false {
    didSet {
      setAccessibilityValue(selected ? 1:0)
      guard selected != oldValue else { return }
      updateSurface(animated: true); updateBadge(animated: true); needsDisplay = true
    }
  }
  override var interactionHoverScale: Double { 1 }
  override var interactionPressedScale: Double { 0.97 }
  override var interactionDuration: Double? { 0.1 }
  override var wantsDefaultClipping: Bool { false }
  private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
  override init(_ title: String, primary: Bool, reduceMotion: Bool, action: @escaping @MainActor () -> Void) {
    super.init(title, primary: primary, reduceMotion: reduceMotion, action: action)
    focusRingType = .none; layer?.masksToBounds = false
    for item in [surface, selection, focus] {
      item.cornerCurve = .continuous; item.masksToBounds = false; layer?.addSublayer(item)
    }
    surface.cornerRadius = 14; surface.borderWidth = 1
    selection.cornerRadius = 13; selection.borderWidth = 2
    focus.cornerRadius = 19; focus.borderWidth = 3; focus.backgroundColor = NSColor.clear.cgColor
    label.text = title
    addSubview(iconView); addSubview(label); addSubview(badge); badge.layer?.opacity = 0
    updateSurface(animated: false)
  }
  required init?(coder: NSCoder) { nil }
  override func interactionHoverChanged(_ hovered: Bool) { self.hovered = hovered; updateSurface(animated: true) }
  override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted }
  override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance(); updateSurface(animated: false); badge.needsDisplay = true; needsDisplay = true
  }
  func applyIcon(_ tile: OnboardingFavicons.Tile, animated: Bool) {
    iconView.apply(name: title, tile: tile, animated: animated, reduceMotion: reduceMotion)
  }
  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    surface.frame = bounds; selection.frame = bounds.insetBy(dx: 1, dy: 1)
    // Inner edge is 3 pt outside the tile; the stroke extends another 3 pt.
    focus.frame = bounds.insetBy(dx: -6, dy: -6)
    surface.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    CATransaction.commit()
    iconView.frame = NSRect(x: bounds.midX-16, y: 12, width: 32, height: 32)
    label.frame = NSRect(x: 2, y: 50, width: 84, height: 26)
    // 18 pt disc + 2 pt knockout, centered 4 pt outside the top-right corner.
    badge.frame = NSRect(x: bounds.maxX-7, y: -15, width: 22, height: 22)
    updateSurface(animated: false)
  }
  private func updateSurface(animated: Bool) {
    let blue = Self.primaryBlue
    let base = dark ? NSColor(srgbRed: 46/255, green: 46/255, blue: 51/255, alpha: 1)
      : NSColor(srgbRed: 244/255, green: 244/255, blue: 246/255, alpha: 1)
    let fill: NSColor
    if selected { fill = (dark ? base:NSColor.white).blended(withFraction: dark ? 0.20:0.09, of: blue) ?? base }
    else if hovered {
      fill = dark ? base.blended(withFraction: 0.06, of: .white) ?? base
        : NSColor(srgbRed: 236/255, green: 236/255, blue: 240/255, alpha: 1)
    } else { fill = base }
    CATransaction.begin(); CATransaction.setDisableActions(!animated || reduceMotion)
    CATransaction.setAnimationDuration(0.12); CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    surface.backgroundColor = fill.cgColor
    surface.borderColor = (dark ? NSColor.white.withAlphaComponent(0.09):NSColor.black.withAlphaComponent(0.06)).cgColor
    surface.shadowColor = (selected ? blue:NSColor.black).cgColor; surface.shadowOpacity = selected ? 0.22:(dark ? 0:0.05)
    surface.shadowRadius = selected ? 9:8; surface.shadowOffset = CGSize(width: 0, height: selected ? 6:1)
    selection.borderColor = blue.cgColor
    selection.opacity = selected ? 1:0
    focus.borderColor = blue.withAlphaComponent(0.45).cgColor
    focus.opacity = window?.firstResponder === self ? 1:0
    CATransaction.commit()
    if label.selected != selected { label.selected = selected; label.needsDisplay = true }
  }
  private func updateBadge(animated: Bool) {
    let from = badge.layer?.presentation()?.opacity ?? (selected ? 0:1)
    CATransaction.begin(); CATransaction.setDisableActions(true); badge.layer?.opacity = selected ? 1:0; CATransaction.commit()
    guard animated else { return }
    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = from; fade.toValue = selected ? 1:0
    fade.duration = reduceMotion ? 0.18:0.2; badge.layer?.add(fade, forKey: "selection-fade")
    guard selected, !reduceMotion else { return }
    let spring = CASpringAnimation(keyPath: "transform.scale")
    spring.fromValue = badge.layer?.animation(forKey: "selection-spring") == nil ? 0.5 : badge.layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 0.5
    spring.toValue = 1
    spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.28, 2); spring.damping = 2 * 0.72 * sqrt(spring.stiffness)
    spring.duration = spring.settlingDuration; badge.layer?.add(spring, forKey: "selection-spring")
  }
  var styleState: [String: Any] {
    ["tileSize": [88,84], "radius": 14, "iconFrame": [28,12,32,32], "labelFrame": [2,50,84,26],
     "focusOutset": 3, "focusWidth": 3, "focusRadius": 19, "badgeDiameter": 18, "badgeOffset": 4,
     "badgeSpringResponse": 0.28, "badgeSpringDamping": 0.72, "badgeScales": !reduceMotion,
     "pressedScale": 0.97, "pressedDuration": 0.1, "hoverDuration": 0.12, "selected": selected]
  }
  override func draw(_ dirtyRect: NSRect) { updateSurface(animated: false) }
}

@MainActor private final class OnboardingFavoriteLabel: NSView {
  var text = ""
  var selected = false
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold:.medium),
      .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph, .kern: -0.1]
    let text = text as NSString
    let height = min(26, ceil(text.boundingRect(with: NSSize(width: 84, height: 26), options: [.usesLineFragmentOrigin], attributes: attributes).height))
    text.draw(in: NSRect(x: 0, y: (26-height)/2, width: 84, height: height), withAttributes: attributes)
  }
}

@MainActor private final class OnboardingFavoriteBadge: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.18
    layer?.shadowRadius = 6; layer?.shadowOffset = CGSize(width: 0, height: 1)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    (dark ? NSColor(white: 30/255, alpha: 1):.white).setFill()
    NSBezierPath(ovalIn: bounds).fill()
    OnboardingButton.primaryBlue.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
    if let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?
      .withSymbolConfiguration(.init(paletteColors: [.white])) {
      let size = symbol.size
      symbol.draw(in: NSRect(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2, width: size.width, height: size.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
  }
}
