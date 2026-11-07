#if OPEN_AUTOMATION
import AppKit
import OpenEngine

extension AutomationController {
  func incognitoState(_ args: [String: Any]) throws -> [String: Any] {
    let selected = app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
    var result: [String: Any] = [
      "normalProfiles": app.model.profiles.count, "normalSpaces": app.model.spaces.count,
      "normalTabs": app.model.index.count, "normalWindows": app.model.windows.count,
      "snapshotSchedules": app.snapshotStore.scheduleCount,
      "historyWrites": app.stores.historyWriteCount,
      "downloads": app.downloadsCenter.downloads.count,
      "windows": app.windowControllers.map { controller -> [String: Any] in
        let factory = app.hostFactories[controller.windowID]
        return ["id": controller.windowID.description, "number": controller.window?.windowNumber ?? 0,
          "private": factory?.isIncognito ?? false, "title": controller.window?.title ?? ""]
      }
    ]
    // Explicit request only: normal-model dumps above never serialize private tabs.
    if args["private"] as? Bool == true, let factory = selected {
      result["private"] = factory.isIncognito
      result["parent"] = factory.incognitoSession?.parent.id.description ?? ""
      result["modelIsNormal"] = factory.model === app.model
      result["modelArchiveSink"] = factory.model.archiveSink != nil
      result["header"] = factory.controller?.context.incognitoTitle ?? ""
      result["chrome"] = factory.controller?.sidebar.incognitoChrome ?? [:]
      result["ephemeral"] = factory.selectedContent?.context.isEphemeral ?? false
      result["context"] = factory.selectedContent?.context.identifier ?? ""
      result["originalContext"] = factory.selectedContent?.context.originalContext?.identifier ?? ""
      result["boostScriptIDs"] = factory.selectedContent?.context.userScripts.filter { $0.identifier.hasPrefix("open.boosts.") }.map(\.identifier) ?? []
      result["appearance"] = factory.window?.effectiveAppearance.name.rawValue ?? ""
      result["extensions"] = factory.focusedBrowser?.extensionActions.map(\.extensionIdentifier) ?? []
      result["tabs"] = factory.orderedTabs.map { ["id": $0.id.description, "url": $0.url.absoluteString] }
    }
    return result
  }

  func incognitoScreen(_ args: [String: Any]) throws -> [String: Any] {
    guard let factory = app.frontWindowController.flatMap({ app.hostFactories[$0.windowID] }), factory.isIncognito,
      let window = factory.window, let scale = args["scale"] as? Double,
      let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == scale }) else {
      throw Failure(message: "No private window or requested physical display scale")
    }
    let visible = screen.visibleFrame
    window.setFrame(NSRect(x: visible.minX + 40, y: visible.minY + 40,
      width: min(1000, visible.width - 80), height: min(700, visible.height - 80)), display: true)
    return ["number": window.windowNumber, "scale": window.backingScaleFactor,
      "screens": NSScreen.screens.map { $0.backingScaleFactor }]
  }
}
#endif
