import AppKit
import OpenDesign
import OpenFeatures
import OpenModel
import OpenCommands

@MainActor
enum TabSwitcherChecks {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let model = FeatureCLI.synthetic(), state = model.windows[0]
        let tabs = model.spaces[0].pinned.compactMap(\.tab) + model.spaces[0].today.compactMap(\.tab)
        let factory = FakeWebContentHostFactory()
        let c = BrowserWindowController(model: model, windowID: state.id, factory: factory,
                                        size: CGSize(width: 1280, height: 800), defaults: FeatureCLI.defaults())
        defer { c.tabSwitcher.cancel(); c.container.closeAll(); c.window?.close() }
        model.selectNode(windowID: state.id, spaceID: state.focusedSpaceID, nodeID: tabs[0].id); c.refresh()
        let items = tabs.map { TabSwitcherController.Item(id: $0.id, title: $0.displayTitle, subtitle: "example.com") }
        var commits = 0
        c.onCommandValidation = { id, _ in
            id == "tab-switcher-forward" || id == "tab-switcher-backward" ? true : nil
        }
        c.onCommand = { [weak c] id in
            guard let c else { return false }
            guard id == "tab-switcher-forward" || id == "tab-switcher-backward" else { return false }
            c.tabSwitcher.advance(by: id == "tab-switcher-forward" ? 1 : -1, items: items,
                current: c.context.currentTab?.id, in: c.contentView, event: c.tabSwitcherKeyEvent,
                ownsWindow: { [weak c] in c?.ownsAdditionalKeyWindow?($0) == true }) { id in
                commits += 1; model.selectNode(windowID: state.id, spaceID: state.focusedSpaceID, nodeID: id); c.refresh()
            }
            return true
        }
        func key(_ type: NSEvent.EventType = .keyDown, code: UInt16 = 48, flags: NSEvent.ModifierFlags = .control, in window: NSWindow? = nil, characters: String? = nil) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: (window ?? c.window!).windowNumber, context: nil, characters: characters ?? (code == 48 ? "\t" : "\u{1b}"),
                charactersIgnoringModifiers: characters ?? (code == 48 ? "\t" : "\u{1b}"), isARepeat: false, keyCode: code)!
        }
        check(c.handleKeyDown(key()) && c.tabSwitcher.isActive && !c.tabSwitcher.isPresented && c.tabSwitcher.selectedID == tabs[1].id
              && c.context.currentTab?.id == tabs[0].id && commits == 0, "TS1 real key router opens a deferred selection")
        let before = tabs.map(\.lastActiveAt)
        _ = c.handleKeyDown(key())
        check(c.tabSwitcher.selectedID == tabs[2].id && tabs.map(\.lastActiveAt) == before,
              "TS2 second Tab preserves order and activity timestamps")
        // This is a rendering readiness wait, not a timing budget. Other real
        // harness scenarios can queue main-actor work before the reveal job runs.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !c.tabSwitcher.isPresented && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        OffscreenRenderer.settle(c.contentView)
        let image = OffscreenRenderer().snapshot(c.contentView, scale: 1)
        print("INFO TS3 image=\(image.width)x\(image.height) root=\(c.contentView.bounds.size) presented=\(c.tabSwitcher.isPresented) subviews=\(c.tabSwitcher.view?.subviews.count ?? -1) visible=\(c.tabSwitcher.visibleIDs.count)")
        check(image.width == 1280 && image.height == 800 && c.tabSwitcher.isPresented && c.tabSwitcher.view?.subviews.isEmpty == true
              && c.tabSwitcher.visibleIDs.count == TabSwitcherTokens.maximumVisible,
              "TS3 real AppKit surface renders only a visible slice without per-tab views")
        _ = c.tabSwitcher.handle(key(.flagsChanged, code: 59, flags: []))
        check(commits == 1 && c.context.currentTab?.id == tabs[2].id && !c.tabSwitcher.isPresented
              && c.tabSwitcher.items.isEmpty, "TS4 release Control commits once and releases the surface")
        _ = c.handleKeyDown(key(flags: [.control, .shift]))
        check(c.tabSwitcher.selectedID == tabs[1].id, "TS5 Ctrl Shift Tab runs the reverse key route")
        _ = c.handleKeyDown(key(code: 53, flags: []))
        _ = c.tabSwitcher.handle(key(.flagsChanged, code: 59, flags: []))
        check(commits == 1 && c.context.currentTab?.id == tabs[2].id && !c.tabSwitcher.isPresented,
              "TS6 Escape cancels and later release cannot commit")
        let many = (0..<1000).map { TabSwitcherController.Item(id: ItemID(), title: "Tab \($0)", subtitle: "example.com") }
        c.tabSwitcher.advance(by: 500, items: many, current: many[0].id, in: c.contentView, event: key()) { _ in }
        check(c.tabSwitcher.visibleIDs.count == 5 && c.tabSwitcher.view?.subviews.isEmpty == true
              && c.tabSwitcher.view?.frame.width == 964, "TS7 1000 tabs retain one bounded drawing view")
        c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        check(!c.tabSwitcher.isActive && c.tabSwitcher.items.isEmpty && c.tabSwitcher.view == nil,
              "TS8 losing window focus cancels and hidden switcher has no live work")
        c.tabSwitcher.advance(by: 1, items: [], current: nil, in: c.contentView, event: key()) { _ in }
        check(!c.tabSwitcher.isPresented, "TS9 empty window does not create a switcher")
        c.tabSwitcher.advance(by: 1, items: items, current: nil, in: c.contentView, event: key()) { _ in }
        check(c.tabSwitcher.selectedID == items[0].id, "TS10 empty Space starts with the most recent candidate")
        c.tabSwitcher.cancel()
        func resetSelection() {
            c.tabSwitcher.cancel()
            model.selectNode(windowID: state.id, spaceID: state.focusedSpaceID, nodeID: tabs[0].id); c.refresh()
        }
        func bindForward(_ modifiers: ShortcutModifiers) {
            var bindings = KeyBindingStore.empty
            bindings.setOverride(KeyBindingOverride(shortcuts: [KeyboardShortcut(key: "f6", modifiers: modifiers)]), for: "tab-switcher-forward")
            c.keyBindingOverrides = bindings
        }
        resetSelection(); bindForward([])
        var previousCommits = commits
        let bareHandled = c.handleKeyDown(key(code: 97, flags: .function, characters: "\u{f709}"))
        check(bareHandled && commits == previousCommits + 1 && c.context.currentTab?.id == tabs[1].id
              && !c.tabSwitcher.isActive && c.tabSwitcher.view == nil && !c.tabSwitcher.isMonitoringModifiers,
              "TS11 bare F6 binding switches immediately without a session")

        resetSelection(); bindForward([.command, .option]); previousCommits = commits
        let chordHandled = c.handleKeyDown(key(code: 97, flags: [.command, .option, .function], characters: "\u{f709}"))
        NSApp.sendEvent(key(.flagsChanged, code: 55, flags: .option))
        let stillHeld = c.tabSwitcher.isActive && commits == previousCommits && c.context.currentTab?.id == tabs[0].id
        NSApp.sendEvent(key(.flagsChanged, code: 58, flags: []))
        check(chordHandled && stillHeld && commits == previousCommits + 1 && c.context.currentTab?.id == tabs[1].id
              && !c.tabSwitcher.isActive && !c.tabSwitcher.isMonitoringModifiers,
              "TS12 Cmd Option binding commits only after both modifiers release")

        resetSelection(); c.keyBindingOverrides = .empty; previousCommits = commits
        let auxiliary = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        defer { c.ownsAdditionalKeyWindow = nil; auxiliary.close() }
        c.ownsAdditionalKeyWindow = { $0 === auxiliary }
        let auxiliaryHandled = c.handleKeyDown(key(in: auxiliary))
        NSApp.sendEvent(key(.flagsChanged, code: 59, flags: [], in: auxiliary))
        check(auxiliaryHandled && commits == previousCommits + 1 && c.context.currentTab?.id == tabs[1].id
              && !c.tabSwitcher.isActive && !c.tabSwitcher.isMonitoringModifiers,
              "TS13 auxiliary window Control release commits through owned event path")

        resetSelection(); previousCommits = commits
        let deactivateHandled = c.handleKeyDown(key())
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        check(deactivateHandled && commits == previousCommits && c.context.currentTab?.id == tabs[0].id
              && !c.tabSwitcher.isActive && c.tabSwitcher.view == nil && !c.tabSwitcher.isMonitoringModifiers
              && c.tabSwitcher.pendingSnapshotCount == 0,
              "TS14 app deactivation cancels session and all pending work")
        c.tabSwitcher.cancel()
        c.onCommand = nil
    }
}
