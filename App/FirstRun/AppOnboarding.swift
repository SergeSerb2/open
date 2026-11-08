import AppKit

extension AppDelegate {
  /// This is the only production entrance into OpenOnboarding. Returning and
  /// skip-first-run launches do not initialize a scene, resource or player.
  func showOnboarding(replay: Bool) {
    if let controller = onboardingWindowController, controller.window?.isVisible == true {
      controller.showWindow(nil); return
    }
    guard replay || !onboardingHandedOff else { return }
    onboardingWindowController?.stop()
    let controller = OnboardingWindowController(options: options, replay: replay)
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
