import AppKit
import QuartzCore
import OpenOnboarding

/// The dim window cannot activate or accept input and is always below its owner.
private final class OnboardingDimWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
  let intro: IntroView
  let sound: IntroSound
  let replay: Bool
  var steps: OnboardingStepsController?
  private let dim: NSWindow
  private var started = false
  private var closingForHandoff = false
  private var finishing = false
  private var nextContent: NSViewController?
  private var lifecycle: [Task<Void, Never>] = []
  private let residentBaseline: UInt64
  private var residentAtThree: Int64?
  private var residentAfterHandoff: Int64?
  var onHandoff: (@MainActor () -> Void)?
  var onRelease: (@MainActor ([String: Any], UInt64) -> Void)?

  init(options: LaunchOptions, replay: Bool) {
    self.replay = replay
    residentBaseline = Self.residentBytes()
    let preparedSound = IntroSound(mode: IntroSound.Mode(rawValue: options.introSound) ?? .normal)
    preparedSound.prepare {}
    let screen = NSScreen.main ?? NSScreen.screens.first
    var size = OnboardingTokens.windowSize
    if let frame = screen?.frame, frame.width <= size.width && frame.height <= size.height {
      size = NSSize(width: max(1, frame.width-72), height: max(1, frame.height-72))
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Open"; window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true; window.isRestorable = false
    window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
    window.backgroundColor = IntroColors.room; window.identifier = .init("onboarding")
    intro = IntroView(reduceMotion: options.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      scale: screen?.backingScaleFactor ?? 2, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    intro.frame = NSRect(origin: .zero, size: size); intro.autoresizingMask = [.width, .height]
    window.contentView = intro
    window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
    sound = preparedSound
    dim = OnboardingDimWindow(contentRect: screen?.frame ?? NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    dim.backgroundColor = .black; dim.alphaValue = intro.reduceMotion ? 0.85 : 0
    dim.isOpaque = false; dim.ignoresMouseEvents = true; dim.isRestorable = false
    dim.isReleasedWhenClosed = false; dim.tabbingMode = .disallowed
    dim.identifier = .init("onboarding-dim"); dim.setAccessibilityElement(false)
    super.init(window: window)
    window.delegate = self; window.center()
    window.addChildWindow(dim, ordered: .below)
    intro.onGetStarted = { [weak self] in self?.handoff() }
  }
  required init?(coder: NSCoder) { return nil }

  func windowDidMove(_ notification: Notification) { updateDimFrame() }
  func windowDidChangeScreen(_ notification: Notification) { updateDimFrame() }
  private func updateDimFrame() {
    if let screen = window?.screen { dim.setFrame(screen.frame, display: false) }
  }
  isolated deinit { lifecycle.forEach { $0.cancel() } }

  func showIntro(measureFrames: Bool) {
    guard let window else { return }
    dim.orderFront(nil); showWindow(nil); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(intro)
    guard !started else { return }; started = true
    window.displayIfNeeded()
    sound.prepare { [weak self] in
      guard let self, !closingForHandoff, window.isVisible else { return }
      let start = CACurrentMediaTime()+IntroTimeline.beat("syncLead").end
      sound.start(animationHostTime: start)
      intro.start(at: start, measureFrames: measureFrames)
      if !intro.reduceMotion {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = IntroTimeline.beat("dim").end
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          dim.animator().alphaValue = 0.85
        }
      }
      lifecycle.append(Task { [weak self] in
        try? await Task.sleep(for: .seconds(IntroTimeline.beat("measureMemory").start+IntroTimeline.beat("syncLead").end))
        guard !Task.isCancelled, let self else { return }
        residentAtThree = Int64(Self.residentBytes())-Int64(residentBaseline)
      })
    }
  }
  func handoff() {
    guard !closingForHandoff else { return }; closingForHandoff = true
    intro.fadeForHandoff()
    lifecycle.append(Task { [weak self] in
      try? await Task.sleep(for: .seconds(IntroTimeline.beat("handoff").end))
      guard !Task.isCancelled, let self else { return }
      onHandoff?()
    })
  }
  /// Stable seam for setup/basics: replace only the foreground content. The
  /// original room, dim window and sound keep their current clocks.
  func show(content: NSViewController) {
    nextContent?.view.removeFromSuperview(); nextContent = content
    intro.showBackgroundOnly()
    content.view.frame = intro.bounds; content.view.autoresizingMask = [.width, .height]
    intro.addSubview(content.view)
    window?.makeFirstResponder(content.view)
  }
  func finish() {
    guard !finishing else { return }; finishing = true
    sound.fadeOut()
    let reduced = intro.reduceMotion
    let duration = reduced ? 0.3 : 2.5
    dim.parent?.removeChildWindow(dim)
    if let browser = NSApp.keyWindow {
      dim.order(.below, relativeTo: browser.windowNumber)
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dim.animator().alphaValue = 0
    }
    if let window {
      if !reduced {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.4; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          window.animator().setFrameOrigin(NSPoint(x: window.frame.minX, y: window.frame.minY+24))
        }
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = reduced ? 0.3:0.6; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().alphaValue = 0
      }
    }
    lifecycle.append(Task { [weak self] in
      try? await Task.sleep(for: .seconds(reduced ? 0.3:0.6))
      guard !Task.isCancelled, let self else { return }; window?.orderOut(nil)
    })
    lifecycle.append(Task { [weak self] in
      try? await Task.sleep(for: .seconds(duration))
      guard !Task.isCancelled, let self else { return }
      intro.stop(); sound.stop(); dim.close(); close()
      var receipt = state; receipt["screen"] = "done"; receipt["active"] = false
      onRelease?(receipt, residentBaseline)
    })
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if finishing { return true }
    closingForHandoff = true; onHandoff = nil
    finish()
    // Deferred: this delegate may be retained only by the window it closes.
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(intro.reduceMotion ? 0.3:2.5))
      NSApp.terminate(nil)
    }
    return false
  }
  func stop() { lifecycle.forEach { $0.cancel() }; lifecycle.removeAll(); intro.stop(); sound.stop(); dim.close() }
  var state: [String: Any] {
    var state = intro.state
    state["active"] = window?.isVisible == true
    if let steps { state.merge(steps.state) { _, new in new } }
    state["screen"] = finishing ? "handoff" : steps?.step.rawValue ?? "intro"
    state["sound"] = sound.state; state["replay"] = replay
    state["window"] = window?.windowNumber ?? 0
    state["frameSize"] = [window?.frame.width ?? 0, window?.frame.height ?? 0]
    state["dim"] = ["exists": dim.isVisible, "alpha": dim.alphaValue, "ignoresMouseEvents": dim.ignoresMouseEvents, "child": dim.parent === window]
    state["residentDelta3Seconds"] = residentAtThree as Any? ?? NSNull()
    state["residentDeltaAfterHandoff"] = residentAfterHandoff as Any? ?? NSNull()
    return state
  }
  static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
  }
}
