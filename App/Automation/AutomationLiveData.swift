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
  static let liveDataCommands: Set<String> = ["glance-state", "glance-open", "glance-alias", "glance-match", "history-record", "live-fetch", "live-folder-state", "live-folder-refresh", "live-folder-origin"]

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
      case .calendar(let provider)?: return ["kind": "calendar", "provider": provider.rawValue]
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
    case "live-folder-origin":
      guard let raw = a["url"] as? String, let url = URL(string: raw) else { throw Failure(message: "live-folder-origin needs url") }
      app.liveFolders.origin = url
      return ["origin": url.absoluteString]
    case "live-folder-refresh":
      let space = try liveSpace(a)
      guard let folder = app.model.liveFolder(in: space.id) else { throw Failure(message: "no Live Folder") }
      let outcome = await app.liveFolders.refresh(folderID: folder.id, manual: a["manual"] as? Bool ?? true)
      return ["outcome": outcome?.rawValue ?? NSNull(), "throttled": app.liveFolders.throttledCount]
    case "live-folder-state":
      let space = try liveSpace(a)
      if a["wait"] as? Bool == true {
        let deadline = Date().addingTimeInterval(30)
        while app.model.liveFolder(in: space.id)?.live?.lastFetch == nil, app.model.liveFolder(in: space.id) != nil, Date() < deadline {
          try await Task.sleep(for: .milliseconds(50))
        }
      }
      guard let folder = app.model.liveFolder(in: space.id), let live = folder.live else { return ["exists": false] }
      let rows: [[String: Any]] = folder.children.compactMap { node in
        guard case .tab(let tab) = node else { return nil }
        return ["id": tab.id.description, "url": tab.url.absoluteString, "title": tab.title, "live": tab.liveItemURL?.absoluteString ?? "",
                "unread": tab.isUnread]
      }
      let index = space.pinned.firstIndex { $0.id == folder.id } ?? -1
      let intro = app.frontWindowController?.liveFolderIntro.map { v -> [String: Any] in
        let f = v.superview.map { v.convert(v.bounds, to: $0) } ?? .zero
        return ["frame": [f.minX, f.minY, f.width, f.height], "title": LiveFolderIntroView.title, "body": LiveFolderIntroView.body]
      }
      let row = app.frontWindowController.flatMap { c in c.sidebar.rowFrame(nodeID: folder.id).map { c.contentView.convert($0, from: c.sidebar) } }
      return ["exists": true, "id": folder.id.description, "title": folder.title, "pinnedIndex": index, "pinnedCount": space.pinned.count, "rows": rows,
        "intro": intro ?? NSNull(), "rowFrame": row.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull(),
        "outcome": live.lastFetch?.outcome.rawValue ?? NSNull(), "refreshes": app.liveFolders.refreshCount,
        "fetchPagesCreated": app.liveFetch.created, "fetchPagesClosed": app.liveFetch.closed] as [String: Any]
    case "glance-state":
      let controller = try glanceController(a)
      guard case .glance(let id)? = controller.hoverPreview.request?.kind else { return ["shown": false] }
      if let calendar = controller.hoverPreview.card?.content as? CalendarPreviewView {
        return try await calendarGlanceState(calendar, controller: controller, tab: id, wait: a["wait"] as? Bool != false)
      }
      guard let view = controller.hoverPreview.card?.content as? RecentsPreviewView else { return ["shown": false] }
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
      if let calendar = controller.hoverPreview.card?.content as? CalendarPreviewView {
        switch a["control"] as? String ?? "new" {
        case "new": calendar.openNew()
        case "join": guard calendar.joinable != nil, !calendar.joinButton.isHidden else { throw Failure(message: "no join strip") }
          calendar.join()
        case "access": guard !calendar.accessButton.isHidden else { throw Failure(message: "no access button") }
          calendar.askAccess()
        case "event":
          let index = a["row"] as? Int ?? 0
          guard calendar.timeline.blocks.indices.contains(index) else { throw Failure(message: "no event block \(index)") }
          calendar.timeline.select(calendar.timeline.blocks[index].event)
        default: throw Failure(message: "unknown calendar control")
        }
        return ["opened": true]
      }
      guard let view = controller.hoverPreview.card?.content as? RecentsPreviewView else { throw Failure(message: "no Recents card") }
      if a["new"] as? Bool == true { view.openNew() } else { view.open(row: a["row"] as? Int ?? 0) }
      return ["opened": true]
    default: throw Failure(message: "unknown live-data command")
    }
  }

  private func liveSpace(_ a: [String: Any]) throws -> Space {
    if let raw = a["space"] as? String, let space = app.model.spaces.first(where: { $0.id.description == raw }) { return space }
    guard let space = app.frontWindowController?.context.focusedSpace else { throw Failure(message: "no Space") }
    return space
  }

  private func calendarGlanceState(_ view: CalendarPreviewView, controller: BrowserWindowController, tab: ItemID, wait: Bool) async throws -> [String: Any] {
    if wait {
      let deadline = Date().addingTimeInterval(5)
      while !view.isLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
    controller.contentView.layoutSubtreeIfNeeded()
    let root = controller.contentView
    func rect(_ v: NSView) -> [Double] { let f = root.convert(v.bounds, from: v); return [f.minX, f.minY, f.width, f.height] }
    return ["shown": true, "kind": "calendar", "provider": view.provider.rawValue, "tab": tab.description, "loaded": view.isLoaded,
      "phase": view.phase.rawValue, "header": CalendarProvider.header, "newLabel": view.newButton.toolTip ?? "",
      "newURL": view.provider.newEventURL(for: view.tab.url).absoluteString,
      "join": view.joinButton.isHidden ? NSNull() : ["event": view.joinable?.event.id ?? "", "url": view.joinable?.link.url.absoluteString ?? "",
        "title": view.joinable?.event.displayTitle ?? "", "button": view.joinButton.title, "tooltip": view.joinButton.toolTip ?? "",
        "subtitle": view.joinable.map { CalendarPreviewView.subtitle(for: $0.event, now: Date()) } ?? ""] as [String: Any],
      "access": view.accessButton.isHidden ? NSNull() : view.accessButton.title,
      "events": view.timeline.blocks.map { ["id": $0.event.id, "title": $0.event.displayTitle, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] },
      "card": controller.hoverPreview.card.map(rect) ?? [], "privacyOpened": CalendarPrivacySettings.openedForAutomation] as [String: Any]
  }

  private func glanceController(_ a: [String: Any]) throws -> BrowserWindowController {
    if let raw = a["window"] as? String, let controller = app.windowControllers.first(where: { $0.windowID.description == raw }) { return controller }
    guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
    return controller
  }
}
#endif
