import AppKit
import QuartzCore
import OpenOnboarding
import OpenModel

/// Finite demonstrations composed from the same native sidebar, rows, command
/// bar, Space pager and split divider as the browser. No engine or frame timer.
@MainActor
final class WelcomeIllustrationView: NSView {
  let kind: Int
  private let miniature = OnboardingMiniature()
  private var neighbor: OnboardingMiniature?
  private(set) var running = false
  var animationCount: Int {
    miniature.animationCount + (neighbor?.animationCount ?? 0)
      + (miniature.layer?.animationKeys()?.count ?? 0) + (neighbor?.layer?.animationKeys()?.count ?? 0)
  }
  #if OPEN_AUTOMATION
  var drawnLabels: [String] { drawnLabelFrames.map(\.0) }
  var drawnLabelFrames: [(String,CGRect)] { miniature.demoLabelFrames(in: layer) }
  var miniatureState: [String:Any]? {
    var state = miniature.demoState
    state["kind"] = kind; state["realSplitDivider"] = kind == 3
    state["realLiftedRow"] = kind == 1 || kind == 3
    state["realSpacePager"] = kind == 2; state["windows"] = neighbor == nil ? 1:2
    state["artWidthFraction"] = 1.0
    return state
  }
  var paintColors: [String:NSColor] { [:] }
  var sceneScale: [CGFloat] { [miniature.renderedScale,miniature.renderedScale] }
  #endif
  init(kind: Int) {
    self.kind = kind; super.init(frame: .zero); wantsLayer = true; layer?.masksToBounds = true
    miniature.demoKind = kind; addSubview(miniature)
    if kind == 2 {
      let other = OnboardingMiniature(); other.demoKind = 2
      other.apply(theme: OnboardingMiniature.demoTheme(kind: 1),dark: true)
      other.finishDemo(); neighbor = other; addSubview(other)
    }
    applyTheme(nil,dark: false); finish()
    setAccessibilityElement(false)
  }
  @available(*,unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
    miniature.frame = bounds
    neighbor?.frame = bounds.offsetBy(dx: bounds.width,dy: 0)
    CATransaction.commit()
  }
  func applyTheme(_ theme: SpaceTheme?,dark: Bool) {
    miniature.apply(theme: kind == 0 ? theme:OnboardingMiniature.demoTheme(kind: kind),dark: kind == 0 ? dark:true)
  }
  func apply(background: NSColor,sidebarTint: NSColor,dark: Bool) {
    layer?.backgroundColor = OnboardingTokens.Room.white.withAlphaComponent(0.025).cgColor
  }
  func play(duration: Double) {
    freeze(); running = true
    CATransaction.begin(); CATransaction.setDisableActions(true)
    miniature.layer?.transform = CATransform3DIdentity; neighbor?.layer?.transform = CATransform3DIdentity
    CATransaction.commit()
    neighbor?.isHidden = false
    miniature.playDemo(duration: duration)
    if let neighbor {
      neighbor.playDemo(duration: duration)
      for (view,sign) in [(miniature,CGFloat(-1)),(neighbor,CGFloat(-1))] {
        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = [0,0,sign*bounds.width*0.62,0]; slide.keyTimes = [0,0.25,0.65,1]
        slide.duration = duration; slide.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),count: 3)
        view.layer?.add(slide,forKey: "space-window-swipe")
      }
    }
  }
  func freeze() {
    miniature.freezeDemo(); neighbor?.freezeDemo()
    for view in [miniature,neighbor].compactMap({ $0 }) {
      if let value = view.layer?.presentation()?.transform {
        CATransaction.begin(); CATransaction.setDisableActions(true); view.layer?.transform = value; CATransaction.commit()
      }
      view.layer?.removeAllAnimations()
    }
    running = false
  }
  func finish() {
    miniature.finishDemo(); neighbor?.finishDemo()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    miniature.layer?.transform = CATransform3DIdentity; neighbor?.layer?.transform = CATransform3DIdentity
    miniature.layer?.removeAllAnimations(); neighbor?.layer?.removeAllAnimations(); CATransaction.commit()
    neighbor?.isHidden = true
    running = false
  }
}
