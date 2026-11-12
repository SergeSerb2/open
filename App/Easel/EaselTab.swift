import AppKit
import OpenEasel
import OpenModel

/// An Easel is a sidebar tab whose URL is `open://easel/<uuid>` (like the Welcome page): it
/// pins, sits in folders, splits and archives like any tab, and never reaches OpenEngine.
/// Its content lives in `<data root>/Easels/<uuid>/document.json` (`EaselStore`).
@MainActor
enum EaselTab {
  static func url(for id: UUID) -> URL { URL(string: "open://easel/\(id.uuidString.lowercased())")! }
  static func documentID(_ url: URL?) -> UUID? {
    guard let url, url.scheme?.lowercased() == "open", url.host?.lowercased() == "easel" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 1 else { return nil }
    return UUID(uuidString: parts[0])
  }
  static func matches(_ url: URL?) -> Bool { documentID(url) != nil }

  /// New Easel (File ▸ New Easel ⌃⇧E, the "+" menu, the command bar): adds an Easel row at the
  /// top of Today in the focused Space and selects it (capture s4 `e1-new-easel`).
  @discardableResult
  static func create(in factory: EngineWebContentHostFactory) -> ItemID? {
    guard !factory.isIncognito, let space = factory.focusedSpace else { return nil }
    let document = EaselDocument()
    factory.app.easels.save(document)
    factory.app.easels.flush()
    let tab = factory.model.newTab(in: space.id, url: url(for: document.id), title: document.displayTitle, at: 0)
    tab.live.faviconPNG = EaselIcon.faviconPNG
    factory.select(nodeID: tab.id)
    factory.scheduleSave()
    return tab.id
  }

  /// Restored, imported and moved Easel rows get their icon without making a canvas.
  static func restoreIcons(in model: BrowserModel) {
    func visit(_ nodes: [SidebarNode]) {
      for node in nodes {
        switch node {
        case .tab(let tab): if matches(tab.url) { tab.live.faviconPNG = EaselIcon.faviconPNG }
        case .folder(let folder): visit(folder.children)
        case .split(let split): for tab in split.panes where matches(tab.url) { tab.live.faviconPNG = EaselIcon.faviconPNG }
        }
      }
    }
    for profile in model.profiles { for tab in profile.favorites where matches(tab.url) { tab.live.faviconPNG = EaselIcon.faviconPNG } }
    for space in model.spaces { visit(space.pinned); visit(space.today) }
  }
}
