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
      if replay {
        onboardingWindowController?.window?.orderOut(nil)
        frontWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.finish()
      }
      else {
        onboardingHandedOff = true
        showFirstRunSteps()
      }
    }
    controller.onRelease = { [weak self, weak controller] receipt, baseline in
      guard let self, let controller, onboardingWindowController === controller else { return }
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
  func showFirstRunSteps() {
    // Use Section 7 unchanged in its existing window for v1. Its first probe
    // starts after this display, since App/main's initial display was the intro.
    let actions = AppFirstRunActions(app: self)
    let viewModel = OpenSettings.FirstRunViewModel(settings: settingsPresenter.settings, actions: actions, directory: options.arcDirectory)
    let controller = FirstRunWindowController(model: viewModel)
    controller.onClose = { [weak self] in self?.onboardingWindowController?.finish() }
    firstRunWindowController = controller; lastFirstRunStep = "welcome"
    controller.showWindow(nil); controller.window?.displayIfNeeded(); controller.startProbeAfterDisplay()
    if let window = controller.window { onboardingWindowController?.handoff(to: window) }
  }
}

import OpenSettings
