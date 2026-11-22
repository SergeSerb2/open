import AppKit
import OpenModel
import OpenRouting

@MainActor
final class AppLinkExecutor: LinkDestinationExecutor {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }

  /// NSApp.windows and BrowserModel.windows are not z-order. Only managed
  /// standard windows participate in most-recent-Space resolution.
  var orderedControllers: [BrowserWindowController] {
    let standardIDs = Set(app.model.windows.filter { $0.style == .standard }.map(\.id))
    return NSApp.orderedWindows.compactMap { window in
      app.windowControllers.first { $0.window === window && standardIDs.contains($0.windowID) }
    }
  }

  func snapshot() -> RoutingSnapshot {
    let model = app.model!
    return RoutingSnapshot(
      spaces: model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) },
      windows: orderedControllers.compactMap { controller in
        guard let state = model.windows.first(where: { $0.id == controller.windowID }), state.style == .standard else { return nil }
        return RoutingWindowSnapshot(id: state.id, kind: .standard, focusedSpaceID: state.focusedSpaceID)
      }, rules: model.routingRules, defaultDestination: model.defaultDestination,
      externalLinksInLittleOpen: UserDefaults.standard.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true,
      profiles: model.profiles.map(\.id))
  }

  func openInSpace(_ url: URL, spaceID: SpaceID) {
    app.consumeFirstExternalDestination(opensLittleOpen: false)
    guard app.model.space(id: spaceID) != nil else { return }
    var controller = orderedControllers.first
    if controller == nil {
      // makeWindow reuses the retained final standard state. Set its Space
      // before composition, so it cannot create a page in the old Space first.
      if app.frontMainModelWindowController == nil, let retained = app.model.windows.first(where: { $0.style == .standard }) {
        app.model.focusSpace(windowID: retained.id, spaceID: spaceID)
      }
      controller = app.makeWindow(focusedSpaceID: spaceID)
    }
    guard let controller, let factory = app.hostFactories[controller.windowID] else { return }
    app.model.focusSpace(windowID: controller.windowID, spaceID: spaceID)
    let tab = app.model.newTab(in: spaceID, url: url, at: 0)
    // Selection must make the tab live and attach its page, just like Cmd+T.
    factory.select(nodeID: tab.id)
    app.focusWindow(controller.windowID, activate: true)
    app.scheduleSave()
  }

  func openInLittleOpen(_ url: URL, profileHint: ProfileID?) {
    app.consumeFirstExternalDestination(opensLittleOpen: true)
    app.openLittleOpen(url: url, profileHint: profileHint)
  }

  func bootstrapFirstSpace() -> Bool {
    if !app.model.spaces.isEmpty { return true }
    let profile = app.model.profiles.first ?? app.model.createProfile(name: "Default")
    guard let profile else { return false }
    do { try app.directories.ensureProfileDirectories(for: profile) }
    catch { AppDelegate.commandLog("External-link bootstrap could not prepare the profile directory."); return false }
    app.model.createSpace(title: "Space", profileID: profile.id)
    app.scheduleSave()
    return true
  }
}
