import AppKit
import OpenModel

/// An ordinary, persistent Today tab. Only the App gives its URL native content.
@MainActor
enum WelcomeTab {
  static let url = URL(string: "open://welcome")!
  static let title = "Welcome to Open"
  static func matches(_ url: URL?) -> Bool { url == Self.url }
  static func isInternal(_ url: URL) -> Bool { url.scheme?.lowercased() == "open" }

  @discardableResult
  static func insert(into model: BrowserModel, spaceID: SpaceID) -> ItemID {
    precondition(model.space(id: spaceID) != nil, "Welcome needs an existing Space")
    let tab = model.newTab(in: spaceID, url: url, title: title, at: 0)
    tab.live.faviconPNG = faviconPNG
    // This also works before a browser window is built (the onboarding hand-off).
    if model.windows.isEmpty { _ = model.createWindow(focusedSpaceID: spaceID) }
    for window in model.windows where window.focusedSpaceID == spaceID {
      model.selectNode(windowID: window.id, spaceID: spaceID, nodeID: tab.id)
    }
    return tab.id
  }

  /// Restored and imported tabs have transient live metadata. Seed their mark
  /// without making a native view or engine host, including unselected tabs.
  static func restoreIcons(in model: BrowserModel) {
    func visit(_ nodes: [SidebarNode]) {
      for node in nodes {
        switch node {
        case .tab(let tab): if matches(tab.url) { tab.live.faviconPNG = faviconPNG }
        case .folder(let folder): visit(folder.children)
        case .split(let split): for tab in split.panes where matches(tab.url) { tab.live.faviconPNG = faviconPNG }
        }
      }
    }
    for profile in model.profiles { for tab in profile.favorites where matches(tab.url) { tab.live.faviconPNG = faviconPNG } }
    for space in model.spaces { visit(space.pinned); visit(space.today) }
  }

  /// Original doorway and sun, drawn at favicon size; no bundled image.
  static let faviconPNG: Data? = {
    let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      NSColor(srgbRed: 0.10, green: 0.25, blue: 0.82, alpha: 1).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
      let door = NSBezierPath()
      door.move(to: NSPoint(x: 10, y: 5)); door.line(to: NSPoint(x: 10, y: 20))
      door.curve(to: NSPoint(x: 23, y: 20), controlPoint1: NSPoint(x: 10, y: 29), controlPoint2: NSPoint(x: 23, y: 29))
      door.line(to: NSPoint(x: 23, y: 8)); door.lineWidth = 2.6; door.lineCapStyle = .round
      NSColor.white.setStroke(); door.stroke()
      NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 17, y: 18, width: 5, height: 5)).fill()
      return true
    }
    guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }()
}

extension EngineWebContentHostFactory {
  @objc func openBasics(_ sender: Any?) {
    guard let space = focusedSpace else { return }
    let existing = (flattened(space.pinned) + flattened(space.today)).first { WelcomeTab.matches($0.url) }
    let id = existing?.id ?? WelcomeTab.insert(into: model, spaceID: space.id)
    selectTabForCommand(id, spaceID: space.id)
    scheduleSave()
  }

  /// Replace the native host in the same model tab. Web history starts at this
  /// destination: Chromium never receives the internal URL as a history entry.
  func leaveWelcome(tabID: ItemID, for url: URL) {
    guard !WelcomeTab.isInternal(url), let tab = model.tab(id: tabID) else { return }
    controller?.container.closeHost(for: tabID)
    welcomeHosts.removeValue(forKey: tabID)?.close()
    tab.url = url; tab.title = ""; tab.live.faviconPNG = nil; tab.live.sleepPhase = .live
    if !app.engineReady { queueWelcomeDestination(tabID, url: url) }
    else { _ = ensureContent(for: tab) }
    showSelection(); scheduleSave()
  }
}
