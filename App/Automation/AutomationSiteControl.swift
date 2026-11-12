#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenModel
import OpenSiteControl
import OpenDesign
import Darwin

/// Empty unless the e2e runner injected its native draw probe. Read at the
/// receipt callback, so later AppKit work cannot count as measured work.
func siteControlNativeDrawProbe() -> [UInt64] {
  typealias Count = @convention(c) (Int32) -> UInt64
  guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_scc_draw_probe_count") else { return [] }
  let count = unsafeBitCast(address, to: Count.self)
  return (0..<6).map { count(Int32($0)) }
}

extension AutomationController {
  func siteControlIdle(_ args: [String: Any]) throws -> Any {
    typealias Action = @convention(c) () -> Void
    typealias Watch = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Count = @convention(c) (Int32) -> UInt64
    func symbol<T>(_ name: String, _: T.Type) throws -> T {
      guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { throw Failure(message: "SCC idle observer is not loaded") }
      return unsafeBitCast(address, to: T.self)
    }
    let count = try symbol("open_idle_count", Count.self)
    switch args["action"] as? String ?? "read" {
    case "begin": try symbol("open_idle_begin", Action.self)()
    case "reset": try symbol("open_idle_reset_events", Action.self)()
    case "end": try symbol("open_idle_end", Action.self)()
    case "watch":
      let watch = try symbol("open_idle_watch_view", Watch.self)
      func visit(_ view: NSView) { watch(Unmanaged.passUnretained(view).toOpaque()); view.subviews.forEach(visit) }
      guard let view = try window.controller?.siteControl?.view else { throw Failure(message: "no site controls") }
      visit(view)
    case "canary":
      let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in }
      let live = count(6); timer.invalidate()
      return ["live": live, "after": count(6)]
    default: break
    }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    return ["counts": (0..<10).map { count(Int32($0)) }, "cpuSeconds": cpu]
  }

  func runSiteControl(_ args: [String: Any]) async throws -> Any {
    let factory = try window
    guard let owner = factory.controller, let scc = owner.siteControl else { throw Failure(message: "no site") }
    switch args["action"] as? String ?? "state" {
    case "state": break
    case "permission-index":
      guard let tab = owner.splitController.focusedTab,
            let context = factory.hosts[tab.id]?.content.context else { throw Failure(message: "no site context") }
      let store = SitePermissionStore.forContext(context)
      await store.persistenceTask?.value
      return ["ready": store.indexReady]
    case "adblock-state":
      guard let context = scc.view.panel.snapshot?.context else { throw Failure(message: "no site snapshot") }
      let store = app.stores.existingAdBlock
      let profile = factory.incognitoSession?.parent.id ?? context.profileID
      let session = factory.isIncognito ? factory.incognitoSession?.context?.identifier : nil
      return ["bindingInstalled": store?.onEngineEvent != nil,
        "profileOpen": store?.isProfileOpen(profile) ?? false,
        "privateSessionReady": !factory.isIncognito || session.map { store?.isPrivateSessionOpen($0, profile: profile) == true } == true,
        "enabled": store?.isEnabled ?? false,
        "shouldBlock": (try? store?.siteSnapshot(for: profile, privateSession: session).shouldBlock(host: context.url.host() ?? "")) == true]
    case "capture-content-blocking":
      guard scc.isPresented, let snapshot = scc.view.panel.snapshot,
            let tile = snapshot.tiles.first(where: { $0.kind == .contentBlocking }), tile.state != .unavailable else {
        throw Failure(message: "no available ad-block tile")
      }
      factory.siteControlSource.capturedContentBlockingTile = (tile, snapshot.context.tabID)
    case "set-adblock-excluded":
      guard scc.isPresented, let context = scc.view.panel.snapshot?.context,
            context.isWebsite, !context.isIncognito, let host = context.url.host(),
            let excluded = args["excluded"] as? Bool,
            let store = app.stores.existingAdBlock, store.onEngineEvent != nil,
            store.isEnabled, store.isProfileOpen(context.profileID) else { throw Failure(message: "no available ad-block store") }
      try store.setExcluded(host, excluded: excluded, profile: context.profileID)
    case "toggle-captured-content-blocking":
      guard scc.isPresented, let captured = factory.siteControlSource.capturedContentBlockingTile,
            scc.tabID == captured.tabID else { throw Failure(message: "no captured tile for this panel") }
      factory.siteControlSource.capturedContentBlockingTile = nil
      // Deliver the retained value through the real panel callback. Settings
      // can change the store between drawing a tile and receiving its action.
      scc.view.panel.onToggle?(captured.tile)
    case "open":
      guard let tab = owner.splitController.focusedTab,
            factory.siteControlSource.snapshot(for: tab.id) != nil,
            !(owner.hasPeekController && owner.peekController.isShown) else { throw Failure(message: "no site") }
      let via = args["via"] as? String ?? "urlField"
      if via == "pane" {
        guard let pane = owner.container.slots.first(where: { $0.tabID == tab.id })?.paneChrome,
              pane.pressSiteControls() else { throw Failure(message: "no visible pane anchor") }
      } else if via == "urlField" {
        // Reload can reset tracking while the tagged pointer stays at its old
        // position. Enter from the page so the real hover path runs again.
        _ = try await runExtensionCommand("ext-hover", ["inside": false])
        _ = try await runExtensionCommand("ext-hover", ["inside": true])
        owner.sidebar.refreshExtensionsLayout()
        guard !owner.sidebar.siteControlsAnchor.isHiddenOrHasHiddenAncestor,
              owner.sidebar.pressSiteControls() else { throw Failure(message: "no visible URL anchor") }
      } else { throw Failure(message: "via must be urlField or pane") }
    case "close": scc.dismiss(reason: .escape, animated: false)
    case "material":
      // Measurement only: try a public material and overlay constants on the open panel (LEAD 12:05 fit).
      func rgba(_ key: String) -> RGBA {
        guard let v = args[key] as? [Double], v.count == 4 else { return .clear }
        return RGBA(v[0], v[1], v[2], v[3])
      }
      let appearance: ContentAppearance = args["appearance"] as? String == "light" ? .light : .dark
      if args["material"] as? Int == -1 { scc.view.panel.materialOverride[appearance] = nil; scc.view.panel.layoutSubtreeIfNeeded(); break }
      guard let raw = args["material"] as? Int, let m = NSVisualEffectView.Material(rawValue: raw) else { throw Failure(message: "material raw value") }
      func d(_ k: String) -> Double { args[k] as? Double ?? 0 }
      scc.view.panel.materialOverride[appearance] = SiteControlMaterialSpec(material: m, overlay: rgba("overlay"),
        tintAlpha: d("tintAlpha"), tailShare: d("tailShare"), tailLength: CGFloat(args["tailLength"] as? Double ?? 120),
        topAlpha: d("topAlpha"), topExtent: CGFloat(args["topExtent"] as? Double ?? 48),
        rimTintShare: d("rimShare"), ringTintShare: d("ringShare"), moreTintShare: d("moreShare"), topWhiteMix: d("topWhite"),
        rim: args["rimAlpha"] == nil ? nil : (d("rimGray"), d("rimAlpha")), ring: args["ringAlpha"] == nil ? nil : (d("ringGray"), d("ringAlpha")))
      scc.view.panel.layoutSubtreeIfNeeded()
    case "tap":
      guard scc.isPresented, let id = args["id"] as? String, id.utf8.count <= 256,
            let button = scc.view.panel.controls.first(where: { $0.controlID == (id.hasPrefix("row.") ? String(id.dropFirst(4)) : id) }),
            !button.isHiddenOrHasHiddenAncestor, button.isEnabled else { throw Failure(message: "no enabled visible control") }
      button.performClick(nil)
    case "menu":
      guard scc.isPresented else { throw Failure(message: "site controls closed") }
      let menu = scc.makeMenu()
      if let title = args["item"] as? String {
        guard title.utf8.count <= 128,
              let index = menu.items.firstIndex(where: { $0.title == title && !$0.isSeparatorItem && $0.isEnabled }) else { throw Failure(message: "no enabled menu item") }
        menu.performActionForItem(at: index)
      }
    default: throw Failure(message: "unknown site-controls action")
    }
    owner.refreshSiteControlButtons()
    return siteControlState(owner)
  }
  private func siteControlState(_ owner: BrowserWindowController) -> [String: Any] {
    guard let scc = owner.siteControl else { return ["presented": false] }
    let panel = scc.view.panel, snapshot = panel.snapshot
    let rect = { (r: CGRect) in [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    let controls = panel.controls.map { button -> [String: Any] in
      ["id": button.controlID, "title": button.accessibilityLabel() ?? button.title,
       "enabled": button.isEnabled, "visible": scc.isPresented && !button.isHiddenOrHasHiddenAncestor,
       "frame": rect(button.convert(button.bounds, to: scc.view))]
    }
    let rows = (snapshot?.tiles ?? []).map { tile -> [String: Any] in
      ["id": "row." + tile.id, "title": tile.title, "subtitle": tile.subtitle,
       "state": tile.state == .on ? "on" : tile.state == .off ? "off" : "unavailable",
       "visible": scc.isPresented, "inUse": tile.inUse, "help": tile.help ?? ""]
    }
    let menu = scc.isPresented ? scc.makeMenu().items.map { ["title": $0.title, "enabled": $0.isEnabled, "separator": $0.isSeparatorItem] as [String: Any] } : []
    let tip = scc.view.visibleArrowTip
    let visibleAnchor: [String: Any]
    if let tab = owner.splitController.focusedTab,
       let anchor = owner.visibleSiteControlAnchor(tabID: tab.id), let window = anchor.window {
      let toolbar = owner.container.slots.contains { $0.paneChrome?.role == .toolbar && $0.paneChrome?.siteControlsAnchor === anchor }
      visibleAnchor = ["frame": rect(window.convertToScreen(anchor.convert(anchor.bounds, to: nil))),
        "surface": toolbar ? "toolbar" : (anchor.isDescendant(of: owner.sidebar) ? "sidebar" : "pane")]
    } else { visibleAnchor = [:] }
    return ["presented": scc.isPresented, "tab": scc.tabID?.description ?? "", "host": snapshot?.context.displayHost ?? "",
      "mode": scc.mode == .extensionPicker ? "extensionPicker" : "standard",
      "isIncognito": snapshot?.context.isIncognito ?? false,
      "canCreateBoost": snapshot?.canCreateBoost ?? false,
      "rows": rows, "controls": controls, "items": menu,
      "extensionsVisible": scc.isPresented && panel.extensionsSectionVisible,
      "boostsVisible": scc.isPresented && panel.boostsSectionVisible,
      "reloadVisible": scc.isPresented && panel.showsReload,
      "visibleAnchor": visibleAnchor,
      "anchor": rect(scc.view.anchorFrame), "body": rect(scc.view.panelFrame), "tip": [Double(tip.x), Double(tip.y)],
      "urlButtonState": owner.sidebar.siteControlState.rawValue,
      "security": controls.first(where: { $0["id"] as? String == "security" }) ?? [:],
      "focusedControl": (owner.window?.firstResponder as? SiteControlButton)?.controlID ?? "",
      "firstDrawMilliseconds": (try? window.siteControlDrawSamples) ?? [],
      "firstDrawNativeProbe": (try? window.siteControlDrawNativeProbeSamples) ?? [],
      "firstDrawPhases": (try? window.siteControlDrawPhaseSamples) ?? [],
      "drawNativeProbe": siteControlNativeDrawProbe(),
      "sourceReads": ["snapshots": (try? window.siteControlSource.snapshotReadCount) ?? 0,
        "buttons": (try? window.siteControlSource.buttonReadCount) ?? 0,
        "changeDeliveries": (try? window.siteControlSource.changeDeliveryCount) ?? 0],
      "sourceActions": ["toggle": (try? window.siteControlSource.toggleCallCount) ?? 0,
        "openAdBlockSettings": (try? window.siteControlSource.openAdBlockSettingsCallCount) ?? 0],
      "extensionItems": panel.hasExtensionItems ? panel.extensionsBody.items.map { ["id": $0.item.id, "title": $0.item.name, "visible": scc.isPresented && !$0.isHiddenOrHasHiddenAncestor] as [String: Any] } : controls.filter { $0["id"] as? String == "extension.add" },
      "extensionsFocusedID": panel.extensionsBody.focusedID ?? ""] as [String: Any]
  }
}
#endif
