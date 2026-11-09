import AppKit
import QuartzCore
import OpenOnboarding

/// The dim window cannot activate or accept input and is always below its owner.
private final class OnboardingDimWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Return belongs to the setup primary action even when a choice has focus.
private final class OnboardingWindow: NSWindow {
  var setupPrimary: (@MainActor () -> Void)?
  var setupBack: (@MainActor () -> Void)?
  override func sendEvent(_ event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.type == .keyDown, modifiers.isEmpty, event.keyCode == 53, let setupBack {
      if !event.isARepeat { setupBack() }
      return
    }
    // NSButton consumes plain Return as focus traversal before key equivalents.
    // Keep the primary action at the native window entry point for every field.
    if event.type == .keyDown, modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76,
       let setupPrimary {
      if !event.isARepeat { setupPrimary() }
      return
    }
    super.sendEvent(event)
  }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
  let intro: IntroView
  let sound: IntroSound
  let replay: Bool
  var steps: OnboardingStepsController?
  private let dim: NSWindow
  private var started = false
  private var engineSettled = false
  private var startRequested = false
  private var measureFrames = false
  private var startObserver: CFRunLoopObserver?
  private let dimView = NSView()
  #if OPEN_AUTOMATION
  private var staticProof: [String: Any]?
  #endif
  private var closingForHandoff = false
  private var finishing = false
  private var nextContent: NSViewController?
  private var lifecycle: [Task<Void, Never>] = []
  private let residentBaseline: UInt64
  private var residentAtThree: Int64?
  private var residentAfterHandoff: Int64?
  #if OPEN_AUTOMATION
  private var screenObserver: (any NSObjectProtocol)?
  #endif
  var onHandoff: (@MainActor () -> Void)?
  var onRelease: (@MainActor ([String: Any], UInt64) -> Void)?

