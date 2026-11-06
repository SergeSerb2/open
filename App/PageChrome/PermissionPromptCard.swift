import AppKit
import QuartzCore
import OpenDesign

/// Little Open's content card. Geometry and curves are lead-specified guesses;
/// the 0.1 s show/hide durations are evidenced in page-chrome §3.
@MainActor
final class PermissionPromptCard: NSView {
  let prompt: PermissionPromptView
  private var height: NSLayoutConstraint?
  private(set) var animationDuration: TimeInterval = 0
  override var wantsDefaultClipping: Bool { false }
  init(prompt: PermissionPromptView, root: NSView) {
    self.prompt = prompt
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = false
    layer?.shadowRadius = 5
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    translatesAutoresizingMaskIntoConstraints = false
    prompt.removeFromSuperview(); addSubview(prompt)
    root.addSubview(self, positioned: .above, relativeTo: nil)
    let preferredWidth = widthAnchor.constraint(equalToConstant: 320); preferredWidth.priority = .defaultHigh
    let height = heightAnchor.constraint(equalToConstant: prompt.preferredHeight(width: 320)); self.height = height
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
      trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10), preferredWidth, height])
    root.layoutSubtreeIfNeeded(); applyColors()
    fade(to: 1)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
  private func applyColors() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    layer?.shadowColor = NSColor(displayP3Red: 0.082, green: 0.110, blue: 0.196, alpha: 1).cgColor
    layer?.shadowOpacity = dark ? 0.80 : 0.30
  }
  override func layout() {
    super.layout()
    height?.constant = prompt.preferredHeight(width: bounds.width)
    prompt.frame = bounds; prompt.needsLayout = true
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
  }
  private func fade(to opacity: CGFloat, completion: (@MainActor () -> Void)? = nil) {
    let current = layer?.presentation().map { CGFloat($0.opacity) } ?? alphaValue
    layer?.removeAllAnimations()
    alphaValue = opacity == 1 ? 0 : current
    animationDuration = Motion.reducesMotion ? 0 : 0.1
    guard animationDuration > 0 else { alphaValue = opacity; completion?(); return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animationDuration
      context.timingFunction = CAMediaTimingFunction(name: opacity == 1 ? .easeOut : .easeIn)
      animator().alphaValue = opacity
    } completionHandler: { MainActor.assumeIsolated { completion?() } }
  }
  func dismiss(animated: Bool) {
    if animated { fade(to: 0) { [weak self] in self?.removeFromSuperview() } }
    else { layer?.removeAllAnimations(); removeFromSuperview() }
  }
}
