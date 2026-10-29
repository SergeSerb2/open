import AppKit
import OpenModel
import OpenFeatures
import OpenStore
import OpenDesign

@MainActor
enum FeatureCLI {
    static func synthetic() -> BrowserModel {
        let profile = Profile()
        let tabs = (1...6).map { n in Tab(url: URL(string: "https://site\(n).example.com/page")!, title: "Example \(n)") }
        for tab in tabs { tab.live.sleepPhase = .live }
        let space = Space(title: "Research", profileID: profile.id, pinned: tabs.prefix(3).map { .tab($0) }, today: tabs.suffix(3).map { .tab($0) })
        return BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
    }
    static var defaultSuites: [String] = []
    static func defaults() -> UserDefaults {
        let name = "Open.M4.Harness.\(UUID().uuidString)"; defaultSuites.append(name)
        let d = UserDefaults(suiteName: name)!
        d.register(defaults: ["open.peek.otherSites": true, "open.peek.shiftClick": true, "open.links.littleOpenNUXSeen": true]); return d
    }
    static func run(_ args: [String]) async throws {
        guard let cmd = args.first else { throw CLIError(description: RenderCLI.usage) }
        if cmd == "check" {
            if args == ["check", "--only", "auto-archive"] {
                var passed = 0, failed = 0
                try await AutoArchiveChecks.run { condition, label in
                    if condition { passed += 1 } else { failed += 1 }
                    print("\(condition ? "PASS" : "FAIL") \(label)")
                }
                print("features-render auto-archive check: \(passed) passed, \(failed) failed")
                if failed > 0 { throw CLIError(description: "\(failed) auto-archive scenarios failed") }
            } else { try await FeatureChecks.run() }
            return
        }
        if cmd == "pip" { try PiPScene.run(args); return }
        if cmd == "compare" { try FeatureCompare.run(args); return }
        if cmd == "hint" {
            // The first-hide hint at rest over a hidden sidebar (A0440's state), default dark theme.
            let size = (RenderCLI.value(args, "--size") ?? "2216x1394").split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { throw CLIError(description: "invalid size") }
            let model = synthetic(), scale = Double(RenderCLI.value(args, "--scale") ?? "1") ?? 1
            let c = BrowserWindowController(model: model, windowID: model.windows[0].id, factory: FakeWebContentHostFactory(),
                                            size: CGSize(width: size[0], height: size[1]), defaults: defaults())
            if RenderCLI.value(args, "--appearance") != "light" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            c.toggleSidebar(); OffscreenRenderer.settle(c.contentView, runLoop: 0.05)
            guard let hint = c.hintToast else { throw CLIError(description: "hint did not show") }
            print("hint frame \(hint.frame) plate \(hint.plateFrame)")
            try output(c.contentView, args: args, scale: scale); c.container.closeAll(); return
        }
        let sizeParts = (RenderCLI.value(args, "--size") ?? (cmd == "little" ? "720x540" : "2216x1394")).split(separator: "x").compactMap { Double($0) }
        guard sizeParts.count == 2, sizeParts.allSatisfy({ $0 > 0 && $0 <= 8192 }) else { throw CLIError(description: "invalid size") }
        let size = CGSize(width: sizeParts[0], height: sizeParts[1]), scale = Double(RenderCLI.value(args, "--scale") ?? "1") ?? 1
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        let model: BrowserModel
        if let dir = RenderCLI.value(args, "--snapshot") {
            guard let loaded = try SnapshotStore(root: URL(fileURLWithPath: dir)).load() else { throw CLIError(description: "missing snapshot") }; model = loaded
        } else { model = synthetic() }
        let factory = FakeWebContentHostFactory(), defaults = defaults()
        if cmd == "little" {
            let little = LittleOpenCoordinator(model: model, archiveSink: nil) { profile in factory.makeHost(tabID: ItemID(), profileID: profile, url: nil)! as! FakeWebContentHost }
            little.presentWindows = false; little.defaults = defaults; little.open(url: URL(string: RenderCLI.value(args, "--url") ?? "https://example.com")!, profileHint: nil)
            guard let c = little.sessions.first.flatMap({ little.controllers[$0.id] }) else { throw CLIError(description: "no Little Open session") }
            c.contentView.frame.size = size; c.window?.setContentSize(size)
            try await waitForLoads(factory, root: c.contentView)
            OffscreenRenderer.settle(c.contentView, runLoop: 0.01)
            try output(c.contentView, args: args, scale: scale); little.closeAll(); return
        }
        guard ["split", "peek", "bench", "switcher"].contains(cmd), let window = model.windows.first else { throw CLIError(description: RenderCLI.usage) }
        if let n = RenderCLI.value(args, "--space").flatMap(Int.init), model.spaces.indices.contains(n) { window.focusedSpaceID = model.spaces[n].id }
        if args.contains("--sidebar-hidden") { window.sidebarMode = .hidden }
        if args.contains("--untitled") { model.space(id: window.focusedSpaceID)?.title = "" }
        guard let space = model.space(id: window.focusedSpaceID) else { throw CLIError(description: "no Space") }
        // Render-only state for captured frames. Values come from the run script in .re/.
        if let w = RenderCLI.value(args, "--width").flatMap(Double.init) { window.sidebarWidth = w }
        if args.contains("--keep-titles") { FakeWebContentHost.reportsTitles = false }
        for spec in RenderCLI.values(args, "--page-color") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let rgb = Int(parts[1], radix: 16) else { throw CLIError(description: "--page-color HOST=RRGGBB") }
            FakeWebContentHost.pageColors[parts[0]] = NSColor(srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        if let spec = RenderCLI.value(args, "--seed-today-split") {
            // "URL=TITLE": a new Today tab after the first one, split with it (a split made during the capture session).
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[0]), let first = space.today.first?.tab else { throw CLIError(description: "--seed-today-split URL=TITLE needs a Today tab") }
            let tab = model.newTab(in: space.id, url: url, title: parts[1], at: 1)
            guard model.makeSplit(tabIDs: [first.id, tab.id]) != nil else { throw CLIError(description: "cannot seed split") }
        }
        func tabs(_ nodes: [SidebarNode]) -> [Tab] { nodes.flatMap { node in switch node { case .tab(let t): [t]; case .split(let s): s.panes; case .folder(let f): tabs(f.children) } } }
        let all = tabs(space.pinned + space.today)
        for tab in all { tab.live.sleepPhase = .live }
        let fractions = (RenderCLI.value(args, "--fractions") ?? (cmd == "bench" ? "0.25,0.25,0.25,0.25" : "0.5,0.5")).split(separator: ",").compactMap { Double($0) }
        let orientation: SplitOrientation = RenderCLI.value(args, "--orientation") == "vertical" ? .vertical : .horizontal
        let selected: ItemID
        if let raw = RenderCLI.value(args, cmd == "peek" ? "--source-tab" : "--select-node"), let uuid = UUID(uuidString: raw), model.node(id: ItemID(rawValue: uuid)) != nil { selected = ItemID(rawValue: uuid) }
        else if cmd == "peek" || cmd == "switcher" { guard let tab = all.first else { throw CLIError(description: "no source") }; selected = tab.id }
        else if fractions.count == 1 { guard let tab = all.first else { throw CLIError(description: "no tab") }; selected = tab.id }
        else {
            if let split = (space.pinned + space.today).compactMap(\.split).first { selected = split.id }
            else {
                let available = all.filter { if case .splitPane? = model.parent(of: $0.id) { return false }; return true }
                guard let split = model.makeSplit(tabIDs: Array(available.prefix(max(2, min(4, fractions.count)))).map(\.id), orientation: orientation) else { throw CLIError(description: "cannot seed split") }; selected = split.id
            }
        }
        if let split = model.node(id: selected)?.split {
            model.setSplitOrientation(splitID: split.id, orientation: orientation)
            model.setSplitFractions(splitID: split.id, fractions: fractions)
            let n = Int(RenderCLI.value(args, "--focus-pane") ?? "1") ?? 1
            if split.panes.indices.contains(n - 1) { model.focusSplitPane(splitID: split.id, tabID: split.panes[n - 1].id) }
        }
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: selected)
        let c = BrowserWindowController(model: model, windowID: window.id, factory: factory, size: size, defaults: defaults)
        if cmd == "switcher" {
            c.tabSwitcher.advance(by: 1, items: all.prefix(5).map {
                .init(id: $0.id, title: $0.displayTitle, subtitle: $0.url.host ?? "")
            }, current: selected, in: c.contentView) { _ in }
            try await Task.sleep(for: .milliseconds(130))
        }
        if cmd == "peek", let source = c.context.currentTab {
            let depth = max(1, min(5, Int(RenderCLI.value(args, "--depth") ?? "1") ?? 1))
            for _ in 0..<depth { c.peekController.open(url: URL(string: RenderCLI.value(args, "--peek-url") ?? "https://example.org/preview")!, sourceTabID: source.id) }
        }
        try await waitForLoads(factory, root: c.contentView)
        OffscreenRenderer.settle(c.contentView, runLoop: 0.01)
        if cmd == "bench" {
            var samples: [Double] = []
            for _ in 0..<200 { let start = CFAbsoluteTimeGetCurrent(); c.container.needsLayout = true; c.container.layoutSubtreeIfNeeded(); samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            samples.sort(); print(String(format: "200 layouts: median %.3f ms, p95 %.3f ms", samples[100], samples[190])); return
        }
        if let frames = RenderCLI.value(args, "--frames") {
            func rect(_ view: NSView) -> [Double] {
                let f = view.convert(view.bounds, to: c.contentView); return [f.minX, size.height - f.maxY, f.width, f.height]
            }
            let payload: Any = cmd == "peek" ? ["panel": rect(c.peekController.overlay.panel), "buttons": c.peekController.overlay.buttons.map(rect)] as [String: Any]
                : c.container.slots.map(rect)
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: frames))
        }
        try output(c.contentView, args: args, scale: scale)
    }
    static func waitForLoads(_ factory: FakeWebContentHostFactory, root: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            OffscreenRenderer.settle(root, runLoop: 0.01)
            if factory.made.filter({ !$0.isClosed }).allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw CLIError(description: "fake host did not finish loading within 5 seconds")
    }
    static func output(_ root: NSView, args: [String], scale: CGFloat) throws {
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out required") }
        root.window?.contentView = nil
        OffscreenRenderer.writePNG(OffscreenRenderer().render(root, scale: scale), to: URL(fileURLWithPath: out)); print("rendered \(out)")
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Task { @MainActor in
    @MainActor func cleanDefaults() { for name in FeatureCLI.defaultSuites { UserDefaults.standard.removePersistentDomain(forName: name) } }
    do { try await FeatureCLI.run(Array(CommandLine.arguments.dropFirst())); cleanDefaults(); exit(0) }
    catch { cleanDefaults(); FileHandle.standardError.write(Data("features-render: \(error)\n".utf8)); exit(1) }
}
RunLoop.main.run()
