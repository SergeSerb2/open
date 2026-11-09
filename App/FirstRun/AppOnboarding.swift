import AppKit
import QuartzCore
import OpenOnboarding

extension AppDelegate {
  /// First-run only. No scene or window exists while engine.start blocks.
  /// Returning launches never enter this preparation path.
  private func prepareOnboardingSound() {
    guard preparedOnboardingSound == nil else { return }
    #if OPEN_AUTOMATION
    if options.measureIntroFrames, IntroPacingTrace.current == nil { IntroPacingTrace.current = IntroPacingTrace() }
    if onboardingStartup.isEmpty {
      onboardingStartup["launchHostTime"] = CACurrentMediaTime()-LaunchTiming.shared.elapsedMilliseconds/1000
    }
    #endif
    let sound = IntroSound(mode: IntroSound.Mode(rawValue: options.introSound) ?? .normal)
    sound.prepare(); preparedOnboardingSound = sound
  }

  /// This is the only production entrance into OpenOnboarding. Returning and
  /// skip-first-run launches do not initialize a scene, resource or player.
  func showOnboarding(replay: Bool) {
    if let controller = onboardingWindowController, controller.window?.isVisible == true {
      controller.showWindow(nil); return
    }
    guard replay || !onboardingHandedOff else { return }
    prepareOnboardingSound()
    guard engineReady else { return }
    if isFirstRun && !firstRunSaved && !onboardingEngineSettled {
      guard onboardingStartObserver == nil else { return }
      let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { [weak self] _, _ in
        MainActor.assumeIsolated {
          guard let self, !self.terminationRequested else { return }
          self.onboardingStartObserver = nil; self.onboardingEngineSettled = true
          #if OPEN_AUTOMATION
          self.onboardingStartup["engineSettledHostTime"] = CACurrentMediaTime()
          self.onboardingStartup["windowsBeforeEngineSettled"] = NSApp.windows.filter { $0.isVisible }.count
          #endif
          self.showOnboarding(replay: replay)
        }
      }
      onboardingStartObserver = observer
      if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
      return
    }
    onboardingWindowController?.stop()
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("onboarding.controller.create")
    defer { pacingRegion?.end() }
    onboardingStartup["windowCreationHostTime"] = CACurrentMediaTime()
    #endif
    guard let sound = preparedOnboardingSound else { return }
    preparedOnboardingSound = nil
    let controller = OnboardingWindowController(options: options, replay: replay, preparedSound: sound)
    #if OPEN_AUTOMATION
    controller.onFirstFrame = { [weak self] in self?.startAutomationIfNeeded() }
    #endif
    onboardingWindowController = controller; onboardingActivated = true; onboardingReceipt = nil
    controller.onHandoff = { [weak self] in
      guard let self else { return }
      onboardingHandedOff = true
      showFirstRunSteps(replay: replay)
    }
    controller.onRelease = { [weak self, weak controller] receipt, baseline in
      guard let self, let controller, onboardingWindowController === controller else { return }
      onboardingReceipt = receipt
      onboardingWindowController?.stop(); onboardingWindowController = nil
      // Drop the window, bitmap backing and scene before the post-hand-off
      // resident read. Retain only a small value receipt for automation.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(100))
        var final = receipt
        final["residentDeltaAfterHandoff"] = Int64(OnboardingWindowController.residentBytes())-Int64(baseline)
        self?.onboardingReceipt = final
      }
    }
    controller.showIntro(measureFrames: options.measureIntroFrames)
  }
  func showFirstRunSteps(replay: Bool = false) {
    guard let onboarding = onboardingWindowController, let window = onboarding.window else { return }
    let actions = AppFirstRunActions(app: self)
    let model = OpenSettings.FirstRunViewModel(settings: settingsPresenter.settings, actions: actions, directory: options.arcDirectory)
    let holder = FirstRunWindowController(model: model, hostedIn: window)
    if !replay { firstRunWindowController = holder; lastFirstRunStep = "welcome" }
    let steps = OnboardingStepsController(app: self, firstRun: model, replay: replay, reduceMotion: onboarding.intro.reduceMotion)
    onboarding.steps = steps
    onboarding.show(content: steps)
    window.displayIfNeeded()
    if !replay { holder.startProbeAfterDisplay() }
  }
}

import OpenSettings
