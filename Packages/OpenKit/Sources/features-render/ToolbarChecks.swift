import AppKit
import OpenModel
import OpenFeatures
import OpenCommands
import OpenDesign
import OpenSidebar

/// commandbar-completion Step 8: the optional content toolbar (§4.6) on the real window controller.
@MainActor
enum ToolbarChecks {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory(), defaults = FeatureCLI.defaults()
        let window = model.windows[0], space = model.spaces[0], first = space.pinned[0].tab!
        window.sidebarWidth = 228
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: first.id)
        let c = BrowserWindowController(model: model, windowID: window.id, factory: factory, size: CGSize(width: 1600, height: 1000), defaults: defaults)
        defer { c.container.closeAll(); c.window?.close() }
        func settle() async throws { try await FeatureCLI.waitForLoads(factory, root: c.contentView); OffscreenRenderer.settle(c.contentView, runLoop: 0.01) }
        var intents: [SidebarIntent] = [], commandBar: [CommandBarSource] = []
        c.onSidebarIntent = { intents.append($0); return nil }
        c.onOpenCommandBar = { source, _ in commandBar.append(source) }
        try await settle()
        let slot = c.container.slots[0], pageBefore = slot.contentHostView?.frame ?? .zero
        let menuBar = MenuBuilder.buildMainMenu(dispatcher: c, spaces: [], tabs: [], overrides: .empty, switchToNinth: false)
        func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
            for i in menu.items {
                if (i.representedObject as? [String: String])?["command"] == id { return i }
                if let sub = i.submenu, let found = item(id, in: sub) { return found }
            }
            return nil
        }
        // Validation runs before a menu shows: it enables the item and sets its runtime title.
        func validated(_ id: String) -> NSMenuItem? {
            guard let i = item(id, in: menuBar), let target = i.target as? NSMenuItemValidation else { return nil }
            i.isEnabled = target.validateMenuItem(i); return i
        }
        func press(_ i: NSMenuItem?) { if let i, let action = i.action { NSApp.sendAction(action, to: i.target, from: i) } }
        let geometry0 = c.sidebar.chromeGeometry
        check(slot.paneChrome == nil && validated("toggle-toolbar")?.title == "Show Toolbar" && validated("toggle-toolbar")?.isEnabled == true
              && validated("toggle-sidebar")?.title == "Hide Sidebar",
              "TB1 default: no toolbar; View menu items read Show Toolbar and Hide Sidebar (CC-32)")
        check(c.sidebar.urlFieldVisible && c.sidebar.toolbarNavigationVisible && geometry0.favorites.minY == FavoritesMetrics.sectionTop,
              "TB1 default sidebar: URL field, Back, Forward and Reload show; Favorites at y \(FavoritesMetrics.sectionTop)")

        press(validated("toggle-toolbar")); try await settle()
        let bar = slot.paneChrome, w = slot.bounds.width
        let page = slot.contentHostView?.frame ?? .zero
        check(window.showsToolbar && bar?.role == .toolbar && bar?.frame == CGRect(x: 0, y: slot.bounds.height - 32, width: w, height: 32),
              "TB2 View ▸ Show Toolbar: the bar takes the top 32 pt of the single pane (\(bar?.frame ?? .zero))")
        check(page.height == pageBefore.height - ToolbarMetrics.height && page.width == pageBefore.width && page.minY == 0,
              "TB2 the page gets the rest: height \(pageBefore.height) → \(page.height)")
        check(validated("toggle-toolbar")?.title == "Hide Toolbar", "TB2 the View menu item now reads Hide Toolbar")
        check(bar?.visibleControls == ["Go back", "Go forward", "Reload", "Copy Current URL", "Site Control Center"],
              "TB3 controls: back, forward, reload, copy, Site Control Center; no split menu, no close (\(bar?.visibleControls ?? []))")
        check(bar?.controlFrame("Go back") == SplitMetrics.back && bar?.controlFrame("Go forward") == SplitMetrics.forward
              && bar?.controlFrame("Reload") == SplitMetrics.reload
              && bar?.controlFrame("Site Control Center") == CGRect(x: w - 37, y: 2, width: 32, height: 28),
              "TB3 frames: back [5,4,32,24], forward [42,…], reload [79,…], Site Control Center [W − 37, 2, 32, 28]")
        let label = bar?.subviews.compactMap { $0 as? NSTextField }.first
        check(bar?.displayedText == "site1.example.com" && abs((label?.frame.midX ?? 0) - w / 2) <= 2.5,
              "TB4 the host shows, centered on the bar (\(bar?.displayedText ?? "nil"), mid \(label?.frame.midX ?? 0) of \(w))")

        let menu = c.toolbarMenu()
        check(menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Show Full URL", "Hide Toolbar", "-", "Manage Extensions"],
              "TB5 right-click menu: Show Full URL, Hide Toolbar, separator, Manage Extensions (\(menu?.items.map(\.title) ?? []))")
        press(menu?.items.first); try await settle()
        check(bar?.displayedText == first.url.absoluteString && c.toolbarMenu()?.items.first?.title == "Hide Full URL"
              && intents.last == .setShowFullURL(true),
              "TB5 Show Full URL: the full URL shows (\(bar?.displayedText ?? "nil")); the App saw the intent first; the item reads Hide Full URL")
        press(c.toolbarMenu()?.items.first); try await settle()
        check(bar?.displayedText == "site1.example.com", "TB5 Hide Full URL: back to the host")
        press(c.toolbarMenu()?.items.last); try await settle()
        check(intents.last == .manageExtensions, "TB5 Manage Extensions reaches the App as an intent")
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window!.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        bar?.mouseDown(with: click)
        check(commandBar == [.urlField], "TB6 a click on the bar opens the command bar in edit mode (Cmd+L)")

        let geometry = c.sidebar.chromeGeometry
        check(!c.sidebar.urlFieldVisible && !c.sidebar.toolbarNavigationVisible && c.sidebar.toolbarVisibleButtons == ["toggle"]
              && geometry.favorites.minY == URLFieldMetrics.y,
              "TB7 sidebar with the toolbar: no URL field, no Back/Forward/Reload, the toggle stays, Favorites at y \(URLFieldMetrics.y) (\(c.sidebar.toolbarVisibleButtons), \(geometry.favorites.minY))")
        window.sidebarWidth = BrowserWindowState.minimumSidebarWidth; c.layoutContent(); try await settle()
        check(c.sidebar.bounds.width == 164 && c.sidebar.toolbarVisibleButtons == ["more"] && !c.sidebar.urlFieldVisible,
              "TB8 164 pt compact sidebar with the toolbar: only More options (\(c.sidebar.toolbarVisibleButtons))")
        check(c.sidebar.toolbarMoreMenu().items.map(\.title) == ["Reload", "Toggle Sidebar"], "TB8 compact More options keeps Reload and Toggle Sidebar (Arc's titles, capture s9)")

        // A split keeps its pane bars; the toolbar flag only adds the bar to a single pane.
        let second = space.pinned[1].tab!
        guard let split = model.makeSplit(tabIDs: [first.id, second.id]) else { check(false, "TB9 split"); return }
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: split.id); c.refresh(); try await settle()
        check(c.container.slots.count == 2 && c.container.slots.allSatisfy { $0.paneChrome?.role == .pane }
              && c.container.slots.contains { $0.paneChrome?.visibleControls.contains("Close This Pane") == true },
              "TB9 a selected split keeps its own pane bars (split menu and close) with the toolbar on")
        model.unsplit(splitID: split.id); model.selectNode(windowID: window.id, spaceID: space.id, nodeID: first.id); c.refresh(); try await settle()
        check(c.container.slots.count == 1 && c.container.slots[0].paneChrome?.role == .toolbar, "TB9 back on a single pane: the toolbar returns")

        press(c.toolbarMenu()?.items[1]); window.sidebarWidth = 228; c.layoutContent(); try await settle()
        let after = c.container.slots[0]
        check(!window.showsToolbar && after.paneChrome == nil && after.contentHostView?.frame.height == pageBefore.height
              && c.sidebar.urlFieldVisible && c.sidebar.toolbarNavigationVisible && c.sidebar.chromeGeometry.favorites.minY == FavoritesMetrics.sectionTop,
              "TB10 Hide Toolbar: no bar, full page height, the sidebar URL field and navigation return")
        let fieldMenu = c.sidebar.urlFieldMenu()
        let fieldTitles = fieldMenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        check(fieldTitles == ["Copy URL", "Share", "Capture…", "Capture Full Page", "Capture in Portrait Mode", "-", "Show as Toolbar",
                              UserDefaults.standard.object(forKey: SidebarContext.sharedQuotesKey) as? Bool ?? true ? "Disable Shared Quotes" : "Enable Shared Quotes"],
              "TB11 URL field right-click menu in Arc 1.172.2 order (capture session 3 Part D): \(fieldTitles)")
        press(fieldMenu.item(withTitle: "Show as Toolbar")); try await settle()
        check(window.showsToolbar && c.container.slots[0].paneChrome?.role == .toolbar && intents.last == .setToolbarShown(true),
              "TB11 Show as Toolbar shows the toolbar")
        c.performCommand("toggle-toolbar"); try await settle()
        check(!window.showsToolbar && c.container.slots[0].paneChrome == nil, "TB12 toggle-toolbar (Cmd+Shift+D) hides it again")

        // The toolbar's copy button copies the URL without trackers (Section 2 item 12, Arc CC-31a).
        c.setToolbarShown(true); try await settle()
        let copyHost = c.container.host(for: first.id) as? FakeWebContentHost
        copyHost?.load(URL(string: "https://site1.example.com/page?utm_source=news&q=1")!); try await settle()
        let copyButton = c.container.slots[0].paneChrome?.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Copy Current URL" }
        copyButton?.performClick(nil)
        check(NSPasteboard.general.string(forType: .string) == "https://site1.example.com/page?q=1" && c.lastToastTitle == "Copied a clean link without trackers",
              "TB14 the copy button copies the URL without trackers and says so (\(NSPasteboard.general.string(forType: .string) ?? "nil"), \(c.lastToastTitle))")
        copyHost?.load(URL(string: "https://site1.example.com/page")!); try await settle()
        copyButton?.performClick(nil)
        check(NSPasteboard.general.string(forType: .string) == "https://site1.example.com/page" && c.lastToastTitle == "Copied Current URL",
              "TB14 a URL without trackers copies as it is: Copied Current URL")
        c.setToolbarShown(false); try await settle()

        let little = BrowserWindowState(focusedSpaceID: space.id, style: .littleOpen)
        let littleModel = BrowserModel(profiles: [], spaces: [], windows: [little])
        check(!littleModel.setToolbarShown(windowID: little.id, true) && !little.showsToolbar, "TB13 a Little Open window refuses the toolbar")
    }
}
