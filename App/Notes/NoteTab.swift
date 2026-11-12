import AppKit
import OpenDocuments
import OpenModel

/// A Note is an ordinary sidebar tab whose URL is `open://note/<uuid>`
/// (agreed with EZ: Easels use `open://easel/<uuid>`). It pins, sits in
/// folders and Split View panes, and archives like any tab. Only the App
/// gives the URL native content; the engine never sees it.
@MainActor
enum NoteTab {
  /// GUESS — capture pending (C3 item NT-1): the sidebar title of a Note with an empty title.
  static let untitled = "Untitled"

  static func matches(_ url: URL?) -> Bool { NoteLink.matches(url) }

  /// New Note (⌃⇧N): a new Today tab at the top, selected (a Note, or the Profile's web document app).
  /// `split`: New Note (in Split) (⌃⌥N) puts it beside the current page.
  @discardableResult
  static func create(in factory: EngineWebContentHostFactory, split: Bool) -> ItemID? {
    guard !factory.isIncognito, let space = factory.focusedSpace else { return nil }
    let model = factory.model
    let current = factory.selectedTab
    // Settings ▸ Profiles ▸ New documents: a web document app opens its "new" page instead.
    let target = DocumentApp.resolve(factory.focusedProfile?.settings.defaultDocumentApp)
    let tab: Tab
    if let url = target.url {
      tab = model.newTab(in: space.id, url: url, title: "", at: 0)
    } else {
      tab = model.newTab(in: space.id, url: NoteLink.url(for: UUID()), title: untitled, at: 0)
      tab.live.faviconPNG = faviconPNG
    }
    var selectID = tab.id
    if split, let current, current.id != tab.id {
      if case .splitPane(let splitID)? = model.parent(of: current.id),
        let existing = model.node(id: splitID)?.split, existing.panes.count < 4 {
        let index = (existing.panes.firstIndex { $0.id == current.id } ?? existing.panes.count - 1) + 1
        if model.addPane(splitID: splitID, tabID: tab.id, at: index) {
          model.focusSplitPane(splitID: splitID, tabID: tab.id); selectID = splitID
        }
      } else if let made = model.makeSplit(tabIDs: [current.id, tab.id]) {
        model.focusSplitPane(splitID: made.id, tabID: tab.id); selectID = made.id
      }
    }
    factory.select(nodeID: selectID)
    factory.scheduleSave()
    return tab.id
  }

  /// Restored tabs have transient live metadata. Seed the Note mark without
  /// reading the Note file or making a view.
  static func restoreIcons(in model: BrowserModel) {
    func seed(_ tab: Tab) { if matches(tab.url) { tab.live.faviconPNG = faviconPNG } }
    func visit(_ nodes: [SidebarNode]) {
      for node in nodes {
        switch node {
        case .tab(let tab): seed(tab)
        case .folder(let folder): visit(folder.children)
        case .split(let split): split.panes.forEach(seed)
        }
      }
    }
    for profile in model.profiles { profile.favorites.forEach(seed) }
    for space in model.spaces { visit(space.pinned); visit(space.today) }
  }

  static let faviconImage: NSImage? = faviconPNG.flatMap(NSImage.init(data:))

  /// Our own drawing: a page with a folded corner and three text lines. No bundled image.
  /// GUESS — capture pending (C3 item NT-1): Arc's Note row icon.
  static let faviconPNG: Data? = {
    let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
      let ink = NSColor(srgbRed: 0.43, green: 0.40, blue: 0.55, alpha: 1)
      let page = NSBezierPath()
      page.move(to: NSPoint(x: 7, y: 4)); page.line(to: NSPoint(x: 19, y: 4)); page.line(to: NSPoint(x: 25, y: 10))
      page.line(to: NSPoint(x: 25, y: 28)); page.line(to: NSPoint(x: 7, y: 28)); page.close()
      NSColor.white.setFill(); page.fill()
      ink.setStroke(); page.lineWidth = 2; page.lineJoinStyle = .round; page.stroke()
      let fold = NSBezierPath()
      fold.move(to: NSPoint(x: 19, y: 4)); fold.line(to: NSPoint(x: 19, y: 10)); fold.line(to: NSPoint(x: 25, y: 10))
      fold.lineWidth = 2; fold.lineJoinStyle = .round; fold.stroke()
      for (y, end) in [(15.0, 21.0), (19.5, 21.0), (24.0, 17.0)] {
        let line = NSBezierPath(); line.move(to: NSPoint(x: 11, y: y)); line.line(to: NSPoint(x: end, y: y))
        line.lineWidth = 1.8; line.lineCapStyle = .round; line.stroke()
      }
      return true
    }
    guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }()
}

extension EngineWebContentHostFactory {
  /// A typed address on a Note tab opens a new tab; the Note stays as it is.
  func openFromNote(_ url: URL) { navigateFromCommandBar(url, current: false) }
  func refreshNoteAppearance() { for host in noteHosts.values { host.updateAppearance() } }
}

extension BrowserModel {
  /// Every tab of every Space and Profile (pinned, Today, folders, split panes, Favorites).
  func allTabsForNotes() -> [Tab] {
    var result: [Tab] = []
    func visit(_ nodes: [SidebarNode]) {
      for node in nodes {
        switch node {
        case .tab(let tab): result.append(tab)
        case .folder(let folder): visit(folder.children)
        case .split(let split): result.append(contentsOf: split.panes)
        }
      }
    }
    for profile in profiles { result.append(contentsOf: profile.favorites) }
    for space in spaces { visit(space.pinned); visit(space.today) }
    return result
  }
}
