import AppKit
import OpenDesign
import OpenFeatures
import OpenModel
import OpenSidebar

/// Sidebar completion lane A1 (plan §5.2): delete confirmations through real `NSAlert`
/// sheets, the first-hide hint, and the resize-gesture hide through the real resize handle.
@MainActor
enum CompletionFeatureChecks {
    static func run(_ check: (Bool, String) -> Void) async throws {
        try deleteAlerts(check)
        try toastUndo(check)
        try deleteKeyboardFocus(check)
        try await hint(check)
        try gestureHide(check)
        try await previews(check)
        try await folderPeek(check)
        try separate(check)
    }

    // MARK: HP7–HP14 (page previews through the real container and fake hosts)

    private static func previews(_ check: (Bool, String) -> Void) async throws {
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory(), defaults = FeatureCLI.defaults()
        let space = model.spaces[0], pinned = space.pinned.compactMap(\.tab)
        let c = BrowserWindowController(model: model, windowID: model.windows[0].id, factory: factory,
                                        size: CGSize(width: 1728, height: 1084), defaults: defaults)
        defer { c.hoverPreview.hide(animated: false); c.container.closeAll(); c.window?.close() }
        func pump() { OffscreenRenderer.settle(c.contentView, runLoop: 0.01) }
        func select(_ tab: Tab) { _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)); pump() }
        func request(_ tab: Tab) -> SidebarHoverPreviewRequest {
            let row = c.sidebar.rowFrame(nodeID: tab.id) ?? CGRect(x: 0, y: 200, width: 228, height: 41)
            return SidebarHoverPreviewRequest(kind: .page(tabID: tab.id), anchorInWindow: c.sidebar.convert(row, to: nil))
        }
        pump(); select(pinned[1]); select(pinned[0])
        let cached = c.container.host(for: pinned[1].id) as? FakeWebContentHost
        let made = factory.made.count
        c.hoverPreview.update(request(pinned[1])); pump()
        check(cached != nil && c.hoverPreview.host === cached && factory.made.count == made && c.hoverPreview.reusedCachedHost
              && cached?.view.superview != nil && c.container.host(for: pinned[1].id) == nil,
              "HP7 a pinned tab with a cached hidden host shows that host object in the card (no makeHost call)")
        c.hoverPreview.update(nil); pump()
        check(c.hoverPreview.card == nil && c.container.host(for: pinned[1].id) === cached, "HP7 dismiss returns the host to the container cache")
        c.hoverPreview.update(request(pinned[2])); pump()
        let fresh = factory.made.last
        check(factory.made.count == made + 1 && fresh?.tabID == pinned[2].id && c.hoverPreview.host === fresh && fresh?.currentURL == pinned[2].url,
              "HP8 without a cached host the factory makes exactly one host for the tab's ID and loads its URL")
        c.hoverPreview.update(nil); pump()
        check(c.container.host(for: pinned[2].id) === fresh, "HP8 dismiss adopts the made host into the container cache")
        c.hoverPreview.update(request(pinned[2])); pump()
        let loads = fresh?.loadCount ?? -1
        c.hoverPreview.card?.click(); pump()
        check(c.hoverPreview.card == nil && model.windows[0].selectedNodeBySpace[space.id] == pinned[2].id
              && c.container.host(for: pinned[2].id) === fresh && fresh?.loadCount == loads && fresh?.view.isHidden == false,
              "HP9 a click in the card selects the tab; the container shows the same host with no reload")
        select(pinned[0])
        let bounds = c.contentView.bounds
        var low = request(pinned[1]); low.anchorInWindow.origin.y = 0
        c.hoverPreview.update(low); pump()
        let frame = c.hoverPreview.card?.frame ?? .zero
        let height = min(560, bounds.height - 20)
        check(frame.minX == c.context.sidebarWidth + 8 && frame.width == 420 && frame.height == height && abs(frame.maxY - (bounds.height - 10)) < 0.5,
              "HP10 page card at x = sidebar + 8, 420 × min(560, H − 20), clamped 10 pt above the window bottom (\(frame))")
        c.hoverPreview.update(nil); pump()

        // Both newly made and cached preview hosts must use the container's metadata bridge.
        for tab in [pinned[2], pinned[1]] {
            c.hoverPreview.update(request(tab))
            guard let host = c.hoverPreview.host as? FakeWebContentHost else { throw CLIError(description: "HP11 no preview host") }
            let url = URL(string: "https://preview.example.com/redirect/\(tab.id)")!, icon = Data([1, 2, 3])
            host.load(url); host.simulateTitle("Preview title"); host.simulateFavicon(icon)
            let forwarded = tab.url == url && tab.title == "Preview title" && tab.live.faviconPNG == icon
            c.hoverPreview.hide(animated: false)
            host.simulateTitle("Returned title"); host.simulateFavicon(nil)
            check(forwarded && tab.title == "Returned title" && tab.live.faviconPNG == nil && c.container.host(for: tab.id) === host,
                  "HP11 cached preview host forwards URL title and favicon during preview and after hide")
        }
        // A previously unloaded tab also emits synchronous load metadata before the card exists.
        let newTab = model.newTab(in: space.id, url: URL(string: "https://new-preview.example.com")!)
        model.pinTab(id: newTab.id); newTab.live.sleepPhase = .live
        c.hoverPreview.update(request(newTab))
        guard let newHost = c.hoverPreview.host as? FakeWebContentHost else { throw CLIError(description: "HP11 no new host") }
        let newURL = URL(string: "https://new-preview.example.com/redirect")!
        newHost.load(newURL); newHost.simulateTitle("New preview title"); newHost.simulateFavicon(Data([4]))
        let newForwarded = newTab.url == newURL && newTab.title == "New preview title" && newTab.live.faviconPNG == Data([4])
        c.hoverPreview.hide(animated: false); newHost.simulateTitle("New returned title")
        check(newForwarded && newTab.title == "New returned title", "HP11 new preview host forwards URL title and favicon during preview and after hide")

        // Engine tab cycling writes the model then synchronously refreshes, bypassing sidebar intents.
        c.hoverPreview.update(request(pinned[1]))
        let previewHost = c.hoverPreview.host as? FakeWebContentHost
        let loadCount = factory.made.reduce(0) { $0 + $1.loadCount }, hostCount = factory.made.count
        model.selectNode(windowID: model.windows[0].id, spaceID: space.id, nodeID: pinned[1].id)
        c.refresh() // Check before the asynchronous tracker selection observer can run.
        check(c.hoverPreview.card == nil && c.container.host(for: pinned[1].id) === previewHost
              && factory.made.count == hostCount && factory.made.reduce(0) { $0 + $1.loadCount } == loadCount,
              "HP12 direct selection returns the preview host before refresh with no makeHost or reload")
        pump(); select(pinned[0])

        let rows = (1...14).map { model.newTab(in: space.id, url: URL(string: "https://folder.example.com/\($0)")!, title: "Folder row \($0)") }
        guard let folder = model.createFolder(in: .spacePinned(space.id), title: "Scrollable preview", withNodes: rows.map(\.id)),
              let outline = c.sidebar.focusedOutline, let window = c.window else { throw CLIError(description: "HP13 no folder") }
        model.setExpanded(folderID: folder.id, expanded: false)
        pump()
        let row = c.sidebar.rowFrame(nodeID: folder.id)!
        let point = c.sidebar.convert(CGPoint(x: 100, y: row.midY), to: nil)
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        outline.enclosingScrollView!.superview!.mouseMoved(with: move)
        try await Task.sleep(for: .milliseconds(550)); pump()
        guard let card = c.hoverPreview.card, let folderView = card.content as? FolderPreviewView,
              let scroll = folderView.tableView.enclosingScrollView else { throw CLIError(description: "HP13 folder preview did not arm") }
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        card.mouseEntered(with: entered)
        func wheel(at point: CGPoint) throws {
            // Start from an AppKit event to retain its window-relative coordinates
            // when converting it to a wheel event, including for offscreen windows.
            let base = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            let event = base.cgEvent!
            event.type = .scrollWheel; event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -80)
            guard let native = NSEvent(cgEvent: event), native.window === window else { throw CLIError(description: "HP13 wheel has no target window") }
            NSApp.sendEvent(native)
            // NSApplication runs local monitors offscreen, but does not route a
            // wheel to the invisible window's views. Use the native scroll view's
            // event entry point only while the card remains under that location.
            if card.superview != nil, card.frame.contains(c.contentView.convert(native.locationInWindow, from: nil)) {
                scroll.scrollWheel(with: native)
            }
            pump()
        }
        let beforeScroll = scroll.contentView.bounds.origin.y
        try wheel(at: scroll.convert(CGPoint(x: 50, y: 150), to: nil))
        let scrolledInside = c.hoverPreview.card === card && c.context.hoverPreviews.request?.kind == .folder(folder.id)
            && scroll.contentView.bounds.origin.y > beforeScroll
        // The pointer flag may lag an exit event: use the wheel's actual location as well.
        try wheel(at: point)
        check(scrolledInside && c.context.hoverPreviews.request == nil && c.hoverPreview.card == nil,
              "HP13 wheel inside folder card scrolls without dismissal; wheel outside dismisses")

        c.hoverPreview.hide(animated: false); c.context.hoverPreviews.dismiss()
        model.windows[0].sidebarWidth = 500
        window.setContentSize(CGSize(width: 640, height: 480)); c.refresh(); pump()
        let smallBounds = c.contentView.bounds
        c.hoverPreview.update(request(pinned[1])); pump()
        let pageFrame = c.hoverPreview.card?.frame ?? .zero
        check(pageFrame.width > 0 && pageFrame.height > 0 && smallBounds.contains(pageFrame) && pageFrame.maxX <= smallBounds.maxX - 8,
              "HP14 page card fits a 640x480 window with a 500 pt sidebar")
        c.hoverPreview.update(SidebarHoverPreviewRequest(kind: .folder(folder.id), anchorInWindow: CGRect(x: 0, y: 0, width: 500, height: 45))); pump()
        guard let smallCard = c.hoverPreview.card, let smallFolder = smallCard.content as? FolderPreviewView,
              let smallScroll = smallFolder.tableView.enclosingScrollView else { throw CLIError(description: "HP14 no small folder card") }
        let folderFrame = smallCard.frame
        smallFolder.tableView.scrollRowToVisible(rows.count - 1); pump()
        check(folderFrame.width > 0 && folderFrame.height > 0 && smallBounds.contains(folderFrame) && folderFrame.maxX <= smallBounds.maxX - 8
              && smallScroll.contentView.bounds.origin.y > 0 && smallFolder.tableView.rows(in: smallScroll.documentVisibleRect).contains(rows.count - 1),
              "HP14 folder card fits a 640x480 window with a 500 pt sidebar and scrolls to its last row")

    }

    private static func folderPeek(_ check: (Bool, String) -> Void) async throws {
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory()
        let space = model.spaces[0], window = model.windows[0]
        let a = model.newTab(in: space.id, url: URL(string: "https://example.invalid/peek-a")!, title: "Peek A")
        let b = model.newTab(in: space.id, url: URL(string: "https://example.invalid/peek-b")!, title: "Peek B")
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Peek integration", withNodes: [a.id, b.id])!
        let c = BrowserWindowController(model: model, windowID: window.id, factory: factory,
                                        size: CGSize(width: 1000, height: 900), defaults: FeatureCLI.defaults())
        defer { c.hoverPreview.hide(animated: false); c.container.closeAll(); c.window?.close() }
        func pump() async { try? await Task.sleep(for: .milliseconds(20)); OffscreenRenderer.settle(c.contentView) }
        _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: b.id, space: space.id)); await pump()
        _ = c.sidebar(c.sidebar, didRequest: .setExpanded(folderID: folder.id, expanded: false)); await pump()
        check(folder.expansion == .peeked(b.id) && c.sidebar.displayedRows.contains(b.id.description), "FP preview fixture uses selected direct child")
        let made = factory.made.count
        let row = c.sidebar.rowFrame(nodeID: folder.id)!
        c.hoverPreview.update(SidebarHoverPreviewRequest(kind: .folder(folder.id), anchorInWindow: c.sidebar.convert(row, to: nil))); await pump()
        check(c.hoverPreview.card != nil && c.hoverPreview.host == nil && factory.made.count == made,
              "FP folder card is native and allocates no web host while peeked")
        let card = c.hoverPreview.card?.content as? FolderPreviewView
        check(card?.displayedTabIDs == [a.id, b.id], "FP folder card contains hidden siblings as well as peek child")
        func choose(_ card: FolderPreviewView?, row: Int) {
            card?.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            card?.tableView.keyDown(with: event)
        }
        choose(card, row: 1); await pump()
        check(folder.expansion == .peeked(b.id) && window.selectedNodeBySpace[space.id] == b.id,
              "FP choosing exposed peek child from real folder results keeps peek")
        c.hoverPreview.update(SidebarHoverPreviewRequest(kind: .folder(folder.id), anchorInWindow: c.sidebar.convert(row, to: nil))); await pump()
        choose(c.hoverPreview.card?.content as? FolderPreviewView, row: 0); await pump()
        check(folder.expansion == .expanded && window.selectedNodeBySpace[space.id] == a.id,
              "FP Q17 hidden folder result expands ancestor chain")
        model.setFolderExpansion(folderID: folder.id, .peeked(b.id)); await pump()
        let beforeUnload = factory.made.count
        _ = c.sidebar(c.sidebar, didRequest: .unloadFolder(folderID: folder.id)); await pump()
        check(c.container.host(for: b.id) == nil && model.tab(id: b.id) === b && folder.expansion == .peeked(b.id)
              && factory.made.dropFirst(beforeUnload).allSatisfy { ![a.id, b.id].contains($0.tabID) }, "FP Q18 unload closes loaded folder hosts, keeps entries/peek, and creates no child host")
        check(c.hoverPreview.card == nil, "FP folder action dismisses card before row interaction")
    }

    // MARK: SP5–SP6 (Separate From Pinned Tab keeps the live host)

    private static func separate(_ check: (Bool, String) -> Void) throws {
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory(), defaults = FeatureCLI.defaults()
        let space = model.spaces[0], pinned = space.pinned.compactMap(\.tab)
        for tab in pinned { tab.pinnedURL = tab.url }
        let c = BrowserWindowController(model: model, windowID: model.windows[0].id, factory: factory,
                                        size: CGSize(width: 1728, height: 1084), defaults: defaults)
        defer { c.container.closeAll(); c.window?.close() }
        func pump() { OffscreenRenderer.settle(c.contentView, runLoop: 0.01) }
        func select(_ tab: Tab) { _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)); pump() }
        pump(); select(pinned[0])
        guard let live = c.container.host(for: pinned[0].id) as? FakeWebContentHost else { throw CLIError(description: "SP5 no live host") }
        live.load(URL(string: "https://elsewhere.example.com/article")!); pump()
        let today = space.today.count
        let ok = c.sidebar(c.sidebar, didRequest: .separateFromPinned(tabID: pinned[0].id)); pump()
        let separated = space.today.first?.tab
        check(ok && space.today.count == today + 1 && separated?.url.host == "elsewhere.example.com"
              && separated.map { c.container.host(for: $0.id) === live } == true && c.container.host(for: pinned[0].id) == nil
              && pinned[0].url == pinned[0].pinnedURL && model.windows[0].selectedNodeBySpace[space.id] == separated?.id && !live.isClosed,
              "SP5 Separate rekeys the live host to the new Today tab (same object, history kept); the pinned tab has no host and its pinned URL")
        factory.refusesAdoption = true
        select(pinned[1])
        guard let second = c.container.host(for: pinned[1].id) as? FakeWebContentHost else { throw CLIError(description: "SP6 no live host") }
        second.load(URL(string: "https://other.example.com/page")!); pump()
        _ = c.sidebar(c.sidebar, didRequest: .separateFromPinned(tabID: pinned[1].id)); pump()
        let next = space.today.first?.tab
        let replacement = next.flatMap { c.container.host(for: $0.id) as? FakeWebContentHost }
        check(second.isClosed && replacement != nil && replacement !== second && replacement?.currentURL == next?.url,
              "SP6 a host that cannot rebind closes; the new tab loads its URL in a new host")
    }

    private static func controller(_ model: BrowserModel, defaults: UserDefaults) -> BrowserWindowController {
        let c = BrowserWindowController(model: model, windowID: model.windows[0].id, factory: FakeWebContentHostFactory(),
                                        size: CGSize(width: 1728, height: 1084), defaults: defaults)
        OffscreenRenderer.settle(c.contentView, runLoop: 0.01)
        return c
    }
    private static func pump(_ c: BrowserWindowController, _ seconds: TimeInterval = 0.01) { OffscreenRenderer.settle(c.contentView, runLoop: seconds) }

    // MARK: DA1–DA5

    private static func deleteAlerts(_ check: (Bool, String) -> Void) throws {
        let model = FeatureCLI.synthetic(), undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let profile = model.profiles[0]
        let first = model.spaces[0], second = model.createSpace(title: "", profileID: profile.id)
        let c = controller(model, defaults: FeatureCLI.defaults())
        defer { if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }; c.container.closeAll(); c.window?.close() }
        func press(_ title: String) {
            guard let alert = c.pendingConfirmation, let button = alert.buttons.first(where: { $0.title == title }) else { return }
            button.performClick(nil); pump(c)
        }
        // DA1: the untitled Space's display title, text, buttons in order, destructive first.
        _ = c.sidebar(c.sidebar, didRequest: .deleteSpace(second.id)); pump(c)
        let alert = c.pendingConfirmation
        let display = model.displayTitle(for: second)
        check(alert != nil && c.window?.attachedSheet === alert?.window
              && alert?.messageText == "Delete your \(display) Space?"
              && alert?.informativeText == "This will archive all the tabs and folders inside it."
              && alert?.buttons.map(\.title) == ["Delete", "Cancel"] && alert?.buttons.first?.hasDestructiveAction == true
              && alert?.buttons.first?.keyEquivalent == "" && alert?.buttons.last?.keyEquivalent == "\u{1b}" && alert?.alertStyle == .warning,
              "DA1 Delete Space shows one sheet: \"Delete your \(display) Space?\", text, Delete (destructive, no Return) then Cancel (Esc)")
        // A second request while the sheet is open is ignored.
        let ignored = c.sidebar(c.sidebar, didRequest: .deleteSpace(first.id))
        check(!ignored && c.pendingConfirmation === alert, "DA1 a second delete request is ignored while the sheet is open")
        let undoCount = undo.canUndo
        press("Cancel")
        check(model.space(id: second.id) != nil && c.pendingConfirmation == nil && c.window?.attachedSheet == nil && undo.canUndo == undoCount,
              "DA2 Cancel changes nothing and registers no undo step")
        _ = c.sidebar(c.sidebar, didRequest: .deleteSpace(second.id)); pump(c)
        press("Delete")
        let gone = model.space(id: second.id) == nil
        undo.undo(); pump(c)
        check(gone && model.space(id: second.id) != nil, "DA3 Delete removes the Space; one undo step restores it")
        // DA4: titled and untitled folders.
        let tabs = first.today.compactMap(\.tab)
        guard let folder = model.createFolder(in: .spaceToday(first.id), title: "Reading", withNodes: [tabs[0].id]),
              let untitled = model.createFolder(in: .spaceToday(first.id), title: "", withNodes: [tabs[1].id]) else {
            throw CLIError(description: "DA4 fixture folders")
        }
        pump(c)
        _ = c.sidebar(c.sidebar, didRequest: .deleteFolder(folderID: folder.id)); pump(c)
        let folderAlert = c.pendingConfirmation
        let titled = folderAlert?.messageText == "Delete your Reading folder?" && folderAlert?.informativeText == "Deleting this folder will archive the tabs inside it."
            && folderAlert?.buttons.map(\.title) == ["Delete Folder", "Cancel"] && folderAlert?.buttons.first?.hasDestructiveAction == true
        press("Delete Folder")
        check(titled && model.node(id: folder.id) == nil && model.tab(id: tabs[0].id) == nil && c.lastToastTitle == "Folder deleted",
              "DA4 folder alert names the folder; Delete Folder archives it and shows \"Folder deleted\" with Undo")
        _ = c.sidebar(c.sidebar, didRequest: .deleteFolder(folderID: untitled.id)); pump(c)
        check(c.pendingConfirmation?.messageText == "Are you sure?", "DA4 an untitled folder's alert reads \"Are you sure?\"")
        press("Cancel")
        check(model.node(id: untitled.id)?.folder != nil, "DA4 Cancel on a folder alert keeps the folder")
        undo.undo(); pump(c)
        check(model.node(id: folder.id)?.folder != nil && model.tab(id: tabs[0].id) != nil, "DA4 toast Undo path (one undo step) restores the folder and its tab")
        // DA5: two folders, one alert, plural toast.
        _ = c.sidebar(c.sidebar, didRequest: .deleteFolders(ids: [folder.id, untitled.id])); pump(c)
        let plural = c.pendingConfirmation?.messageText == "Are you sure?"
        press("Delete Folder")
        check(plural && model.node(id: folder.id) == nil && model.node(id: untitled.id) == nil && c.lastToastTitle == "Folders deleted",
              "DA5 two folders: one \"Are you sure?\" alert and the toast \"Folders deleted\"")
        model.undoManager = nil
    }

    // MARK: DA6–DA7

    private static func toastUndo(_ check: (Bool, String) -> Void) throws {
        let model = FeatureCLI.synthetic(), undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let space = model.spaces[0], tab = space.today[0].id
        guard let folder = model.createFolder(in: .spaceToday(space.id), title: "Undo folder", withNodes: [tab]) else {
            throw CLIError(description: "DA6 fixture folder")
        }
        let c = controller(model, defaults: FeatureCLI.defaults())
        defer { if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }; c.container.closeAll(); c.window?.close() }
        func delete() {
            _ = c.sidebar(c.sidebar, didRequest: .deleteFolder(folderID: folder.id)); pump(c)
            c.pendingConfirmation?.buttons.first?.performClick(nil); pump(c)
        }
        delete()
        let first = c.pressToastUndo(); pump(c)
        let second = c.pressToastUndo(); pump(c)
        check(first && !second && model.node(id: folder.id)?.folder === folder && model.tab(id: tab) != nil,
              "DA6 folder toast Undo restores once, dismisses, and a second click cannot undo folder creation")
        delete()
        let newer = model.newTab(in: space.id, url: URL(string: "https://newer.example/")!, title: "Newer action")
        _ = c.pressToastUndo(); pump(c)
        check(model.node(id: folder.id) == nil && model.tab(id: newer.id) != nil && !c.pressToastUndo(),
              "DA6 folder toast refuses a newer undo target and dismisses")
        undo.undo(); undo.undo(); pump(c)
        delete()
        undo.undo(); pump(c)
        _ = c.pressToastUndo(); pump(c)
        check(model.node(id: folder.id)?.folder === folder && !c.pressToastUndo(),
              "DA6 a normal Undo invalidates the old deletion toast, protecting the earlier operation")
        let before = space.today.map(\.id)
        _ = c.sidebar(c.sidebar, didRequest: .clearToday(space: space.id)); pump(c)
        let cleared = space.today.isEmpty
        let clearFirst = c.pressToastUndo(); pump(c)
        check(cleared && clearFirst && !c.pressToastUndo() && space.today.map(\.id) == before,
              "DA6 Clear Today toast Undo restores once and dismisses")
        _ = c.sidebar(c.sidebar, didRequest: .clearToday(space: space.id)); pump(c)
        let afterClear = model.newTab(in: space.id, url: URL(string: "https://after-clear.example/")!, title: "After Clear")
        _ = c.pressToastUndo(); pump(c)
        check(space.today.map(\.id) == [afterClear.id] && !c.pressToastUndo(),
              "DA6 Clear Today toast refuses a newer undo target and dismisses")
    }

    private static func deleteKeyboardFocus(_ check: (Bool, String) -> Void) throws {
        let model = FeatureCLI.synthetic(), space = model.spaces[0]
        guard let folder = model.createFolder(in: .spaceToday(space.id), at: 0, title: "Focus folder", withNodes: [space.today[0].id]) else {
            throw CLIError(description: "DA7 fixture folder")
        }
        let successor = space.today[1].id
        let c = controller(model, defaults: FeatureCLI.defaults()), outline = c.sidebar.focusedOutline!
        defer { if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }; c.container.closeAll(); c.window?.close() }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            c.window?.makeFirstResponder(outline)
            outline.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window!.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
            pump(c)
        }
        func focusedID() -> ItemID? {
            for row in 0..<outline.numberOfRows where outline.rowView(atRow: row, makeIfNecessary: true)?.isAccessibilityFocused() == true {
                if let tab = outline.item(atRow: row) as? Tab { return tab.id }
                if let folder = outline.item(atRow: row) as? Folder { return folder.id }
            }
            return nil
        }
        func focus(_ id: ItemID) {
            for _ in 0..<(outline.numberOfRows + 1) {
                if focusedID() == id { return }
                key(125)
            }
        }
        func press(_ title: String) {
            c.pendingConfirmation?.buttons.first(where: { $0.title == title })?.performClick(nil); pump(c)
            c.window?.makeFirstResponder(outline); pump(c)
        }
        focus(folder.id); key(51)
        let requested = c.pendingConfirmation != nil && model.node(id: folder.id) != nil
        press("Cancel")
        check(requested && focusedID() == folder.id && model.node(id: folder.id) != nil,
              "DA7 keyboard Delete opens confirmation; Cancel keeps focus on the folder")
        key(51); press("Delete Folder")
        let followed = focusedID() == successor && model.node(id: folder.id) == nil
        key(36)
        check(followed && model.windows[0].selectedNodeBySpace[space.id] == successor,
              "DA7 confirmed keyboard folder delete skips its expanded children, focuses the successor, and Return selects it")
        // Shift selection followed by Delete exercises the asynchronous .deleteFolders path.
        guard let a = model.createFolder(in: .spaceToday(space.id), at: 0, title: "Batch A"),
              let b = model.createFolder(in: .spaceToday(space.id), at: 1, title: "Batch B") else {
            throw CLIError(description: "DA7 batch fixture")
        }
        pump(c)
        // Move up from the surviving tab to the two new rows.
        key(126); key(126)
        key(125, .shift); key(51)
        let batchRequested = c.pendingConfirmation != nil && c.context.selection.ids == [a.id, b.id]
        press("Cancel")
        check(batchRequested && focusedID() == b.id && c.context.selection.ids == [a.id, b.id],
              "DA7 multi-folder Cancel keeps keyboard focus and selection")
        key(51); press("Delete Folder")
        check(model.node(id: a.id) == nil && model.node(id: b.id) == nil && focusedID() == successor,
              "DA7 confirmed multi-folder delete focuses the first surviving successor")
        // A removal from another path can leave a stale focused object. Return/Delete
        // must not activate it or request deletion of that missing node.
        guard let stale = model.createFolder(in: .spaceToday(space.id), at: 0, title: "Stale") else {
            throw CLIError(description: "DA7 stale fixture")
        }
        pump(c); key(126)
        model.archiveNodes(ids: [stale.id]); pump(c)
        let expanded = stale.isExpanded
        var staleRequests = 0
        c.onSidebarIntent = { _ in staleRequests += 1; return nil }
        key(36); key(51)
        check(staleRequests == 0 && stale.isExpanded == expanded && c.pendingConfirmation == nil && model.node(id: successor) != nil,
              "DA7 Return and Delete ignore an outline item removed by another action")
    }

    // MARK: HT1–HT3

    /// Suspends this main-actor job so the hint's scheduled work items can run.
    private static func wait(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private static func hint(_ check: (Bool, String) -> Void) async throws {
        let wasForced = SidebarDiagnostics.forceAnimations
        SidebarDiagnostics.forceAnimations = true
        defer { SidebarDiagnostics.forceAnimations = wasForced }
        let key = BrowserWindowController.hideHintShownKey
        // HT1: the toolbar button (the sidebar's own toggle intent) as the first hide.
        let defaults = FeatureCLI.defaults(), model = FeatureCLI.synthetic(), c = controller(model, defaults: defaults)
        defer { c.container.closeAll(); c.window?.close() }
        _ = c.sidebar(c.sidebar, didRequest: .toggleSidebar); pump(c)
        let hint = c.hintToast, size = c.contentView.bounds.size
        let frame = hint?.frame ?? .zero
        check(hint != nil && c.hintShows == 1 && defaults.bool(forKey: key)
              && abs(frame.maxX - (size.width - 5)) < 0.5 && frame.minY == 4 && frame.height == 47
              && abs(frame.width - 399) <= 3 && abs((hint?.plateFrame.width ?? 0) - 37) <= 1 && hint?.keys == "⌘S",
              String(format: "HT1 first hide by the toolbar button shows the hint at [W − 5 − w, 4, %.0f, 47] (399 ± 3 measured), keycap ⌘S plate %.0f pt; key set", frame.width, hint?.plateFrame.width ?? 0))
        _ = c.sidebar(c.sidebar, didRequest: .toggleSidebar); pump(c)
        check(c.hintToast === hint, "HT1 a show during the hint keeps it")
        c.expireHintToast(); try await wait(0.35)
        _ = c.sidebar(c.sidebar, didRequest: .toggleSidebar); pump(c)
        _ = c.sidebar(c.sidebar, didRequest: .toggleSidebar); c.toggleSidebar(); pump(c)
        check(c.hintShows == 1 && c.hintToast == nil, "HT1 later hides by any path show nothing")
        // HT2: Cmd+S as the first hide, through the window's real key path.
        let defaults2 = FeatureCLI.defaults(), model2 = FeatureCLI.synthetic(), c2 = controller(model2, defaults: defaults2)
        defer { c2.container.closeAll(); c2.window?.close() }
        // The App's dispatcher wiring for this one command (App/MainMenu.swift "toggle-sidebar").
        c2.onCommand = { [weak c2] id in guard id == "toggle-sidebar" else { return false }; c2?.toggleSidebar(); return true }
        c2.onCommandValidation = { id, _ in id == "toggle-sidebar" ? true : nil }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: c2.window!.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                                     isARepeat: false, keyCode: 1)!
        let handled = c2.handleKeyDown(event); pump(c2)
        check(handled && model2.windows[0].sidebarMode == .hidden && c2.hintShows == 1 && defaults2.bool(forKey: key),
              "HT2 Cmd+S as the first hide shows the hint and sets open.sidebar.hideHintShown (C17)")
        // HT3: scheduled lifetime and the fade-out, driven by the forced clock.
        let shownAt = c2.hintShownAt ?? 0
        let deadline = c2.hintFadeDeadline ?? 0
        let fadeIn = c2.hintAnimations["in"]
        c2.expireHintToast()
        let fadeOut = c2.hintAnimations["out"]
        try await wait(0.4)
        check(abs(deadline - shownAt - 5.5) < 1e-9 && abs((fadeIn?.duration ?? 0) - 0.2) < 1e-9 && abs((fadeOut?.duration ?? 0) - 0.25) < 1e-9 && c2.hintToast == nil,
              String(format: "HT3 hint stays %.2f s (5.5), fades in 0.2 s and out 0.25 s, then leaves the window", deadline - shownAt))
    }

    // MARK: GH1–GH5

    private static func gestureHide(_ check: (Bool, String) -> Void) throws {
        let defaults = FeatureCLI.defaults(), model = FeatureCLI.synthetic(), c = controller(model, defaults: defaults)
        defer { c.container.closeAll(); c.window?.close(); Motion.reduceMotionOverride = nil }
        let state = model.windows[0], window = c.window!
        let handleFrame = c.sidebarResizeFrame
        guard let handle = c.contentView.hitTest(CGPoint(x: handleFrame.midX, y: handleFrame.midY)), handle.frame == handleFrame else {
            throw CLIError(description: "GH resize handle is not hit-testable")
        }
        func event(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 400), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func down(_ x: CGFloat, clicks: Int = 1) { handle.mouseDown(with: event(.leftMouseDown, x: x, clicks: clicks)); pump(c) }
        func drag(_ x: CGFloat) { handle.mouseDragged(with: event(.leftMouseDragged, x: x)); pump(c) }
        func up(_ x: CGFloat) { handle.mouseUp(with: event(.leftMouseUp, x: x)); pump(c) }
        let commits = c.sidebarWidthCommits
        down(228); drag(190); drag(150)
        check(c.context.sidebarWidth == 164 && state.sidebarWidth == 228 && c.sidebarWidthCommits == commits && state.sidebarMode == .anchored,
              "GH1 drag to pointer x 150 stops at 164 pt; no model write per tick")
        let gestures = c.sidebarGestureHides
        drag(60)
        let hiddenWhilePressed = state.sidebarMode == .hidden && c.sidebarResizeActive
        up(60)
        check(hiddenWhilePressed && state.sidebarMode == .hidden && state.sidebarWidth == 228 && c.sidebarGestureHides == gestures + 1
              && c.hintShows == 1 && defaults.bool(forKey: BrowserWindowController.hideHintShownKey),
              "GH2 x 60 with the button down hides before mouse-up; release keeps it hidden, width 228, one .sidebarHiddenByGesture (hint shows)")
        c.expireHintToast()
        c.toggleSidebar(); pump(c)
        check(state.sidebarMode == .anchored && c.context.sidebarWidth == 228, "GH2 Cmd+S path restores the width from before the drag (228)")
        down(228); drag(70)
        let hiddenAt70 = state.sidebarMode == .hidden
        drag(120)
        let shownAt120 = state.sidebarMode == .anchored && c.context.sidebarWidth == 164
        let commitsBefore = c.sidebarWidthCommits
        up(120)
        check(hiddenAt70 && shownAt120 && state.sidebarWidth == 164 && c.sidebarWidthCommits == commitsBefore + 1,
              "GH3 x 70 then back to x 120 before release shows it again at 164; release writes 164 once")
        Motion.reduceMotionOverride = true
        down(164); drag(40)
        let reducedHidden = state.sidebarMode == .hidden && c.sidebarAnimations.isEmpty
        up(40)
        check(reducedHidden && state.sidebarMode == .hidden, "GH4 Reduce Motion hides with no slide animation")
        Motion.reduceMotionOverride = nil
        c.toggleSidebar(); pump(c)
        down(164); drag(364); up(364)
        let at364 = state.sidebarWidth == 364
        var resets = c.sidebarWidthCommits
        func doubleClick(_ x: CGFloat) { down(x); up(x); down(x, clicks: 2); up(x) }
        doubleClick(364)
        let reset364 = state.sidebarWidth == 228 && c.sidebarWidthCommits == resets + 1
        down(228); drag(700); up(700)
        let capped = state.sidebarWidth == 500
        resets = c.sidebarWidthCommits
        doubleClick(500)
        check(at364 && reset364 && capped && state.sidebarWidth == 228 && c.sidebarWidthCommits == resets + 1,
              "GH5 double-click on the handle at 364 and 500 sets 228 with one model write; a drag right stops at 500")
    }
}
