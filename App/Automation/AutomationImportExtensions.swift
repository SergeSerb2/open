#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import OpenSettings

extension AutomationController {
  func runImportExtensions(_ args: [String: Any]) async throws -> [String: Any] {
    let wizard = app.firstRunWindowController?.model.wizard ?? app.settingsPresenter.settings.importWizard
    let model = wizard.extensions
    let reportVisible = if let flow = app.firstRunWindowController {
      flow.window?.isVisible == true && flow.model.step == .report
    } else {
      app.settingsPresenter.settings.showsImport && app.settingsPresenter.settingsPresenter.window?.isVisible == true && wizard.step == .report
    }
    switch args["action"] as? String ?? "state" {
    case "state": break
    case "fixtures":
      guard !model.isInstalling, let files = args["files"] as? [String: String], files.count <= 4096,
        files.allSatisfy({ id, path in
          id.utf8.count == 32 && id.utf8.allSatisfy({ (97...112).contains($0) })
            && !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\0")
        }) else { throw Failure(message: "invalid extension fixture mapping") }
      app.importRunner.extensionFixtures = files.mapValues { URL(fileURLWithPath: $0) }
    case "toggle":
      guard !model.isInstalling, let id = args["row"] as? String, id.utf8.count <= 300,
        model.rows.contains(where: { $0.id == id }), let on = args["on"] as? Bool
      else { throw Failure(message: "unknown extension row or queue busy") }
      model.select(id: id, on: on)
    case "install":
      guard reportVisible, model.canInstall, importExtensionTask == nil else { throw Failure(message: "extension install button is disabled") }
      importExtensionTask = Task { @MainActor [weak self] in
        await wizard.installExtensions(); self?.importExtensionTask = nil
      }
      await Task.yield()
    case "inspect":
      // OCR is restricted to the synthetic fixture run. Production manifest
      // names never enter this command's output or an e2e receipt.
      guard !app.importRunner.extensionFixtures.isEmpty,
        let host = app.firstRunWindowController?.window ?? app.settingsPresenter.settingsPresenter.window
      else { throw Failure(message: "synthetic report is not visible") }
      // Settings presents its import report in a sheet. Capture that report,
      // rather than the dimmed Settings window behind it.
      let window = host.attachedSheet ?? host
      guard let root = window.contentView else { throw Failure(message: "synthetic report is not visible") }
      func scroll(_ view: NSView, depth: Int = 0) {
        guard depth < 64 else { return }
        if let clip = (view as? NSScrollView)?.contentView, let document = clip.documentView {
          let y = max(0, document.bounds.height - clip.bounds.height)
          clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? y : 0))
        }
        for child in view.subviews { scroll(child, depth: depth + 1) }
      }
      root.layoutSubtreeIfNeeded(); scroll(root)
      return ["text": try await firstRunRenderedText(window).lines, "window": window.windowNumber]
    case "registries":
      guard let factory = app.hostFactories.values.first(where: { !$0.isIncognito }) else { throw Failure(message: "no browser window") }
      return ["profiles": app.model.profiles.compactMap { profile -> [String: Any]? in
        guard let context = factory.context(for: profile.id) else { return nil }
        return ["profile": profile.id.description, "ready": context.extensions.isReady,
          "installed": context.extensions.installedExtensions.map(\.identifier)]
      }]
    default: throw Failure(message: "unknown import extension action")
    }
    return ["visible": reportVisible && !model.rows.isEmpty,
      "showsProfiles": model.showsProfiles, "canInstall": model.canInstall,
      "installing": model.isInstalling, "summary": model.summary ?? "",
      "webStoreCompletion": app.importRunner.extensionWebStoreCompletion.map {
        ["installed": $0.installed, "error": $0.error ?? ""] as [String: Any]
      } ?? [:],
      // Names stay on screen only. This command does not log manifest names.
      "rows": model.rows.map { row in ["row": row.id, "extension": row.candidate.extensionID,
        "profile": row.candidate.profileID.description, "selected": row.selected,
        "status": row.result?.text ?? "", "active": model.activeID == row.id] as [String: Any] }]
  }
}
#endif
