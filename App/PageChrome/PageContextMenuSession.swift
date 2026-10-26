import AppKit
import OpenEngine

/// Owns the engine request until exactly one native or app action is chosen.
/// Native NSMenu is proven by interaction-states §15. Page-specific app item
/// grouping is a guess; link/copy behavior is supported by features-advanced LK-1/2.
@MainActor
final class PageContextMenuSession {
  let menu = NSMenu()
  private let request: OEContextMenu
  private weak var owner: EngineWebContentHostFactory?
  private weak var page: OEWebContent?
  private(set) var completed = false
  private(set) var chosen = ""
  private(set) var rows: [[String: Any]] = []
  private var appTitles: Set<String> = []

  init(request: OEContextMenu, page: OEWebContent, owner: EngineWebContentHostFactory) {
    menu.autoenablesItems = false
    self.request = request; self.owner = owner; self.page = page
    let opener = owner.tabID(for: page)
    if let url = request.linkURL {
      add("link-open", "Open Link") { [weak page] in page?.load(url) }
      add("link-new-tab", "Open Link in New Tab") { [weak owner] in _ = owner?.openNewTab(url: url, background: true, opener: opener) }
      add("link-peek", "Open Link in Peek", enabled: opener != nil) { [weak owner] in
        if let opener { owner?.controller?.peekController.open(url: url, sourceTabID: opener) }
      }
      add("link-little-open", "Open Link in Little Open", enabled: false) {} // Step E owns routing.
      add("link-copy", "Copy Link") { Self.copy(url.absoluteString) }
      menu.addItem(.separator())
    }
    if request.mediaType == .image, let url = request.sourceURL {
      add("image-new-tab", "Open Image in New Tab") { [weak owner] in _ = owner?.openNewTab(url: url, background: true, opener: opener) }
      add("image-copy-url", "Copy Image Address") { Self.copy(url.absoluteString) }
      menu.addItem(.separator())
    }
    if !request.selectionText.isEmpty, let url = request.pageURL {
      let selection = request.selectionText
      add("selection-copy-link", "Copy Link to Highlight") {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encoded = selection.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        components?.percentEncodedFragment = ":~:text=" + encoded
        if let result = components?.url { Self.copy(result.absoluteString) }
      }
      menu.addItem(.separator())
    }
    append(request.items, to: menu, parent: "")
    while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
  }
  private static func normalized(_ title: String) -> String {
    title.replacingOccurrences(of: "&", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  private static func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
  private func add(_ key: String, _ title: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) {
    appTitles.insert(Self.normalized(title))
    let item = ClosureMenuItem(title: title) { [weak self] in
      guard let self, self.finish(key, engine: nil) else { return }; action()
    }
    item.identifier = .init(key); item.isEnabled = enabled; menu.addItem(item)
    rows.append(["key": key, "title": title, "enabled": enabled, "engine": false, "submenu": ""])
  }
  private func append(_ items: [OEContextMenuItem], to destination: NSMenu, parent: String) {
    for source in items {
      if source.isSeparator { if destination.items.last?.isSeparatorItem == false { destination.addItem(.separator()) }; continue }
      if appTitles.contains(Self.normalized(source.title)) { continue }
      let key = "engine:\(source.commandIdentifier)"
      let item = ClosureMenuItem(title: source.title) { [weak self] in _ = self?.finish(key, engine: source.commandIdentifier) }
      item.identifier = .init(key); item.isEnabled = source.isEnabled; item.state = source.isChecked ? .on : .off
      if !source.submenu.isEmpty {
        let child = NSMenu(title: source.title); child.autoenablesItems = false; append(source.submenu, to: child, parent: source.title); item.submenu = child
      } else { rows.append(["key": key, "id": source.commandIdentifier, "title": source.title,
        "enabled": source.isEnabled, "engine": true, "submenu": parent]) }
      destination.addItem(item)
    }
  }
  @discardableResult private func finish(_ key: String, engine: Int?) -> Bool {
    guard !completed else { return false }; completed = true; chosen = key
    if let engine { request.select(command: engine) } else { request.cancel() }
    owner?.record("contextMenuDecision", page, ["key": key]); return true
  }
  func belongs(to content: OEWebContent) -> Bool { page === content }
  func cancel() { _ = finish("cancel", engine: nil); menu.cancelTracking() }
  func present() {
    guard !completed, let page, page.isLive, !page.view.isHiddenOrHasHiddenAncestor, page.view.window != nil else { cancel(); return }
    _ = menu.popUp(positioning: nil, at: request.location, in: page.view)
    if !completed { cancel() }
  }
  @discardableResult func perform(key: String) -> Bool {
    guard !completed else { return false }
    guard page?.isLive == true else { cancel(); return false }
    func find(_ candidate: NSMenu) -> (NSMenu, Int)? {
      for (index, item) in candidate.items.enumerated() {
        if item.identifier?.rawValue == key, item.submenu == nil, item.isEnabled { return (candidate, index) }
        if let submenu = item.submenu, let result = find(submenu) { return result }
      }
      return nil
    }
    guard let (native, index) = find(menu) else { return false }
    native.performActionForItem(at: index); return completed
  }
  var state: [String: Any] { ["items": rows, "completed": completed, "chosen": chosen] }
}
