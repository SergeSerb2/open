import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

@MainActor
private final class PreviewIntentRecorder: SidebarDelegate {
    var events: [(SidebarIntent, TimeInterval)] = []
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        events.append((intent, ProcessInfo.processInfo.systemUptime))
        return ModelSidebarActions(context: sidebar.context).perform(intent)
    }
}

/// Real offscreen sidebar events, real timer deadlines, native folder/search
/// controls, and the Profile model. Page hosts and the sweep trigger stay in A.
@MainActor
enum PreviewChecks {
    static func run() {
        let check = Checks.check
        let suite = "com.open.sidebar-preview-check.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "open.general.previewsEnabled")
        preferences.set(0.5, forKey: "open.general.previewsDelaySeconds")
        let model = Synthetic.model(), state = model.windows[0], space = model.spaces[0]
        let context = SidebarContext(model: model, windowID: state.id, previewPreferences: preferences)
        let recorder = PreviewIntentRecorder()
        var options = RenderScene.Options(); options.size = CGSize(width: 1100, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: recorder)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { context.hoverPreviews.dismiss(); host.contentView = nil; host.close() }
        let sidebar = scene.sidebar, outline = sidebar.focusedOutline!
        func pump(_ duration: TimeInterval = 0.005) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration)); OffscreenRenderer.settle(scene)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: host.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func hover(_ id: ItemID) {
            let frame = sidebar.rowFrame(nodeID: id)!
            let point = sidebar.convert(CGPoint(x: 100, y: frame.midY), to: nil)
            outline.enclosingScrollView!.superview!.mouseMoved(with: mouse(.mouseMoved, point))
        }
        func escape() {
            outline.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            pump()
        }
        let pinned = space.pinned[0].tab!, today = space.today[0].tab!
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Preview folder")!
        pump()
        hover(pinned.id)
        check(!context.hoverPreviews.hasInstalledWork && context.hoverPreviews.scheduledShowCount == 0,
              "HP2 disabled hover schedules no timer and installs no monitor/observer work")
        preferences.set(true, forKey: "open.general.previewsEnabled"); pump()
        let schedules = TooltipController.shared.scheduleCount
        // Logic, not wall clock: read the scheduled delay and deadline back.
        // A second hover on the same row must keep the first deadline.
        hover(pinned.id)
        let pinnedDelay = context.hoverPreviews.scheduledShowDelay
        let pinnedDeadline = context.hoverPreviews.scheduledShowDeadline
        hover(pinned.id)
        check(context.hoverPreviews.isArmed && context.hoverPreviews.request == nil && context.hoverPreviews.scheduledShowCount == 1 &&
              pinnedDelay == 0.5 && pinnedDeadline != nil && context.hoverPreviews.scheduledShowDeadline == pinnedDeadline,
              "HP1 moving inside the pinned row does not restart its 0.5 s task")
        check(TooltipController.shared.scheduleCount == schedules, "HP6 an armed preview suppresses row tooltip scheduling")
        let delivered = Checks.waitFor(settle: scene) { context.hoverPreviews.request != nil }
        let shown = recorder.events.first { if case .hoverPreview(.some) = $0.0 { true } else { false } }
        check(delivered && shown != nil && pinnedDelay == 0.5 && context.hoverPreviews.request?.kind == .page(tabID: pinned.id),
              "HP1 pinned row emits the App request at its scheduled 0.5 s deadline")
        let sourceFrame = sidebar.rowFrame(nodeID: pinned.id)!
        check(context.hoverPreviews.request?.anchorInWindow == sidebar.convert(sourceFrame, to: nil), "HP1 request carries the real row's window anchor")
        escape(); pump(1.01)
        // The one real wall-clock check for this timer family. Machine load
        // can delay a single run, so allow up to 3 attempts; each attempt
        // prints its measured lateness and the 1-minute load average.
        var attempts: [String] = []
        var realtimeOK = false
        for attempt in 1...3 {
            recorder.events = []
            let liveStart = ProcessInfo.processInfo.systemUptime
            hover(pinned.id)
            var firedAt: TimeInterval?
            while ProcessInfo.processInfo.systemUptime - liveStart < 2.0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                if let event = recorder.events.first(where: { if case .hoverPreview(.some) = $0.0 { true } else { false } }) { firedAt = event.1; break }
            }
            let load = Checks.loadAverage1()
            let elapsed = firedAt.map { $0 - liveStart }
            attempts.append(elapsed.map { String(format: "attempt %d fired at %.3f s (lateness %+.0f ms), load1 %.2f", attempt, $0, ($0 - 0.5) * 1000, load) }
                            ?? String(format: "attempt %d no request within 2 s, load1 %.2f", attempt, load))
            print("  .. HP1 real-time \(attempts.last!)")
            if let elapsed, (0.45...0.55).contains(elapsed) { realtimeOK = true; break }
            escape(); pump(1.01)
        }
        check(realtimeOK, "HP1 real-time 5 ms run-loop slices deliver preview at 0.5 s ±50 ms — \(attempts.joined(separator: "; "))")
        context.hoverPreviews.setPointerInsidePreview(true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host)
        check(context.hoverPreviews.request == nil, "HP5 captured source window resignation dismisses a preview held by the card")
        escape(); pump(1.01)
        recorder.events = []
        hover(folder.id)
        let folderDelay = context.hoverPreviews.scheduledShowDelay
        let folderDelivered = Checks.waitFor(settle: scene) { context.hoverPreviews.request?.kind == .folder(folder.id) }
        check(folderDelay == 0.5 && folderDelivered && recorder.events.contains { if case .hoverPreview(.some) = $0.0 { true } else { false } },
              "HP1 folder row emits its request at the configured deadline")
        escape(); pump(1.01)
        let tile = sidebar.favoritesCollection.item(at: IndexPath(item: 0, section: 0))!.view
        let favoriteID = model.profiles[0].favorites[0].id
        recorder.events = []
        tile.mouseEntered(with: mouse(.mouseEntered, tile.convert(CGPoint(x: 10, y: 10), to: nil)))
        let favoriteDelay = context.hoverPreviews.scheduledShowDelay
        let favoriteDelivered = Checks.waitFor(settle: scene) { context.hoverPreviews.request?.kind == .page(tabID: favoriteID) }
        check(favoriteDelay == 0.5 && favoriteDelivered && recorder.events.contains { if case .hoverPreview(.some) = $0.0 { true } else { false } },
              "HP1 Favorite tile emits its page request after 0.5 s")
        tile.mouseExited(with: mouse(.mouseExited, .zero)); context.hoverPreviews.setPointerInsidePreview(true)
        check(context.hoverPreviews.request != nil && context.hoverPreviews.scheduledHideDelay == nil, "HP4 entering the preview card cancels the outside-row dismissal")
        context.hoverPreviews.setPointerInsidePreview(false)
        let hideDelay = context.hoverPreviews.scheduledHideDelay
        let hidden = Checks.waitFor(settle: scene) { context.hoverPreviews.request == nil }
        check(hideDelay == 0.25 && hidden, "HP4 leaving row and card hides after 0.25 s")
        let count = context.hoverPreviews.scheduledShowCount
        hover(folder.id)
        check(context.hoverPreviews.request?.kind == .folder(folder.id) && context.hoverPreviews.scheduledShowCount == count,
              "HP4 another target within one second swaps immediately without a new show task")
        _ = sidebar.contextMenu(nodeID: folder.id)
        check(context.hoverPreviews.request == nil, "HP5 requesting the production row menu dismisses its preview")
        hover(pinned.id)
        let drag = SidebarDragEvent(ids: [today.id], window: host)
        _ = outline.dataSource?.outlineView?(outline, validateDrop: drag, proposedItem: folder, proposedChildIndex: -1)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP5 a production drag destination cancels shown and armed previews")
        outline.draggingExited(drag)
        hover(pinned.id)
        model.focusSpace(windowID: state.id, spaceID: model.spaces[1].id); pump()
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP5 real Space switch dismisses preview state")
        model.focusSpace(windowID: state.id, spaceID: space.id); pump()
        let oldCount = context.hoverPreviews.scheduledShowCount
        hover(today.id); pump(0.53)
        check(context.hoverPreviews.request == nil && context.hoverPreviews.scheduledShowCount == oldCount, "HP1 Today rows never arm a preview")
        let paneA = model.newTab(in: space.id, url: Synthetic.url("hover-pane-a"), title: "Hover pane A")
        let paneB = model.newTab(in: space.id, url: Synthetic.url("hover-pane-b"), title: "Hover pane B")
        let split = model.makeSplit(tabIDs: [paneA.id, paneB.id])!; pump()
        hover(split.id); pump(0.53)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP1 split rows never arm a preview")
        sidebar.beginRename(nodeID: pinned.id); pump()
        hover(pinned.id)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP5 the real inline editor blocks previews")
        (host.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        host.makeFirstResponder(outline); pump()
        hover(folder.id); pump(0.53)
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!
        outline.enclosingScrollView!.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP5 scrolling the real list dismisses its preview")
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: pinned.id); pump()
        hover(pinned.id); pump(0.53)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP1 the current pinned row never previews itself")
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: favoriteID); pump()
        tile.mouseEntered(with: mouse(.mouseEntered, .zero)); pump(0.53)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP1 the current Favorite never previews itself")
        tile.mouseExited(with: mouse(.mouseExited, .zero))
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: nil); pump()
        preferences.set(false, forKey: "open.general.previewsFolders"); pump()
        hover(folder.id); pump(0.53)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP2 the Folders source switch gates the real row")
        preferences.set(true, forKey: "open.general.previewsFolders")
        preferences.set(false, forKey: "open.general.previewsPages"); pump()
        hover(pinned.id); pump(0.53)
        check(context.hoverPreviews.request == nil && !context.hoverPreviews.isArmed, "HP2 the Pinned tabs and Favorites switch gates page previews")
        preferences.set(false, forKey: "open.general.previewsEnabled"); pump()
        hover(pinned.id)
        check(!context.hoverPreviews.hasInstalledWork, "HP2 disabling an existing tracker removes its installed work")

        checkFolder(context: context, folder: folder, scene: scene)
        checkBanner(context: context, scene: scene, recorder: recorder)
    }

    private static func checkFolder(context: SidebarContext, folder: Folder, scene: RenderScene) {
        let model = context.model, space = context.focusedSpace!
        let nested = model.createFolder(in: .folder(folder.id), title: "Nested")!
        for index in 0..<11 {
            let tab = model.newTab(in: space.id, url: Synthetic.url("preview-\(index)"), title: index == 3 ? "Needle document" : "Preview page \(index)")
            model.moveNode(id: tab.id, to: index == 3 ? .folder(nested.id) : .folder(folder.id), at: nil)
        }
        let paneA = model.newTab(in: space.id, url: Synthetic.url("preview-split-a"), title: "Split preview A")
        let paneB = model.newTab(in: space.id, url: Synthetic.url("preview-split-b"), title: "Split preview B")
        let split = model.makeSplit(tabIDs: [paneA.id, paneB.id])!
        model.moveNode(id: split.id, to: .folder(folder.id), at: nil)
        model.setExpanded(folderID: folder.id, expanded: false); model.setExpanded(folderID: nested.id, expanded: false)
        OffscreenRenderer.settle(scene, runLoop: 0.005)
        let card = FolderPreviewView(context: context, folder: folder)
        let host = OffscreenRenderer.host(card, scale: 1)
        defer { host.contentView = nil; host.close() }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); OffscreenRenderer.settle(card); OffscreenRenderer.settle(scene) }
        Checks.check(card.bounds.width == 300 && card.fittingSize.height == 392 && card.tableView.rowHeight == 32 && !card.searchField.isHidden && card.searchField.frame.height == 24,
                     "HP3 real native folder card is 300 wide, has 32 pt rows, search above eight tabs, and ten visible rows")
        for icon in [String?.none, "⭐️", "star.fill"] {
            folder.customIcon = icon; pump()
            _ = OffscreenRenderer().snapshot(scene, scale: 1); _ = OffscreenRenderer().snapshot(card, scale: 1)
            Checks.check(card.drawnHeaderGlyph != nil && scene.sidebar.drawnFolderGlyph(nodeID: folder.id) == card.drawnHeaderGlyph, "HP3 actual row/header glyphs match for \(icon ?? "folder glyph")")
        }
        context.folderIconOverrideProvider = { _ in "heart.fill" }; folder.customIcon = "⭐️"; pump()
        Checks.check(card.drawnHeaderGlyph == "heart.fill" && scene.sidebar.drawnFolderGlyph(nodeID: folder.id) == "heart.fill", "HP3 shared iconOverride provider precedes customIcon in row and header")
        context.folderIconOverrideProvider = nil; folder.customIcon = nil; pump()
        model.setExpanded(folderID: folder.id, expanded: true); pump()
        Checks.check(card.headerIconView.frame == CGRect(x: 10, y: 8, width: 20, height: 20), "HP3 header uses the row's 20 pt icon canvas, centered on the 36 pt header")
        Checks.check(card.drawnHeaderGlyph == "folder.open" && scene.sidebar.drawnFolderGlyph(nodeID: folder.id) == "folder.open", "HP3 row and header both draw the open folder glyph without customIcon")
        model.setExpanded(folderID: folder.id, expanded: false); pump()
        let before = OffscreenRenderer().snapshot(card, scale: 1)
        folder.customIcon = "⭐️"; pump()
        let after = OffscreenRenderer().snapshot(card, scale: 1)
        Checks.check(card.displayedHeaderIcon == "⭐️" && (before.dataProvider!.data! as Data) != (after.dataProvider!.data! as Data), "HP3 custom folder icon changes the actual header pixels")
        host.makeFirstResponder(card.searchField)
        let editor = card.searchField.currentEditor() as! NSTextView
        editor.selectAll(nil); editor.insertText("Needle", replacementRange: NSRange(location: 0, length: editor.string.utf16.count)); pump()
        let needle = nested.children[0].tab!
        Checks.check(card.displayedTabIDs == [needle.id] && card.tableView.numberOfRows == 1, "HP3 real search field filters the depth-first native rows")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        Checks.check(host.firstResponder === card.tableView, "HP3 Down from the real search editor focuses the result rows")
        for code in [UInt16(36)] {
            card.tableView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        pump()
        Checks.check(context.selectedID(in: space.id) == needle.id && folder.isExpanded && nested.isExpanded, "HP3 Down/Return selects through the model and expands the folder chain")
        host.makeFirstResponder(card.searchField)
        let splitEditor = card.searchField.currentEditor() as! NSTextView
        splitEditor.selectAll(nil); splitEditor.insertText("Split preview B", replacementRange: NSRange(location: 0, length: splitEditor.string.utf16.count)); pump()
        splitEditor.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump()
        Checks.check(context.selectedID(in: space.id) == split.id && split.focusedPaneID == paneB.id, "HP3 Return from search selects the real split and focuses its matching pane")
        host.makeFirstResponder(card.searchField)
        let emptyEditor = card.searchField.currentEditor() as! NSTextView
        emptyEditor.selectAll(nil); emptyEditor.insertText("No matching title", replacementRange: NSRange(location: 0, length: emptyEditor.string.utf16.count)); pump()
        emptyEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        Checks.check(card.displayedTabIDs.isEmpty && context.selectedID(in: space.id) == split.id, "HP3 a no-match search has no activation on Return")
        for width in [228.0, 500.0] {
            context.window?.sidebarWidth = width; card.needsLayout = true; pump()
            Checks.check(card.fittingSize.width == 300, "HP3 folder card stays 300 pt at sidebar width \(Int(width))")
        }
        let empty = model.createFolder(in: .spacePinned(space.id), title: "Empty preview")!
        let emptyCard = FolderPreviewView(context: context, folder: empty)
        Checks.check(emptyCard.displayedTabIDs.isEmpty && emptyCard.searchField.isHidden, "HP3 empty folder has no selectable rows or search field")
    }

    private static func checkBanner(context: SidebarContext, scene: RenderScene, recorder: PreviewIntentRecorder) {
        let sidebar = scene.sidebar, preferences = context.previewPreferences
        let profile = context.model.profile(id: context.focusedSpace!.profileID)!
        context.autoArchiveBannerRequested = true
        func pump() { scene.needsLayout = true; OffscreenRenderer.settle(scene, runLoop: 0.005) }
        pump()
        for width in [228.0, 500.0] {
            context.window?.sidebarWidth = width; pump()
            let banner = sidebar.autoArchiveBanner!, height = banner.height(for: width - 16)
            Checks.check(banner.frame == CGRect(x: 8, y: scene.bounds.height - 50 - 8 - height, width: width - 16, height: height) &&
                         sidebar.bannerContentInset == 0 && sidebar.focusedOutline?.enclosingScrollView?.contentInsets.bottom == 0 &&
                         sidebar.convert(sidebar.focusedOutline!.enclosingScrollView!.bounds, from: sidebar.focusedOutline!.enclosingScrollView!).maxY == banner.frame.minY - 8 &&
                         NSColor(cgColor: banner.layer!.backgroundColor!)!.alphaComponent == 1 &&
                         banner.dismissButton.frame.minY >= banner.messageView.frame.maxY + 8,
                         "BN1 opaque banner, unclipped text, and list ending 8 pt above card at width \(Int(width)) (height \(Int(height)))")
        }
        let originalSpace = context.focusedSpace!, originalAppearance = context.systemAppearance
        for space in [context.model.spaces[0], context.model.spaces[2]] {
            context.model.focusSpace(windowID: context.windowID, spaceID: space.id)
            for appearance in [ContentAppearance.light, .dark] {
                context.systemAppearance = appearance
                for width in [228.0, 500.0] {
                    context.window?.sidebarWidth = width; pump()
                    let banner = sidebar.autoArchiveBanner!
                    func luminance(_ color: NSColor) -> Double {
                        let c = color.usingColorSpace(.sRGB)!
                        func linear(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
                        return linear(c.redComponent)*0.2126 + linear(c.greenComponent)*0.7152 + linear(c.blueComponent)*0.0722
                    }
                    let link = banner.messageView.linkTextAttributes![.foregroundColor] as! NSColor
                    Checks.check(banner.messageView.alwaysUnderline && banner.messageView.linkTextAttributes?[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue,
                                 "BN1 Settings remains underlined in \(appearance)")
                    if space === context.model.spaces[2] && appearance == .light {
                        let ink = link.usingColorSpace(.sRGB)!
                        Checks.check(ink.blueComponent > ink.redComponent + 0.15 && ink.blueComponent > ink.greenComponent + 0.15,
                                     "BN1 unthemed light Settings keeps the passing blue Space accent")
                    }
                    let bg = NSColor(cgColor: banner.layer!.backgroundColor!)!
                    let a = luminance(link), b = luminance(bg), ratio = (max(a,b)+0.05)/(min(a,b)+0.05)
                    let bottom = sidebar.convert(sidebar.focusedOutline!.enclosingScrollView!.bounds, from: sidebar.focusedOutline!.enclosingScrollView!).maxY
                    Checks.check(ratio >= 4.5 && bg.alphaComponent == 1 && bottom == banner.frame.minY-8, "BN1/BN4 \(context.title(of: space)) \(appearance) width \(Int(width)): opaque card, no row overlap, link contrast \(String(format: "%.2f",ratio)):1 ≥ 4.5:1")
                }
            }
        }
        context.model.focusSpace(windowID: context.windowID, spaceID: originalSpace.id)
        context.systemAppearance = originalAppearance; pump()
        for (interval, label) in [(AutoArchiveInterval.oneHour, "1 hour"), (.sixHours, "6 hours"), (.twelveHours, "12 hours"), (.twentyFourHours, "24 hours"), (.sevenDays, "7 days"), (.thirtyDays, "30 days")] {
            var settings = profile.settings; settings.autoArchiveAfter = interval; profile.settings = settings; pump()
            Checks.check(sidebar.autoArchiveBanner?.thresholdText == label && sidebar.autoArchiveBanner?.message.contains("past \(label).") == true,
                         "BN3 banner uses the Profile's real \(label) threshold")
        }
        let banner = sidebar.autoArchiveBanner!
        Checks.check(banner.message.contains("haven’t") && !banner.message.contains("haven't"), "BN1 banner uses the curly apostrophe")
        let button = banner.dismissButton
        let pointOnButton = button.convert(CGPoint(x: 12, y: 12), to: nil)
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: pointOnButton, modifierFlags: [], timestamp: 0, windowNumber: scene.window!.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        button.mouseEntered(with: enter)
        Checks.check(button.layer?.backgroundColor == GrayScale.a(5).cgColor(button.contentAppearance), "BN2 Got it hover uses GrayA5")
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: pointOnButton, modifierFlags: [], timestamp: 0, windowNumber: scene.window!.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        button.mouseExited(with: exit)
        Checks.check(button.layer?.backgroundColor == GrayScale.a(4).cgColor(button.contentAppearance), "BN2 Got it exit restores GrayA4")
        var capturedPressed = false
        let probe = Timer(timeInterval: 0.01, repeats: false) { _ in MainActor.assumeIsolated {
            capturedPressed = button.layer?.backgroundColor == GrayScale.a(6).cgColor(button.contentAppearance)
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: pointOnButton, modifierFlags: [], timestamp: 0.02, windowNumber: scene.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            NSApp.postEvent(release, atStart: true)
        } }
        RunLoop.main.add(probe, forMode: .eventTracking)
        button.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: pointOnButton, modifierFlags: [], timestamp: 0, windowNumber: scene.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        probe.invalidate()
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        Checks.check(capturedPressed && button.layer?.backgroundColor == GrayScale.a(4).cgColor(button.contentAppearance), "BN2 native mouse tracking uses GrayA6 while pressed and restores GrayA4")
        banner.dismissButton.performClick(nil)
        Checks.check(recorder.events.last?.0 == .dismissAutoArchiveBanner, "BN2 native Got it button sends the App dismissal intent")
        let text = banner.messageView
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let range = (text.string as NSString).range(of: "Settings")
        let glyphs = text.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = text.layoutManager!.boundingRect(forGlyphRange: glyphs, in: text.textContainer!)
        let point = text.convert(CGPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: scene.window!.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: true); text.mouseDown(with: event(.leftMouseDown)); pump()
        Checks.check(recorder.events.last?.0 == .openProfileSettings(profile.id), "BN2 clicking the real Settings text link sends the current Profile ID")
        preferences.set(true, forKey: "open.sidebar.autoArchiveBannerDismissed"); sidebar.refreshAutoArchiveBanner(); pump()
        Checks.check(sidebar.autoArchiveBanner == nil && sidebar.bannerContentInset == 0, "BN4 dismissed banner is hidden and restores the list inset")
        preferences.set(false, forKey: "open.sidebar.autoArchiveBannerDismissed")
        preferences.set(false, forKey: "open.sidebar.autoArchiveBannerEligible"); sidebar.refreshAutoArchiveBanner(); pump()
        Checks.check(sidebar.autoArchiveBanner == nil, "BN4 ineligible windows show no banner")
        preferences.set(true, forKey: "open.sidebar.autoArchiveBannerEligible")
        var settings = profile.settings; settings.autoArchiveAfter = .never; profile.settings = settings; pump()
        Checks.check(sidebar.autoArchiveBanner == nil, "BN3 never-archive Profile has no education threshold or banner")
    }
}
