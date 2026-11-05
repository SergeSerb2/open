import AppKit
import OpenCommandBar
import OpenDesign
import OpenFeatures
import OpenModel
import OpenStore

/// Production windows, command bar, picker, model and SQLite. Only page content is fake.
/// All windows remain unordered. App key routing and native pixel comparison are Step 6b gates.
@MainActor
enum LittleOpenChecks {
    static let screen = LittleOpenScreen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410))
    static func run(_ check: (Bool, String) -> Void) async throws {
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory(), defaults = FeatureCLI.defaults()
        model.windows = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("little-open-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ArchiveStore(fileURL: root.appendingPathComponent("archive.sqlite3"))
        let little = LittleOpenCoordinator(model: model, archiveSink: archive, screenProvider: { screen }) { profile in
            factory.makeHost(tabID: ItemID(), profileID: profile, url: nil)! as! FakeWebContentHost
        }
        little.presentWindows = false; little.defaults = defaults; little.isActionEnabled = { _, _ in true }
        defer { little.closeAll() }
        func blank(_ timestamp: TimeInterval? = nil) -> LittleOpenWindowController {
            little.openBlank(focusURLField: true, keyDownTimestamp: timestamp)
            return little.controllers[little.sessions[0].id]!
        }
        func pump(_ c: LittleOpenWindowController) { OffscreenRenderer.settle(c.contentView, runLoop: 0.01) }
        func type(_ c: LittleOpenWindowController, _ text: String) async throws {
            c.focusURL(); pump(c)
            guard let editor = c.window?.firstResponder as? NSTextView else { throw CLIError(description: "Little Open did not focus its real field editor") }
            editor.insertText(text, replacementRange: editor.selectedRange())
            for _ in 0..<100 {
                pump(c)
                if c.commandBar.appliedQuery == c.commandBar.text && c.commandBar.isSnapshotFinal { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CLIError(description: "Little Open suggestion snapshot timed out")
        }
        func key(_ window: NSWindow, code: UInt16, text: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        let first = blank(); pump(first)
        let barFrame = CGRect(x: 2050, y: 1061, width: 490, height: 329)
        check(first.window?.frame == barFrame && first.state == .bar && model.windows.isEmpty && !first.window!.isVisible,
              "L1 fixed screen: bar frame \(first.window!.frame), no main window or on-screen window")
        check(first.commandBar.request?.mode == .littleOpen && first.commandBar.view.debugUsesOwnFieldEditor
              && first.commandBar.view.panelFrame == CGRect(x: 0, y: 0, width: 490, height: 329)
              && first.commandBar.view.debugCloseFrame == CGRect(x: 443, y: 19, width: 26, height: 26)
              && first.commandBar.view.debugHasCloseButton && !first.commandBar.view.debugPress("info")
              && !first.window!.styleMask.contains(.resizable)
              && [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { first.window!.standardWindowButton($0)?.isHidden == true },
              "L1 focused embedded .littleOpen field, x [443,19,26,26], no info/traffic lights/resize")
        let second = blank(); pump(second)
        check(little.sessions.count == 2 && second.window?.frame == barFrame, "L1 second blank makes a new window at the same frame")
        little.closeAll()
        little.open(url: URL(string: "https://example.com/path#one")!, profileHint: nil)
        let reused = little.sessions[0].id, loads = factory.made.last!.loadCount
        little.open(url: URL(string: "https://EXAMPLE.com:443/path#two")!, profileHint: nil)
        check(little.sessions.count == 1 && little.sessions[0].id == reused && factory.made.last!.loadCount == loads,
              "L1 canonical URL resurface, no reload")
        little.closeAll()

        let page = blank(); pump(page)
        let corner = CGPoint(x: page.window!.frame.maxX, y: page.window!.frame.maxY)
        page.container.host(for: page.session.tab.id)!.load(URL(string: "https://www.example.com/page")!); pump(page)
        check(page.state == .page && page.window!.frame.size == CGSize(width: 1185, height: 832)
              && CGPoint(x: page.window!.frame.maxX, y: page.window!.frame.maxY) == corner,
              "L4 committed URL: page \(page.window!.frame), fixed top-right \(corner)")
        check(page.container.frame == CGRect(x: 0, y: 0, width: 1185, height: 785)
              && page.container.slots[0].contentHostView?.frame == page.container.bounds
              && page.titleBar.hostButton.title == "example.com" && page.titleBar.profileButton.isHidden,
              "L4 full-bleed page [0,47,1185,785], host strips www., single Profile hides chip")
        for width: CGFloat in [1185, 800] {
            page.window!.setFrame(CGRect(x: 0, y: 0, width: width, height: 832), display: false); pump(page)
            let f = page.titleBar.elementFrames
            let expected: [String: CGRect] = ["capsule": CGRect(x: 84, y: 8, width: width - 289, height: 31),
                "copy": CGRect(x: width - 228, y: 16, width: 16, height: 16), "pill": CGRect(x: width - 196, y: 8, width: 188, height: 30),
                "open": CGRect(x: width - 191, y: 15, width: 148, height: 17), "chevron": CGRect(x: width - 29, y: 15, width: 16, height: 16)]
            check(expected.allSatisfy { key, rect in f[key].map { abs($0.minX - rect.minX) <= 0.5 && abs($0.minY - rect.minY) <= 0.5 && abs($0.width - rect.width) <= 0.5 && abs($0.height - rect.height) <= 0.5 } ?? false },
                  "L4 measured title-bar frames at W=\(width): \(f)")
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { page.window!.standardWindowButton($0) }
            let frames = buttons.map { page.contentView.convert($0.bounds, from: $0) }.map { CGRect(x: $0.minX, y: 832 - $0.maxY, width: $0.width, height: $0.height) }
            check(frames == [9,32,55].map { CGRect(x: $0, y: 16, width: 16, height: 16) } && buttons.allSatisfy { !$0.isHidden }, "L4 traffic lights at W=\(width): \(frames)")
        }
        let clamped = LittleOpenCoordinator(model: model, archiveSink: nil, screenProvider: {
            LittleOpenScreen(frame: CGRect(x: 100, y: 200, width: 900, height: 650), visibleFrame: CGRect(x: 100, y: 200, width: 900, height: 650))
        }) { profile in factory.makeHost(tabID: ItemID(), profileID: profile, url: nil)! as! FakeWebContentHost }
        clamped.presentWindows = false; clamped.defaults = defaults
        clamped.open(url: URL(string: "https://clamp.example/")!, profileHint: nil)
        let clampedWindow = clamped.controllers[clamped.sessions[0].id]!.window!
        check(clampedWindow.frame == CGRect(x: 120, y: 220, width: 860, height: 610)
              && clampedWindow.minSize == CGSize(width: 360, height: 240) && clampedWindow.frameAutosaveName.isEmpty
              && clampedWindow.animationBehavior == .none, "L4 screen clamp [120,220,860,610], min 360×240, no autosave/animation")
        clamped.closeAll()
        let otherProfile = model.createProfile(name: "Work")!
        model.focusSpace(windowID: model.createWindow(focusedSpaceID: model.spaces[0].id)!.id, spaceID: model.spaces[0].id)
        let destination = model.createSpace(title: "Reading", profileID: page.session.profileID, icon: .emoji("📘"))
        let third = model.createSpace(title: "Studio", profileID: page.session.profileID, icon: .emoji("🌿"))
        _ = model.createSpace(title: "Foreign Profile", profileID: otherProfile.id)
        model.focusSpace(windowID: model.windows[0].id, spaceID: destination.id)
        pump(page); try await Task.sleep(for: .milliseconds(20)); pump(page)
        check(page.pillSpaceID == destination.id && page.titleBar.spaceTitle == "Reading" && !page.titleBar.profileButton.isHidden,
              "L5 pill follows model's most recent Profile Space; >=2 Profiles shows chip")
        page.titleBar.chevronButton.performClick(nil)
        let picker = page.spacePicker!
        check(picker.filteredSpaces.first?.id == destination.id && picker.highlightedIndex == 0 && !picker.filteredSpaces.contains { $0.profileID != page.session.profileID },
              "L5 chevron opens picker, current first/highlighted, Profile scope")
        let pickerWindow = OffscreenRenderer.host(picker.view, scale: 1)
        defer { pickerWindow.close() }
        pickerWindow.makeFirstResponder(picker.searchField)
        key(pickerWindow, code: 125, text: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        check(picker.highlightedIndex == 1, "L5 Down moves picker highlight")
        key(pickerWindow, code: 126, text: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        check(picker.highlightedIndex == 0, "L5 Up moves picker highlight")
        (pickerWindow.firstResponder as? NSTextView)?.insertText("sTu", replacementRange: NSRange(location: 0, length: 0))
        check(picker.filteredSpaces.map(\.id) == [third.id], "L5 Search Spaces typing filters case-insensitive substring")
        key(pickerWindow, code: 36, text: "\r")
        check(!little.sessions.contains { $0.id == page.session.id } && model.spaces.first { $0.id == third.id }?.today.first?.tab?.url.host == "www.example.com",
              "L5 Return moves to highlighted Space through real search-field path")
        let pill = blank(); pill.container.host(for: pill.session.tab.id)!.load(URL(string: "https://pill.example/")!); pump(pill)
        pill.titleBar.chevronButton.performClick(nil)
        let escapePicker = pill.spacePicker!, escapeWindow = OffscreenRenderer.host(pill.spacePicker!.view, scale: 1)
        escapeWindow.makeFirstResponder(escapePicker.searchField)
        key(escapeWindow, code: 53, text: "\u{1b}")
        check(pill.spacePicker == nil && little.controllers[pill.session.id] != nil, "L5 picker Escape closes only the picker")
        escapeWindow.close()
        pill.titleBar.pillButton.performClick(nil)
        check(!little.sessions.contains { $0.id == pill.session.id } && third.today.first?.tab?.url.host == "pill.example", "L5 pill click moves to its displayed Space")
        let command = blank(); command.container.host(for: command.session.tab.id)!.load(URL(string: "https://command.example/")!); command.openInCurrentSpace()
        check(!little.sessions.contains { $0.id == command.session.id } && third.today.first?.tab?.url.host == "command.example", "L5 open-in-current-space uses the same pill destination")
        little.closeAll()

        _ = blank(100); _ = blank(100)
        check(little.sessions.count == 1, "L6 same key-down timestamp creates exactly one window")
        _ = blank(100.2)
        check(little.sessions.count == 2, "L6 key-down timestamps 0.2 s apart create two windows")
        little.closeAll()

        let intent = blank()
        try await type(intent, "https://intent.example/path")
        if let index = intent.commandBar.suggestions.firstIndex(where: { $0.kind == .navigate }) { intent.commandBar.choose(index, modifiers: [.command, .option, .shift]) }
        check(intent.currentURL?.host == "intent.example" && intent.state == .page && !model.index.values.contains { $0.tab?.url.host == "intent.example" }, "L7 open intent ignores modifiers/destination and loads this page only")
        try await type(intent, "arbitrary query with words")
        if let index = intent.commandBar.suggestions.firstIndex(where: { $0.kind == .search }) { intent.commandBar.choose(index, modifiers: [.command, .option]) }
        check(intent.currentURL?.absoluteString.contains("arbitrary") == true, "L7 search intent loads this page")
        var commands: [String] = []; little.performCommand = { id, _ in commands.append(id) }
        try await type(intent, "New Window")
        if let index = intent.commandBar.suggestions.firstIndex(where: { $0.kind == .action && $0.actionID == "new-window" }) { intent.commandBar.choose(index) }
        check(commands == ["new-window"], "L7 runAction forwards once")
        // Save/restore the pasteboard: the check uses the real copy path without leaving test text.
        let savedPasteboard = NSPasteboard.general.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedPasteboard.map { pairs in let item = NSPasteboardItem(); for (type, data) in pairs { item.setData(data, forType: type) }; return item })
        }
        try await type(intent, "2+2")
        if let index = intent.commandBar.suggestions.firstIndex(where: { $0.kind == .calculator }) { intent.commandBar.choose(index) }
        check(NSPasteboard.general.string(forType: .string) == "4", "L7 copy intent writes real pasteboard")
        intent.focusURL(); key(intent.window!, code: 53, text: "\u{1b}")
        check(little.controllers[intent.session.id] != nil && !intent.commandBar.isPresented, "L7 page Escape closes overlay only")
        intent.focusURL(); intent.commandBar.dismiss(reason: .clickOutside)
        check(little.controllers[intent.session.id] != nil && !intent.commandBar.isPresented, "L7 page click-outside closes overlay only")
        let escape = blank(); key(escape.window!, code: 53, text: "\u{1b}")
        check(little.controllers[escape.session.id] == nil, "L7 bar Escape closes window")
        let close = blank(); _ = close.commandBar.view.debugPress("close")
        check(little.controllers[close.session.id] == nil, "L7 embedded x closes bar window")
        var switched: [(ItemID, SpaceID?)] = []; little.onSwitchToTab = { switched.append(($0, $1)) }
        let switcher = blank(); try await type(switcher, "Example 1")
        let expectedTab = model.spaces[0].pinned[0].tab!.id
        if let index = switcher.commandBar.suggestions.firstIndex(where: { $0.kind == .switchToTab && $0.tabID == expectedTab }) { switcher.commandBar.choose(index) }
        check(switched.count == 1 && switched.first?.0 == expectedTab && little.controllers[switcher.session.id] == nil, "L7 Switch to Tab forwards once then closes window")
        archive.flushQueue(); check(await archive.recent().isEmpty, "L7 bar close, selection, move and escape never archive")
        little.closeAll()

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        check(little.nextExpiry(now: now) == nil, "L8 no sessions has no expiry")
        model.profiles[0].settings.littleOpenAutoArchiveAfter = .oneHour
        let expiry = blank(); expiry.session.lastActiveAt = now.addingTimeInterval(-1800)
        let later = blank(); later.session.lastActiveAt = now
        var changes = 0; little.onChange = { changes += 1 }
        check(little.nextExpiry(now: now) == now.addingTimeInterval(1800), "L8 earliest deadline = lastActiveAt + per-Profile interval (1800 s)")
        little.recordActivity(expiry.session.id)
        check(changes == 1 && little.nextExpiry(now: now) == now.addingTimeInterval(3600), "L8 activity notifies sweeper and reschedules earliest deadline")
        expiry.session.lastActiveAt = now.addingTimeInterval(-3600)
        check(little.archiveExpired(now: now) == 1 && little.controllers[expiry.session.id] == nil && little.controllers[later.session.id] != nil, "L8 expires exactly at deadline, keeps fresh session")
        archive.flushQueue(); let records = await archive.recent()
        check(records.count == 1 && records[0].id == expiry.session.tab.id && records[0].reason == .autoArchived
              && records[0].originalLocation == "littleOpen:\(expiry.session.id)" && records[0].profileID == expiry.session.profileID
              && records[0].spaceID == nil && records[0].archivedAt == now, "L8 real SQLite reason autoArchived, location littleOpen:<id>, Profile and timestamp")
        model.profiles[0].settings.littleOpenAutoArchiveAfter = .never
        check(little.nextExpiry(now: now) == nil && little.archiveExpired(now: now.addingTimeInterval(1e8)) == 0, "L8 Never has no deadline and never archives")
        little.closeAll()

        defaults.set(false, forKey: "open.links.littleOpenNUXSeen")
        let intro = blank(); check(!intro.showsIntro, "L4 NUX waits for page state")
        intro.container.host(for: intro.session.tab.id)!.load(URL(string: "https://intro.example/")!); pump(intro)
        check(intro.showsIntro && intro.container.frame.height == intro.contentView.bounds.height - 47 - 32, "L4 first page NUX adds 32 pt band")
        intro.dismissIntro(); let next = blank(); next.container.host(for: next.session.tab.id)!.load(URL(string: "https://intro2.example/")!); pump(next)
        check(!next.showsIntro && defaults.bool(forKey: "open.links.littleOpenNUXSeen"), "L4 NUX shown once and Got it removes band")
        let state = little.stateForAutomation.first { $0.id == next.session.id }
        check(state?.state == .page && state?.window === next.window && state?.currentURL.host == "intro2.example" && state?.profileID == next.session.profileID && state?.pillSpaceID == next.pillSpaceID && state?.lastActiveAt == next.session.lastActiveAt, "L4 read-only automation state matches live session")
    }
}