  init(options: LaunchOptions, replay: Bool) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("onboarding.window.create")
    defer { pacingRegion?.end() }
    #endif
    self.replay = replay
    residentBaseline = Self.residentBytes()
    let preparedSound = IntroSound(mode: IntroSound.Mode(rawValue: options.introSound) ?? .normal)
    preparedSound.prepare {}
    let screen = NSScreen.main ?? NSScreen.screens.first
    var size = OnboardingTokens.windowSize
    if let frame = screen?.frame, frame.width <= size.width && frame.height <= size.height {
      size = NSSize(width: max(1, frame.width-72), height: max(1, frame.height-72))
    }
    let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Open"; window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true; window.isRestorable = false
    window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
    window.backgroundColor = IntroColors.room; window.identifier = .init("onboarding")
    var useScreenBlend = true
    #if OPEN_AUTOMATION
    // Same App and scene, only these two render-server filters differ.
    useScreenBlend = ProcessInfo.processInfo.environment["OPEN_INTRO_NORMAL_BLEND"] != "1"
    #endif
    intro = IntroView(reduceMotion: options.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      scale: screen?.backingScaleFactor ?? 2, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
      useScreenBlend: useScreenBlend)
    intro.frame = NSRect(origin: .zero, size: size); intro.autoresizingMask = [.width, .height]
    window.contentView = intro
    window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
    sound = preparedSound
    #if OPEN_AUTOMATION
    let dimRegion = IntroPacingTrace.begin("onboarding.dim.create")
    #endif
    dim = OnboardingDimWindow(contentRect: screen?.frame ?? NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    dim.backgroundColor = .clear
    dimView.wantsLayer = true; dimView.layer?.backgroundColor = NSColor.black.cgColor
    dimView.layer?.opacity = 0; dim.contentView = dimView
    dim.isOpaque = false; dim.ignoresMouseEvents = true; dim.isRestorable = false
    dim.isReleasedWhenClosed = false; dim.tabbingMode = .disallowed
    dim.identifier = .init("onboarding-dim"); dim.setAccessibilityElement(false)
    super.init(window: window)
    window.delegate = self; window.center()
    window.addChildWindow(dim, ordered: .below)
    #if OPEN_AUTOMATION
    dimRegion?.end()
    screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          let region = IntroPacingTrace.begin("screen.reconfiguration.notification")
          defer { region?.end() }
          self?.updateDimFrame()
        }
      }
    #endif
    intro.onGetStarted = { [weak self] in self?.handoff() }
  }
  required init?(coder: NSCoder) { return nil }

  func windowDidMove(_ notification: Notification) { updateDimFrame() }
  func windowDidChangeScreen(_ notification: Notification) {
    #if OPEN_AUTOMATION
    let region = IntroPacingTrace.begin("onboarding.window.screenChanged")
    defer { region?.end() }
    #endif
    updateDimFrame()
  }
  #if OPEN_AUTOMATION
  func windowDidChangeBackingProperties(_ notification: Notification) {
    let region = IntroPacingTrace.begin("onboarding.window.backingChanged")
    defer { region?.end() }
    updateDimFrame()
  }
  #endif
  private func updateDimFrame() {
    #if OPEN_AUTOMATION
    let region = IntroPacingTrace.begin("onboarding.dim.updateFrame")
    defer { region?.end() }
    #endif
    if let screen = window?.screen { dim.setFrame(screen.frame, display: false) }
  }
  isolated deinit {
    lifecycle.forEach { $0.cancel() }
    if let startObserver { CFRunLoopObserverInvalidate(startObserver) }
    #if OPEN_AUTOMATION
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    #endif
  }

  func showIntro(measureFrames: Bool, engineReady: Bool) {
    #if OPEN_AUTOMATION
    let region = IntroPacingTrace.begin("onboarding.window.show")
    defer { region?.end() }
    #endif
    guard let window else { return }
    dim.orderFront(nil); showWindow(nil); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(intro)
    guard !started else { return }; started = true
    self.measureFrames = measureFrames
    intro.onFirstPresentation = { [weak self] in self?.beginWhenReady() }
    intro.observeRoomPresentation()
    window.displayIfNeeded()
    if engineReady { engineDidBecomeReady() }
  }

  /// This observer runs only in the engine's native message loop, after its
  /// first sources and before-waiting work return. The room stays static.
  func engineDidBecomeReady() {
    guard startObserver == nil, !engineSettled else { return }
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.startObserver = nil; self.engineSettled = true; self.beginWhenReady()
      }
    }
    startObserver = observer
    if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
  }

  private func beginWhenReady() {
    guard engineSettled, intro.firstFrameHostTime != nil, !startRequested, !closingForHandoff else { return }
    startRequested = true
    sound.prepare { [weak self] in
      guard let self, !closingForHandoff, window?.isVisible == true else { return }
      sound.scheduleStart { [weak self] hostTime in
        guard let self, !closingForHandoff else { return }
        #if OPEN_AUTOMATION
        staticProof = ["hostTime": CACurrentMediaTime(), "scene": intro.staticSceneState,
          "dim": IntroView.staticLayerState(dim.contentView?.superview?.layer ?? dimView.layer), "musicStarted": sound.musicHasStarted,
          "audioStartHostTime": sound.audioStartHostTime as Any? ?? NSNull(),
          "scheduledPlayhead": sound.scheduledPlayhead, "scheduledDeviceLeadMS": sound.scheduledDeviceLead*1000]
        #endif
        lifecycle.append(Task { [weak self] in
          try? await Task.sleep(for: .seconds(max(0, hostTime-CACurrentMediaTime())), tolerance: .zero)
          guard !Task.isCancelled, let self, !closingForHandoff else { return }
          // No animation keys are installed before this transition. All visual
          // tracks and the dim overlay share this t=0 with scheduled playback.
          let start = CACurrentMediaTime()
          intro.start(at: start, measureFrames: measureFrames)
          CATransaction.begin(); CATransaction.setDisableActions(true)
          dimView.layer?.opacity = 0.85
          let fade = CABasicAnimation(keyPath: "opacity")
          fade.fromValue = 0; fade.toValue = 0.85; fade.beginTime = start
          fade.duration = IntroTimeline.beat(intro.reduceMotion ? "reduceFade" : "dim").end
          fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          dimView.layer?.add(fade, forKey: "intro-dim")
          CATransaction.commit()
          lifecycle.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(IntroTimeline.beat("measureMemory").start))
            guard !Task.isCancelled, let self else { return }
            residentAtThree = Int64(Self.residentBytes())-Int64(residentBaseline)
          })
        })
      }
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
    (window as? OnboardingWindow)?.setupPrimary = { [weak content] in
      (content as? OnboardingStepsController)?.performPrimaryAction()
    }
    (window as? OnboardingWindow)?.setupBack = { [weak content] in
      (content as? OnboardingStepsController)?.back()
    }
    (content as? OnboardingStepsController)?.didAttach()
  }
  func hidePreparedBrowser(_ browser: NSWindow) {
    browser.alphaValue = 0
    browser.order(.below, relativeTo: dim.windowNumber)
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
    let dimFade = CABasicAnimation(keyPath: "opacity")
    dimFade.fromValue = dimView.layer?.presentation()?.opacity ?? 0.85; dimFade.toValue = 0
    dimFade.duration = duration; dimFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dimView.layer?.opacity = 0; dimView.layer?.add(dimFade, forKey: "finish-dim")
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
    closingForHandoff = true
    onHandoff = nil
    finish()
    // Deferred: this delegate may be retained only by the window it closes.
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(intro.reduceMotion ? 0.3:2.5))
      NSApp.terminate(nil)
    }
    return false
  }
  func stop() { if let startObserver { CFRunLoopObserverInvalidate(startObserver); self.startObserver = nil }; lifecycle.forEach { $0.cancel() }; lifecycle.removeAll(); intro.stop(); sound.stop(); dim.close() }
  var state: [String: Any] {
    var state = intro.state
    state["active"] = window?.isVisible == true
    if let steps { state.merge(steps.state) { _, new in new } }
    state["screen"] = finishing ? "handoff" : steps?.step.rawValue ?? "intro"
    state["sound"] = sound.state; state["replay"] = replay
    state["window"] = window?.windowNumber ?? 0
    state["frameSize"] = [window?.frame.width ?? 0, window?.frame.height ?? 0]
    state["dim"] = ["exists": dim.isVisible, "alpha": dimView.layer?.presentation()?.opacity ?? dimView.layer?.opacity ?? 0, "ignoresMouseEvents": dim.ignoresMouseEvents, "child": dim.parent === window]
    #if OPEN_AUTOMATION
    state["preAnimationStatic"] = staticProof as Any? ?? NSNull()
    if measureFrames {
      state["currentSceneLayers"] = intro.staticSceneState
      state["currentDimLayers"] = IntroView.staticLayerState(dim.contentView?.superview?.layer ?? dimView.layer)
    }
    #endif
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
