#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenLiveData
import OpenModel
import OpenSidebar

/// Live-data cards (LF L1, Recents): reads the real card and operates it through its own
/// open paths. `glance-alias` lets a fixture host count as a Recents site so e2e runs without
/// the real sites or any account; `history-record` seeds the Profile's real history store.
extension AutomationController {
  static let liveDataCommands: Set<String> = ["glance-state", "glance-open", "glance-alias", "glance-match", "history-record", "live-fetch"]

  func runLiveDataCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    switch cmd {
    case "glance-alias":
      var aliases: [String: RecentsSite] = [:]
      for (host, raw) in a["aliases"] as? [String: String] ?? [:] {
        guard let site = RecentsSite(rawValue: raw) else { throw Failure(message: "unknown Recents site \(raw)") }
        aliases[host.lowercased()] = site
      }
      for controller in app.windowControllers { controller.context.glanceHostAliases = aliases }
      return ["aliases": aliases.mapValues(\.rawValue)]
    case "glance-match":
      guard let raw = a["url"] as? String, let url = URL(string: raw) else { throw Failure(message: "glance-match needs url") }
      switch GlanceKind.match(url: url) {
      case .recents(let site)?: return ["kind": "recents", "site": site.rawValue]
      case nil: return ["kind": "none"]
      }
    case "history-record":
      guard let raw = a["url"] as? String, let url = URL(string: raw) else { throw Failure(message: "history-record needs url") }
      let profile = (a["profile"] as? String).flatMap(UUID.init(uuidString:)).map(ProfileID.init(rawValue:))
        ?? (try? window.focusedProfile?.id) ?? app.model.defaultProfile?.id
      guard let store = app.stores.history(for: profile) else { throw Failure(message: "unknown History Profile") }
      await app.stores.flushHistory()
      let time = Date().addingTimeInterval(-(a["ago"] as? Double ?? 0))
      let id = await store.recordVisit(url: url, title: a["title"] as? String ?? "", time: time)
      return ["visit": id.map { Int($0) } ?? -1]
    case "live-fetch":
      guard let raw = a["url"] as? String, let url = URL(string: raw), let script = a["script"] as? String else { throw Failure(message: "live-fetch needs url and script") }
      let profile = (try? window.focusedProfile?.id) ?? app.model.defaultProfile?.id
      guard let profile else { throw Failure(message: "no Profile") }
      let started = Date()
      do {
        let value = try await app.liveFetch.fetch(profileID: profile, url: url, script: script)
        return ["value": value, "created": app.liveFetch.created, "closed": app.liveFetch.closed, "seconds": Date().timeIntervalSince(started)] as [String: Any]
      } catch {
        return ["error": String(describing: error), "created": app.liveFetch.created, "closed": app.liveFetch.closed] as [String: Any]
      }
    case "glance-state":
      let controller = try glanceController(a)
      guard case .glance(let id)? = controller.hoverPreview.request?.kind,
        let view = controller.hoverPreview.card?.content as? RecentsPreviewView else { return ["shown": false] }
      if a["wait"] as? Bool != false {
        let deadline = Date().addingTimeInterval(5)
        while !view.isLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
      }
      controller.contentView.layoutSubtreeIfNeeded()
      let root = controller.contentView
      let card = controller.hoverPreview.card.map { root.convert($0.bounds, from: $0) } ?? .zero
      return ["shown": true, "kind": "recents", "site": view.site.rawValue, "tab": id.description, "loaded": view.isLoaded,
        "header": RecentsSite.header, "newLabel": view.newButton.toolTip ?? "", "newURL": view.site.newURL.absoluteString,
        "empty": view.pages.isEmpty ? view.site.emptyText : "",
        "rows": view.pages.map { ["url": $0.url.absoluteString, "title": $0.title] },
        "card": [card.minX, card.minY, card.width, card.height]] as [String: Any]
    case "glance-open":
      let controller = try glanceController(a)
      guard let view = controller.hoverPreview.card?.content as? RecentsPreviewView else { throw Failure(message: "no Recents card") }
      if a["new"] as? Bool == true { view.openNew() } else { view.open(row: a["row"] as? Int ?? 0) }
      return ["opened": true]
    default: throw Failure(message: "unknown live-data command")
    }
  }

  private func glanceController(_ a: [String: Any]) throws -> BrowserWindowController {
    if let raw = a["window"] as? String, let controller = app.windowControllers.first(where: { $0.windowID.description == raw }) { return controller }
    guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
    return controller
  }
}
#endif
