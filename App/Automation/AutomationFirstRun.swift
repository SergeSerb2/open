#if OPEN_AUTOMATION
import AppKit
import OpenSettings
import Vision

extension AutomationController {
  /// One surface for the real flow and the Settings wizard which shares its runner.
  func runFirstRun(_ args: [String: Any]) async throws -> [String: Any] {
    let action = args["action"] as? String
    guard action.map({ $0.utf8.count <= 32 }) ?? true,
      (args["directory"] as? String).map({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
    else { throw Failure(message: "first-run argument exceeds limit") }
    let flow = app.firstRunWindowController?.model
    if let action {
      if action.hasPrefix("settings-") {
        guard flow == nil else { throw Failure(message: "finish first run before opening Settings") }
        let settings = app.settingsPresenter.settings
        if action == "settings-import" {
          app.settingsPresenter.show(pane: .general); settings.showsImport = true
        }
        let wizard = settings.importWizard
        switch action {
        case "settings-import":
          guard let path = args["directory"] as? String else { throw Failure(message: "missing directory") }
          await wizard.choose(directory: URL(fileURLWithPath: path, isDirectory: true))
        case "settings-next":
          guard wizard.step == .choose else { throw Failure(message: "wizard is not on Choose") }
          let deadline = ContinuousClock.now.advanced(by: .seconds(10))
          while wizard.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
          wizard.review()
        case "settings-run":
          guard firstRunActionTask == nil, wizard.step == .review else { throw Failure(message: "wizard is not ready") }
          firstRunActionTask = Task { @MainActor [weak self] in
            await wizard.beginImport(); self?.firstRunActionTask = nil
          }
        case "settings-done":
          guard wizard.step == .report, !wizard.busy else { throw Failure(message: "wizard is not on Report") }
          wizard.finish()
        default: throw Failure(message: "unknown first-run action")
        }
      } else {
        guard let flow else { throw Failure(message: "first run is not active") }
        guard !flow.busy || ["focus", "inspect"].contains(action) else { throw Failure(message: "import is busy") }
        switch action {
        case "focus":
          guard let window = app.firstRunWindowController?.window else { throw Failure(message: "no first-run window") }
          try await activateForInput(window)
        case "inspect": break
        case "select":
          guard flow.step == .importChoices else { throw Failure(message: "not on Import") }
          if let on = args["spaces"] as? Bool { flow.includeSpacesAndTabs = on }
          if let on = args["archive"] as? Bool { flow.includeArchive = on }
          if let on = args["history"] as? Bool { flow.includeHistory = on }
        case "import":
          guard flow.step == .welcome else { throw Failure(message: "not on Welcome") }; flow.showImport()
        case "fresh":
          guard [.welcome, .importChoices, .failed].contains(flow.step) else { throw Failure(message: "Start Fresh is unavailable") }; flow.startFresh()
        case "back":
          guard [.importChoices, .failed].contains(flow.step) else { throw Failure(message: "Back is unavailable") }
          flow.step = flow.step == .importChoices ? .welcome : .importChoices
        case "notnow":
          guard [.importChoices, .defaultBrowser].contains(flow.step) else { throw Failure(message: "Not Now is unavailable") }
          if flow.step == .importChoices { flow.skipImport() } else { flow.finish() }
        case "finish": guard flow.step == .defaultBrowser else { throw Failure(message: "not on default-browser step") }; flow.finish()
        case "continue", "retry":
          if flow.step == .report {
            if flow.errorText == FirstRunViewModel.importedSaveError { app.finishFirstRun(imported: true) }
            else { flow.enterDefaultBrowser() }
          } else {
            guard firstRunActionTask == nil, [.importChoices, .failed].contains(flow.step) else { throw Failure(message: "import is not ready") }
            firstRunActionTask = Task { @MainActor [weak self] in
              await flow.continueImport(); self?.firstRunActionTask = nil
            }
          }
        case "choose-dir":
          guard flow.step == .importChoices, let path = args["directory"] as? String else { throw Failure(message: "missing directory or not on Import") }
          await flow.choose(directory: URL(fileURLWithPath: path, isDirectory: true))
        default: throw Failure(message: "unknown first-run action")
        }
      }
    }
    let current = app.firstRunWindowController?.model
    var state: [String: Any] = ["active": app.firstRunWindowController?.window?.isVisible == true,
      "step": current?.step.rawValue ?? app.lastFirstRunStep,
      "completed": UserDefaults.standard.bool(forKey: "open.firstRun.completed")]
    if let current {
      state["welcome"] = current.welcomeStatus
      state["probeReady"] = current.probe != nil
      state["counts"] = current.probe?.settingsCounts ?? [:]
      state["sidebarFound"] = current.probe?.sidebarFound ?? false
      state["secretsEnabled"] = current.wizard.canImportPasswordsAndCookies
      state["error"] = current.errorText ?? ""
      state["window"] = app.firstRunWindowController?.window?.windowNumber ?? 0
      state["defaultBrowser"] = current.isDefaultBrowser
      state["defaultAttempted"] = current.defaultWasAttempted
      state["outcome"] = current.outcome?.counts ?? [:]
      state["failures"] = current.outcome?.failures ?? [:]
      if let window = app.firstRunWindowController?.window {
        state["frameSize"] = [window.frame.width, window.frame.height]
        state["key"] = window.isKeyWindow
        state["trafficLights"] = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { kind -> [CGFloat]? in
          guard let button = window.standardWindowButton(kind) else { return nil }
          let r = button.convert(button.bounds, to: nil)
          return [r.minX, window.frame.height - r.maxY, r.width, r.height]
        }
        if action == "inspect" { state["renderedText"] = try await firstRunRenderedText(window) }
      }
    }
    if action?.hasPrefix("settings-") == true || current == nil {
      // Reading normal launch status must keep Settings lazy.
      if action?.hasPrefix("settings-") == true || app.importRunner.lastOutcome != nil {
        let wizard = app.settingsPresenter.settings.importWizard
        state["settingsStep"] = wizard.step.rawValue
        state["settingsOutcome"] = wizard.outcome?.counts ?? [:]
        state["settingsError"] = wizard.outcome?.errorText ?? ""
      }
    }
    return state
  }

  /// Inspect pixels from our own native window. SwiftUI's in-process AX tree
  /// can be empty unless an outside assistive client has activated it. OCR
  /// proves the displayed copy and its geometry without such a client or input.
  private func firstRunRenderedText(_ window: NSWindow) async throws -> [[String: Any]] {
    try await Task.sleep(for: .milliseconds(250)) // allow the normal step fade to finish
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("open-firstrun-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await WindowSnapshot.capture(window, to: url)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(url: url).perform([request])
    return (request.results ?? []).prefix(128).compactMap { observation in
      guard let line = observation.topCandidates(1).first else { return nil }
      let r = observation.boundingBox
      return ["text": String(line.string.prefix(512)),
        "frame": [r.minX * window.frame.width, (1 - r.maxY) * window.frame.height,
                  r.width * window.frame.width, r.height * window.frame.height]]
    }
  }
}
#endif
