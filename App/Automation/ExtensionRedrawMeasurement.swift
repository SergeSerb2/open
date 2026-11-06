#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenExtensionsUI

/// Short, explicitly requested display-frame measurement. The production UI
/// creates no display link; stop (or 120 display frames) removes every hook.
@MainActor
final class ExtensionRedrawMeasurement: NSObject {
  private var displayLink: CADisplayLink?
  private var buttons: [ExtensionActionButton]
  private var counts: [ObjectIdentifier: Int] = [:]
  private var frames = 0
  private var draws = 0
  private var maximum = 0
  init(strips: [ExtensionStripView]) {
    buttons = strips.flatMap(\.buttons).filter { !$0.isHiddenOrHasHiddenAncestor }
    super.init()
    for button in buttons {
      let key = ObjectIdentifier(button)
      button.onRedraw = { [weak self] in self?.draw(key) }
    }
    if let view = buttons.first {
      let link = view.displayLink(target: self, selector: #selector(frame(_:)))
      displayLink = link; link.add(to: .main, forMode: .common)
    }
  }
  @objc private func frame(_ link: CADisplayLink) {
    frames += 1; counts.removeAll(keepingCapacity: true)
    if frames >= 120 { stop() }
  }
  private func draw(_ key: ObjectIdentifier) {
    draws += 1; counts[key, default: 0] += 1
    maximum = max(maximum, counts[key, default: 0])
  }
  func stop() {
    displayLink?.invalidate(); displayLink = nil
    buttons.forEach { $0.onRedraw = nil }; buttons.removeAll()
  }
  var state: [String: Any] {
    ["frames": frames, "redraws": draws, "maxPerActionPerFrame": maximum, "running": displayLink != nil]
  }
}
#endif
