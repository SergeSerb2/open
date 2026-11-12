#if OPEN_AUTOMATION
import AppKit
import OpenSettings
import Vision

private struct FirstRunTextLine: Sendable {
  let text: String
  let frame: [Double]
}

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
        if action == "settings-import" || action == "settings-open-sources" {
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
        case "settings-select":
          let deadline = ContinuousClock.now.advanced(by: .seconds(10))
          while wizard.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
          guard wizard.step == .choose, !wizard.busy else { throw Failure(message: "wizard is not on Choose") }
          if let historyOnly = args["historyOnly"] as? Bool, historyOnly {
            wizard.plan.spaces = false; wizard.plan.tabs = false; wizard.plan.favorites = false
            wizard.plan.folders = false; wizard.plan.archive = false; wizard.plan.searchSettings = false
          }
          if let on = args["history"] as? Bool { wizard.plan.history = on }
        case "settings-passwords":
          // Copy reference on a capability-OFF build. It uses the real view
          // and real button guards and cannot grant consent or enable import.
          guard !wizard.busy, !wizard.canImportPasswordsAndCookies else { throw Failure(message: "Passwords copy reference requires capability OFF") }
          wizard.step = .consent
        case "settings-allow-passwords":
          guard !wizard.canImportPasswordsAndCookies else { throw Failure(message: "automation cannot grant real secrets consent") }
          await wizard.allowAndImportSecrets()
        case "settings-skip-passwords":
          await wizard.skipSecrets()
        case "settings-cancel-passwords":
          guard !wizard.busy else { throw Failure(message: "wizard is busy") }
          wizard.finish()
        case "settings-inspect": break
        case "settings-open-sources":
          // The real sheet's own task loads the catalog; await the same call.
          await wizard.loadSources()
        case "settings-source":
          guard wizard.step == .source, let id = args["id"] as? String, id.utf8.count <= 64 else { throw Failure(message: "wizard is not on Source") }
          wizard.selectedSourceID = id
          guard wizard.canContinueFromSource else { throw Failure(message: "source is not selectable") }
          await wizard.continueFromSource()
        case "settings-profile":
          guard wizard.step == .choose, let id = args["id"] as? String, id.utf8.count <= 255 else { throw Failure(message: "wizard is not on Choose") }
          await wizard.selectProfile(id)
        case "settings-browser-select":
          guard wizard.step == .choose, !wizard.plan.isArc, !wizard.busy else { throw Failure(message: "wizard is not on a browser Choose step") }
          if let on = args["bookmarks"] as? Bool { wizard.plan.bookmarks = on }
          if let on = args["openTabs"] as? Bool { wizard.plan.openTabs = on }
          if let on = args["history"] as? Bool { wizard.plan.history = on }
          if let on = args["search"] as? Bool { wizard.plan.searchSettings = on }
          if let on = args["passwords"] as? Bool { wizard.plan.passwords = on }
          if let value = args["primaryPassword"] as? String, value.utf8.count <= 256 { wizard.plan.primaryPassword = value }
        case "settings-safari-export", "settings-passwords-file":
          // Synthetic files only: the path must sit next to the synthetic browser library.
          guard let base = ImportWizardViewModel.browserLibraryOverride?.deletingLastPathComponent().standardizedFileURL.path,
                let path = args["path"] as? String, path.utf8.count <= 1024,
                URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(base + "/") else { throw Failure(message: "file must be in the synthetic import root") }
          if action == "settings-safari-export" { await wizard.useSafariExport(URL(fileURLWithPath: path)) }
          else { await wizard.usePasswordsFile(URL(fileURLWithPath: path)) }
        case "settings-access-check":
          await wizard.checkAccessAgain()
        case "settings-back":
          wizard.backToSource()
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
          if let on = args["secrets"] as? Bool { flow.includeSecrets = on }
        case "import":
          guard let steps = app.onboardingWindowController?.steps, steps.step == .name else { throw Failure(message: "not on Name") }
          if flow.probe == nil { await flow.refreshProbe() }; steps.next()
        case "fresh":
          guard [.welcome, .importChoices, .failed, .defaultBrowser].contains(flow.step) else { throw Failure(message: "Start Fresh is unavailable") }; if let steps = app.onboardingWindowController?.steps { await steps.skipToDefault(); steps.finishFromDefault() }
        case "back":
          guard [.importChoices, .failed].contains(flow.step) else { throw Failure(message: "Back is unavailable") }
          if let steps = app.onboardingWindowController?.steps { steps.back() }
        case "notnow":
          guard [.importChoices, .defaultBrowser].contains(flow.step) else { throw Failure(message: "Not Now is unavailable") }
          if let steps = app.onboardingWindowController?.steps { if steps.step == .importData { await steps.skipToDefault() } else { steps.finishFromDefault() } }
        case "finish": guard flow.step == .defaultBrowser else { throw Failure(message: "not on default-browser step") }; app.onboardingWindowController?.steps?.finishFromDefault()
        case "continue", "retry":
          if flow.step == .report {
            if flow.errorText == FirstRunViewModel.importedSaveError { if let steps = app.onboardingWindowController?.steps { await steps.skipToDefault(); steps.finishFromDefault() } }
            else if action == "retry", flow.errorText != nil, !flow.wizard.hasImportedData { flow.showImport() }
            else if let steps = app.onboardingWindowController?.steps { await steps.skipToDefault() }
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
      "screen": app.onboardingWindowController?.steps?.step.rawValue ?? "done",
      "importInProgress": app.importInProgress,
      "historyInProgress": app.importRunner.historyInProgress,
      "historyProcessed": app.importRunner.historyProcessed,
      "importUndoInProgress": app.importRunner.undoOperations > 0,
      "importUndoError": app.importRunner.undoError,
      "importAllMilliseconds": app.importRunner.importAllMilliseconds,
      "importMetrics": app.importRunner.watchdog.state.merging([
        "historyMilliseconds": app.importRunner.historyMilliseconds,
        "totalMilliseconds": app.importRunner.totalMilliseconds
      ]) { _, new in new },
      "completed": UserDefaults.standard.bool(forKey: "open.firstRun.completed")]
    if let outcome = app.importRunner.lastOutcome {
      state["lastOutcome"] = outcome.counts; state["lastFailures"] = outcome.failures
    }
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
      state["reportValues"] = Dictionary(uniqueKeysWithValues: ImportWizardViewModel.reportCategories.map { ($0, current.reportValue($0)) })
      state["phase"] = current.phaseText
      state["progress"] = current.progress ?? NSNull()
      state["browserHasLanded"] = current.browserHasLanded
      if let window = app.firstRunWindowController?.window {
        state["frameSize"] = [window.frame.width, window.frame.height]
        state["key"] = window.isKeyWindow
        state["trafficLights"] = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { kind -> [CGFloat]? in
          guard let button = window.standardWindowButton(kind) else { return nil }
          let r = button.convert(button.bounds, to: nil)
          return [r.minX, window.frame.height - r.maxY, r.width, r.height]
        }
        if action == "inspect" {
          let inspection = try await firstRunRenderedText(window)
          state["renderedText"] = inspection.lines; state["ocrRetries"] = inspection.retries
        }
      }
    }
    if action?.hasPrefix("settings-") == true || current == nil {
      // Reading normal launch status must keep Settings lazy.
      if action?.hasPrefix("settings-") == true || app.importInProgress || app.importRunner.historyInProgress || app.importRunner.lastOutcome != nil {
        let wizard = app.settingsPresenter.settings.importWizard
        state["settingsStep"] = wizard.step.rawValue
        state["settingsBusy"] = wizard.busy
        state["settingsReadable"] = wizard.readable
        state["settingsCanContinue"] = wizard.canContinue
        state["settingsCounts"] = wizard.counts
        state["settingsOutcome"] = wizard.outcome?.counts ?? [:]
        state["settingsError"] = wizard.outcome?.errorText ?? ""
        state["secretsEnabled"] = wizard.canImportPasswordsAndCookies
        let copy = wizard.passwordsCopy
        state["secretsTitle"] = copy.title
        state["secretsBody"] = copy.body
        state["secretsButtons"] = wizard.step == .consent
          ? (wizard.canImportPasswordsAndCookies ? [PasswordsImportCopy.skipButton, PasswordsImportCopy.allowButton, "Cancel"] : [PasswordsImportCopy.skipButton, "Cancel"]) : []
        state["secretsAllowVisible"] = wizard.step == .consent && wizard.canImportPasswordsAndCookies
        state["secretsAllowEnabled"] = wizard.step == .consent && wizard.canImportPasswordsAndCookies && !wizard.consentWasDecided && !wizard.busy
        state["secretsConsented"] = wizard.plan.secretsConsented
        state["secretsReportLines"] = wizard.secretsReportLines
        state["secretsUnfinishedMessage"] = wizard.unfinishedSecretsImportMessage ?? ""
        state["settingsFailures"] = wizard.outcome?.failures ?? [:]
        state["settingsReportValues"] = Dictionary(uniqueKeysWithValues: ImportWizardViewModel.reportCategories.map { ($0, wizard.reportValue($0)) })
        state["settingsTitle"] = wizard.title
        state["settingsSource"] = wizard.plan.source.importKey
        state["settingsSelectedSource"] = wizard.selectedSourceID
        state["settingsSourcesLoaded"] = wizard.sourcesLoaded
        state["settingsCanContinueFromSource"] = wizard.canContinueFromSource
        state["settingsBrowserSecretsEnabled"] = wizard.canImportBrowserSecrets
        state["settingsExtensions"] = (wizard.outcome?.extensions ?? []).map(\.extensionID)
        state["settingsSecretsTitle"] = wizard.passwordsCopy.title
        state["settingsSources"] = wizard.sources.map { source -> [String: Any] in
          ["id": source.id, "name": source.name, "family": source.family.rawValue, "selectable": wizard.canSelect(source),
           "visible": wizard.visibleSources.contains(source),
           "status": wizard.sourceStatus(source) ?? "", "profiles": source.profiles.map { ["id": $0.id, "name": $0.name] }]
        }
        state["settingsBrowserLabels"] = Dictionary(uniqueKeysWithValues: Set(wizard.browserCategories + ["Passwords and cookies", "Passwords", "Cookies"]).map { ($0, wizard.countLabel($0)) })
        state["settingsAccess"] = wizard.accessBlocker?.rawValue ?? ""
        state["settingsWizardError"] = wizard.errorText
        state["settingsAccessTitle"] = wizard.accessTitle
        state["fullDiskAccessRequests"] = wizard.fullDiskAccessRequests
        state["settingsCanContinue"] = wizard.canContinue
        state["settingsPasswords"] = wizard.plan.passwords
        state["settingsNeedsPrimaryPassword"] = wizard.needsPrimaryPassword
        state["settingsSafariExport"] = wizard.plan.safariFiles.exportArchive?.lastPathComponent ?? ""
        state["settingsReportCategories"] = wizard.displayedReportCategories
        state["settingsReportSummary"] = wizard.step == .report ? wizard.reportSummary : ""
        state["undoTitle"] = app.undoManager.undoActionName
      }
    }
    return state
  }

  /// Inspect pixels from our own native window. SwiftUI's in-process AX tree
  /// can be empty unless an outside assistive client has activated it. OCR
  /// proves the displayed copy and its geometry without such a client or input.
  func firstRunRenderedText(_ window: NSWindow) async throws -> (lines: [[String: Any]], retries: Int) {
    try await Task.sleep(for: .milliseconds(250)) // allow the normal step fade to finish
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("open-firstrun-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await WindowSnapshot.capture(window, to: url)
    let width = Double(window.frame.width), height = Double(window.frame.height)
    let inspected = try await Task.detached(priority: .utility) {
      func recognize() throws -> [FirstRunTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).prefix(128).compactMap { observation -> FirstRunTextLine? in
          guard let line = observation.topCandidates(1).first else { return nil }
          let r = observation.boundingBox
          return FirstRunTextLine(text: String(line.string.prefix(512)), frame:
            [r.minX * width, (1 - r.maxY) * height, r.width * width, r.height * height])
        }
      }
      do { return (try recognize(), 0) }
      catch {
        let failure = error as NSError
        guard failure.domain == "TextRecognition.CRImageReaderError", failure.code == 1 else { throw error }
        // One retry of Vision's transient decoder failure, on the same native
        // capture. Keep all copy/geometry assertions and the client deadline.
        try await Task.sleep(for: .milliseconds(250))
        return (try recognize(), 1)
      }
    }.value
    return (inspected.0.map { ["text": $0.text, "frame": $0.frame] }, inspected.1)
  }
}
#endif
