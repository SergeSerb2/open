import AppKit
import QuartzCore
import Darwin
import OpenDesign
import OpenWeb
import OpenExtensionsUI

@MainActor enum Checks {
    /// Reuse features-render's real scheduler/drawing interposer, adapting only its
    /// executable/module attribution. This stays harness-only, outside product code.
    static func relaunchWithObserverIfNeeded() throws -> Int32? {
        guard ProcessInfo.processInfo.environment["OPEN_EXT_IDLE_OBSERVER"] == nil else { return nil }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("open-extensions-idle-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try String(contentsOf: root.appendingPathComponent("tools/verification/feature-idle-probe.m"), encoding: .utf8)
            .replacingOccurrences(of: "/features-render", with: "/extensions-render")
            .replacingOccurrences(of: "\"OpenFeatures\"", with: "\"OpenExtensionsUI\"")
        let input = scratch.appendingPathComponent("probe.m"), library = scratch.appendingPathComponent("idle-probe.dylib")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-dynamiclib", "-fblocks", "-fobjc-arc", "-Wno-deprecated-declarations", input.path,
                              "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "CoreVideo", "-o", library.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CLIError(description: "idle observer build failed") }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = Array(CommandLine.arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = library.path; environment["OPEN_EXT_IDLE_OBSERVER"] = "1"
        child.environment = environment
        try child.run(); child.waitUntilExit(); return child.terminationStatus
    }
    struct Probe {
        let begin: @convention(c) () -> Void
        let reset: @convention(c) () -> Void
        let end: @convention(c) () -> Void
        let watch: @convention(c) (UnsafeMutableRawPointer) -> Void
        let count: @convention(c) (Int32) -> UInt64
        init() throws {
            func symbol<T>(_ name: String, _: T.Type) throws -> T {
                guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { throw CLIError(description: "idle observer missing: " + name) }
                return unsafeBitCast(p, to: T.self)
            }
            begin = try symbol("open_idle_begin", (@convention(c) () -> Void).self)
            reset = try symbol("open_idle_reset_events", (@convention(c) () -> Void).self)
            end = try symbol("open_idle_end", (@convention(c) () -> Void).self)
            watch = try symbol("open_idle_watch_view", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
            count = try symbol("open_idle_count", (@convention(c) (Int32) -> UInt64).self)
        }
        var counts: [UInt64] { (0..<10).map { count(Int32($0)) } }
    }
    private final class LinkTarget: NSObject { @objc func tick(_ link: CADisplayLink) {} }
    private static func observerProof(_ p: Probe) -> Bool {
        p.begin(); defer { p.end() }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in }
        let source = DispatchSource.makeTimerSource(queue: .main); source.schedule(deadline: .now() + 60); source.resume()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28)); view.wantsLayer = true
        let window = ExtensionsRenderer.host(view, scale: 2)
        defer { window.contentView = nil; window.close() }
        p.watch(Unmanaged.passUnretained(view).toOpaque())
        let a = CABasicAnimation(keyPath: "opacity"); a.duration = 60; a.fromValue = 0; a.toValue = 1
        view.layer?.add(a, forKey: "canary")
        let target = LinkTarget(), link = view.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .default)
        let counts = p.counts
        timer.invalidate(); source.cancel(); link.invalidate(); view.layer?.removeAllAnimations()
        return counts[6] > 0 && counts[7] > 0 && counts[9] > 0 && counts[4] > 0 && p.counts[6...9].allSatisfy { $0 == 0 }
    }
    private static func idle() throws -> (Bool, String) {
        let p = try Probe(), canary = observerProof(p)
        var good = canary, receipts: [String] = []
        defer { Motion.reduceMotionOverride = nil }
        for reduced in [false, true] {
            Motion.reduceMotionOverride = reduced
            for style in [ExtensionStripStyle.urlField, .paneBar, .toolbar] {
                p.begin()
                let strip = ExtensionStripView(style: style); strip.frame = CGRect(x: 0, y: 0, width: 600, height: 90)
                strip.hovered = true; _ = strip.setActions(Synthetic.actions(20))
                let window = ExtensionsRenderer.host(strip, scale: 2)
                p.watch(Unmanaged.passUnretained(strip).toOpaque())
                ExtensionsRenderer.settle(strip, runLoop: 0.03)
                let live = Array(p.counts[6...9])
                p.reset(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let counts = p.counts
                func animations(_ layer: CALayer?) -> Int {
                    guard let layer else { return 0 }
                    return (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).map { animations($0) }.reduce(0, +)
                }
                good = good && live.allSatisfy { $0 == 0 } && counts.allSatisfy { $0 == 0 } && animations(strip.layer) == 0
                receipts.append("\(style)/reduce=\(reduced):\(counts)")
                p.end(); window.contentView = nil; window.close()
            }
        }
        return (good, "canary=\(canary); draw/layout/display/invalidation/schedule/overflow/timer/source/CV/CA = " + receipts.joined(separator: "; "))
    }
    private static func sharedStripUpdates() -> Bool {
        let context = ExtensionsUIContext(), root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 180))
        let strips = [ExtensionStripView(style: .urlField, context: context), ExtensionStripView(style: .toolbar, context: context)]
        let actions = Synthetic.actions(3, pinned: 2)
        for (index, strip) in strips.enumerated() {
            strip.frame = CGRect(x: 0, y: index * 90, width: 600, height: 90)
            strip.hovered = true; _ = strip.setActions(actions); root.addSubview(strip)
        }
        let window = ExtensionsRenderer.host(root, scale: 2)
        defer { window.contentView = nil; window.close() }
        var good = true
        func deliver(_ action: ExtensionActionInfo, expected: [String]) {
            // The App may update the shared snapshot before notifying either host.
            _ = context.updateAction(action)
            for strip in strips {
                strip.updateAction(action); strip.layoutSubtreeIfNeeded()
                good = good && strip.buttons.map { $0.action.id } == expected
            }
        }
        var third = actions[2]; third.isPinned = true; third.pinnedIndex = 2
        deliver(third, expected: ["synthetic.0", "synthetic.1", "synthetic.2"])
        third.pinnedIndex = -1
        deliver(third, expected: ["synthetic.2", "synthetic.0", "synthetic.1"])
        var first = actions[0]; first.isPinned = false; first.pinnedIndex = nil
        deliver(first, expected: ["synthetic.2", "synthetic.1"])
        let counts = strips.map(\.layoutCount)
        third.badgeText = "updated"; third.toolbarImage = Synthetic.image(index: 2, badge: "NEW")
        deliver(third, expected: ["synthetic.2", "synthetic.1"])
        return good && strips.map(\.layoutCount) == counts && strips.allSatisfy {
            $0.buttons.first?.action.toolbarImage === third.toolbarImage
        }
    }
    private static func scrollingPicker() -> Bool {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 236, height: 92))
        let body = ExtensionsSectionBody(frame: .zero)
        var actions = Synthetic.actions(31); actions[30].name = "Needle"
        _ = body.setActions(actions); body.pickerMode = true
        body.frame = CGRect(origin: .zero, size: body.intrinsicContentSize)
        scroll.documentView = body
        let window = ExtensionsRenderer.host(scroll, scale: 2)
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(body)
        func send(_ code: UInt16, _ text: String = "", _ time: TimeInterval = 0) {
            window.sendEvent(Scenes.key(code, text: text, time: time, window: window.windowNumber))
        }
        func visible(_ id: String) -> Bool {
            guard let item = body.items.first(where: { $0.item.id == id }) else { return false }
            return body.focusedID == id && scroll.contentView.documentVisibleRect.contains(item.frame)
        }
        for _ in 0..<4 { send(125) }
        let arrow = visible("synthetic.20")
        send(0, "n", 3); let typed = visible("synthetic.30")
        send(125); let wrapped = visible("synthetic.0")
        send(126); let reverse = visible("synthetic.30")
        var ranVisible = false
        body.onIntent = { if case let .run(id, _) = $0 { ranVisible = visible(id) } }
        send(36)
        return arrow && typed && wrapped && reverse && ranVisible
    }
    static func run() throws -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name) | \(detail)")
        }
        func layout(_ width: CGFloat, _ style: ExtensionStripStyle = .urlField, _ count: Int = 6, _ host: CGFloat = 120, _ focused: Bool = true) -> ExtensionStripLayout {
            ExtensionStripLayout(style: style, width: width, pinnedCount: count, hostTextWidth: host, focused: focused)
        }
        let maxima = [228, 300, 500].map { layout(CGFloat($0)).nMax }
        check("strip.nmax", maxima == [3, 5, 13], "W 228/300/500 → \(maxima)")
        let strip = ExtensionStripView(style: .urlField); strip.frame = CGRect(x: 0, y: 0, width: 228, height: 82); strip.hovered = true
        let actions = Synthetic.actions(8, pinned: 6)
        _ = strip.setActions(actions)
        let window = ExtensionsRenderer.host(strip, scale: 2)
        defer { window.contentView = nil; window.close() }
        let overflow = ExtensionsMenuBuilder.model(actions: actions, kind: .overflow(visiblePinned: strip.geometry.actionFrames.count))
        check("strip.overflow", strip.geometry.actionFrames.count == 2 && strip.geometry.moreFrame != nil
            && overflow.prefix(4).compactMap(\.extensionID) == (2..<6).map { "synthetic.\($0)" }, "6 pinned @228 → 2 actions + more; overflow first 4 preserved")
        _ = strip.setActions(Array(actions.reversed())); strip.layoutSubtreeIfNeeded()
        let ordered = strip.buttons.map { $0.action.id } == (0..<6).map { "synthetic.\($0)" }
        var run = "", context = "", close = 0
        strip.context.run = { id, _, _ in run = id }; strip.context.contextMenu = { id, _, _ in context = id }; strip.context.closePopup = { close += 1 }
        strip.buttons[0].activate(); strip.buttons[1].activate()
        var popup = strip.buttons[0].action; popup.isShowingPopup = true; strip.updateAction(popup); strip.buttons[0].activate()
        strip.hovered = false
        let hidden = strip.buttons.allSatisfy(\.isHidden) && strip.buttons.allSatisfy { !$0.accessibilityPerformPress() }
        strip.forcedVisibility = .popup
        let forced = !strip.buttons[0].isHidden
        strip.hasPage = false; let noPage = strip.buttons.allSatisfy(\.isHidden)
        strip.hasPage = true; strip.forcedVisibility = []; strip.hovered = true
        popup.isShowingPopup = false; strip.updateAction(popup)
        window.orderBack(nil)
        var nativeDragEvents = 0
        let productionDrag = strip.buttons[0].onDrag
        strip.buttons[0].onDrag = { event, begins in nativeDragEvents += 1; productionDrag?(event, begins) }
        var moves: [(String, Int)] = []
        strip.context.movePinned = { moves.append(($0, $1)) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
        let start = strip.buttons[0].convert(CGPoint(x: 15, y: 15), to: nil)
        let nativeHit = window.contentView?.hitTest(start) === strip.buttons[0]
        mouse(.leftMouseDown, start); mouse(.leftMouseDragged, CGPoint(x: start.x + 2, y: start.y)); mouse(.leftMouseUp, start)
        let threshold = moves.isEmpty
        mouse(.leftMouseDown, start); mouse(.leftMouseDragged, CGPoint(x: start.x + 28, y: start.y)); mouse(.leftMouseUp, CGPoint(x: start.x + 28, y: start.y))
        let reordered = moves.count == 1 && moves[0].0 == "synthetic.0" && moves[0].1 == 1
        mouse(.leftMouseDown, start); mouse(.leftMouseDragged, CGPoint(x: start.x + 28, y: start.y))
        window.sendEvent(Scenes.key(53, window: window.windowNumber)); mouse(.leftMouseUp, CGPoint(x: start.x + 28, y: start.y))
        mouse(.leftMouseDown, start); mouse(.leftMouseDragged, CGPoint(x: 300, y: start.y)); mouse(.leftMouseUp, CGPoint(x: 300, y: start.y))
        let drag = nativeHit && threshold && reordered && moves.count == 1
        let sharedUpdates = sharedStripUpdates()
        check("strip.order", ordered && hidden && forced && noPage && run == "synthetic.0" && context == "synthetic.1" && close == 1 && drag && sharedUpdates,
              "shared pin/unpin/order/badge=\(sharedUpdates); pinnedIndex; click/disabled/second-click; hidden AX/forced/no-page; native drag threshold/drop/Esc/outside=\(drag),events=\(nativeDragEvents),moves=\(moves),threshold=\(threshold),reorder=\(reordered); hit=\(nativeHit)")
        var updated = strip.buttons[0].action
        let before = strip.layoutCount; updated.badgeText = "changed"; updated.toolbarImage = Synthetic.image(index: 0, badge: "NEW")
        strip.updateAction(updated); strip.layoutSubtreeIfNeeded()
        check("strip.badge-no-layout", strip.layoutCount == before && strip.buttons[0].action.toolbarImage === updated.toolbarImage,
              "badge/image update: \(strip.layoutCount - before) strip layouts")
        let panes = [layout(984, .paneBar, 26, 160), layout(600, .paneBar, 26, 120), layout(400, .paneBar, 26, 120)]
        check("pane.nmax", panes.map(\.nMax) == [19, 7, 0] && panes[2].moreFrame != nil && panes[2].actionFrames.isEmpty,
              "984/host160, 600/host120, 400/host120 → \(panes.map(\.nMax)); 400 more only")
        check("pane.unfocused", layout(984, .paneBar, 26, 160, false).frames.isEmpty, "unfocused pane has no slots")
        let toolbar = [layout(984, .toolbar, 40, 160), layout(600, .toolbar, 40, 120)]
        var noOverlap = true
        for width: CGFloat in [250, 400, 600, 984] {
            for count in 0...40 {
                let g = layout(width, .toolbar, count), scc = ToolbarMetrics.siteControls(width: width, stripWidth: g.stripWidth)
                noOverlap = noOverlap && g.frames.allSatisfy { !$0.intersects(scc) && $0.minX >= 0 && $0.maxX <= width - 5 }
                    && (g.frames.isEmpty || scc.maxX + 4 == g.frames[0].minX)
            }
        }
        check("toolbar.nmax", toolbar.map(\.nMax) == [23, 10] && noOverlap,
              "left115; right=w−5, minus nothing; 984/host160=\(toolbar[0].nMax), 600/host120=\(toolbar[1].nMax); 164 frame sets do not overlap SCC")
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1200), anchor = CGRect(x: 200, y: 900, width: 28, height: 28)
        let below = ExtensionPopupPlacement.frame(anchor: anchor, requestedSize: CGSize(width: 320, height: 480), visibleFrame: screen)
        check("placement.below", below.minX == 200 && below.maxY == 894 && below.size == CGSize(width: 320, height: 480), "left200, top894; gap6")
        let right = ExtensionPopupPlacement.frame(anchor: CGRect(x: 1580, y: 900, width: 20, height: 28), requestedSize: CGSize(width: 320, height: 480), visibleFrame: screen)
        check("placement.clamp-right", right.maxX == 1592, "right edge1592 = screen−8")
        let aboveAnchor = CGRect(x: 100, y: 80, width: 28, height: 28)
        let above = ExtensionPopupPlacement.frame(anchor: aboveAnchor, requestedSize: CGSize(width: 320, height: 480), visibleFrame: screen)
        check("placement.flip-above", above.minY == aboveAnchor.maxY + 6, "bottom114 = anchor.top108+6")
        let large = ExtensionPopupPlacement.frame(anchor: anchor, requestedSize: CGSize(width: 1200, height: 900), visibleFrame: screen)
        let small = ExtensionPopupPlacement.frame(anchor: anchor, requestedSize: CGSize(width: 10, height: 10), visibleFrame: screen)
        let constrained = ExtensionPopupPlacement.frame(anchor: CGRect(x: 100, y: 100, width: 28, height: 28), requestedSize: CGSize(width: 1200, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let panel = ExtensionPopupPanel(); let content = NSView(); panel.host(view: content)
        let notReady = panel.alphaValue == 0 && panel.ignoresMouseEvents && !panel.canBecomeKey && panel.hosts(view: content)
        panel.setFrame(CGRect(x: -20000, y: -20000, width: 320, height: 480), display: false)
        panel.orderNotReady(parent: window)
        let orderedNotReady = panel.isVisible && panel.alphaValue == 0 && !panel.canBecomeKey
        var readyCalls = 0; panel.onReady = { readyCalls += 1 }
        panel.showWhenReady(); panel.showWhenReady()
        let ready = panel.isReady && panel.alphaValue == 1 && !panel.ignoresMouseEvents && readyCalls == 1
        panel.detach(); panel.close()
        check("placement.size-clamp", large.size == CGSize(width: 800, height: 600) && small.size == CGSize(width: 25, height: 25)
            && constrained.width == 384 && constrained.height == 158 && notReady && orderedNotReady && ready, "1200×900→800×600;10×10→25×25; screen bounds; panel host/not-ready/order/ready-once")
        let menu = ExtensionsMenuBuilder.menu(actions: actions, kind: .bar, run: { _, _ in }, command: { _ in })
        let emptyMenu = ExtensionsMenuBuilder.menu(actions: [], kind: .bar, run: { _, _ in }, command: { _ in })
        check("menu.bar", menu.items.prefix(6).map(\.title) == actions.prefix(6).map(\.name) && !menu.items[1].isEnabled
            && menu.items[8].isSeparatorItem && menu.items.suffix(2).map(\.title) == ["Manage Extensions…", "Add Extension…"]
            && menu.items.prefix(8).allSatisfy { $0.image?.size == CGSize(width: 16, height: 16) }
            && emptyMenu.items.count == 2 && !emptyMenu.items.contains(where: \.isSeparatorItem), "pinned first, names, disabled, 16pt icons, separator, empty menu")
        let labels = ["Remove from Chromium", "Remove from Chrome…", "Remove from Chromium…", "Pin to Toolbar", "Unpin from Toolbar", "Chrome Tools", "Chromium Settings Sync"]
        let expected = ["Remove from Open…", "Remove from Open…", "Remove from Open…", "Pin", "Unpin", "Chrome Tools", "Chromium Settings Sync"]
        let source = SyntheticMenu([.init(command: 10, title: "Chrome Tools", submenu: [.init(command: 11, title: "Pin to Toolbar", isChecked: true)]), .init(isSeparator: true), .init(command: 12, title: "Remove from Chromium")])
        var native: NSMenu? = ExtensionsMenuBuilder.contextMenu(source)
        let preserved = native?.items[0].title == "Chrome Tools" && native?.items[0].submenu?.items[0].title == "Pin" && native?.items[0].submenu?.items[0].state == .on && native?.items[1].isSeparatorItem == true
        native?.performActionForItem(at: 2); native?.delegate?.menuDidClose?(native!); native?.delegate?.menuDidClose?(native!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)); native = nil
        let cancelled = SyntheticMenu([.init(command: 1, title: "Options")]); var cancelMenu: NSMenu? = ExtensionsMenuBuilder.contextMenu(cancelled)
        cancelMenu?.delegate?.menuDidClose?(cancelMenu!); cancelMenu?.delegate?.menuDidClose?(cancelMenu!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)); cancelMenu = nil
        check("menu.relabel", labels.map(ExtensionsMenuBuilder.relabel) == expected && preserved && source.selections == [12] && source.cancels == 0 && cancelled.cancels == 1,
              "Chrome + Chromium built-in relabel, extension names kept; separator/submenu/check preserved; select once, cancel once")
        let body = ExtensionsSectionBody(frame: CGRect(x: 0, y: 0, width: 260, height: 200)); body.pickerMode = true
        _ = body.setActions(Synthetic.actions(5))
        let pickerWindow = ExtensionsRenderer.host(body, scale: 2); defer { pickerWindow.contentView = nil; pickerWindow.close() }
        pickerWindow.makeFirstResponder(body)
        func send(_ code: UInt16, _ text: String = "", _ time: TimeInterval = 0) { pickerWindow.sendEvent(Scenes.key(code, text: text, time: time, window: pickerWindow.windowNumber)) }
        send(123); let leftWrap = body.focusedID == "extensions.add"
        send(124); send(125); let downWrap = body.focusedID == "extensions.add"
        send(126); let up = body.focusedID == "synthetic.0"
        send(0, "d", 1); send(0, "a", 1.5); let type = body.focusedID == "synthetic.1"
        send(0, "b", 3); let reset = body.focusedID == "synthetic.0"
        var ran = "", closed = 0
        body.onIntent = { if case let .run(id, _) = $0 { ran = id } }; body.onClose = { closed += 1 }
        send(36); send(53)
        _ = body.setActions(Synthetic.actions(3)); send(126); let rowWrap = body.focusedID == "extensions.add"
        let scrolled = scrollingPicker()
        check("picker.keys", leftWrap && downWrap && up && type && reset && ran == "synthetic.0" && closed == 1 && rowWrap && scrolled,
              "NSWindow.sendEvent → firstResponder: grid/row wrap, prefix within1s/reset, Return run, Esc close; scroll arrows/type/wrap/visible-run=\(scrolled)")
        var texts = true, promptReceipts: [String] = []
        for type in ExtensionPromptType.allCases {
            let prompt = SyntheticPrompt(type, permissions: type == .uninstall || type == .repair ? 0 : 3)
            let text = ExtensionPromptText(prompt)
            let title: String, accept: String, cancel: String
            switch type {
            case .install, .externalInstall, .remoteInstall: title = "Add Sample extension to Open?"; accept = "Add Extension"; cancel = "Cancel"
            case .permissions, .reEnable: title = "The extension Sample has requested additional permissions"; accept = "Allow"; cancel = "Deny"
            case .repair: title = "Repair Sample in Open?"; accept = "Repair"; cancel = "Cancel"
            case .uninstall: title = "Remove Sample extension from Open?"; accept = "Remove Extension"; cancel = "Cancel"
            }
            texts = texts && text.title == title && text.accept == accept && text.cancel == cancel
                && text.bodyHeading == (type == .uninstall || type == .repair ? nil : "It can:")
            let sheet = ExtensionPromptSheet(model: prompt)!
            let host = ExtensionsRenderer.host(sheet.promptView, scale: 2); host.makeFirstResponder(sheet.promptView)
            host.sendEvent(Scenes.key(36, window: host.windowNumber)); sheet.answer(false); sheet.close()
            texts = texts && prompt.accepts == 1 && prompt.cancels == 0
            promptReceipts.append("\(type):title=\(text.title == title),buttons=\(text.accept == accept && text.cancel == cancel),answers=\(prompt.accepts)/\(prompt.cancels)")
            host.contentView = nil; host.close()
        }
        let longPrompt = SyntheticPrompt(.install, name: "A long extension name for a useful browsing tool")
        let longView = ExtensionPromptView(model: longPrompt)
        let longTitle = longView.subviews.compactMap { $0 as? NSTextField }.first!
        let neededTitleHeight = longTitle.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: 308, height: 1000)).height
        texts = texts && longTitle.frame.height >= neededTitleHeight
        promptReceipts.append("long title height=\(longTitle.frame.height),needed=\(neededTitleHeight)")
        let permissionsView = ExtensionPromptView(model: SyntheticPrompt(.permissions, permissions: 3, name: "A long extension name for a useful browsing tool"))
        let permissionsTitle = permissionsView.subviews.compactMap { $0 as? NSTextField }.first!
        let permissionTitleHeight = permissionsTitle.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: 308, height: 1000)).height
        texts = texts && permissionsTitle.frame.height >= permissionTitleHeight
        promptReceipts.append("3-line title height=\(permissionsTitle.frame.height),needed=\(permissionTitleHeight)")
        var iconFrames = true
        let renderer = ExtensionsRenderer()
        for sourceSize: CGFloat in [16, 48, 128] { for scale: CGFloat in [1, 2] {
            let fixture = SyntheticPrompt(.install); fixture.icon = Synthetic.image(index: 0, size: sourceSize)
            let image = renderer.render(ExtensionPromptView(model: fixture), scale: scale)
            let data = image.dataProvider!.data! as Data
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = Int(CGFloat(y) * scale) * image.bytesPerRow + Int(CGFloat(x) * scale) * 4
                return Array(data[offset..<(offset + 4)])
            }
            let center = pixel(48, 48), background = pixel(23, 48)
            iconFrames = iconFrames && pixel(26, 48) == center && pixel(70, 48) == center && pixel(73, 48) == background
                && zip(center.prefix(3), background.prefix(3)).map { abs(Int($0) - Int($1)) }.reduce(0, +) > 100
            if sourceSize == 48 {
                // A doubled fixture CTM clips three rounded corners at 2x.
                // Check all four corners through the real rendered prompt.
                iconFrames = iconFrames && [(24, 24), (71, 24), (24, 71), (71, 71)].allSatisfy {
                    pixel($0.0, $0.1) == background
                }
            }
        } }
        texts = texts && iconFrames
        promptReceipts.append("48pt icon pixels from16/48/128pt sources at1x/2x, all rounded corners=\(iconFrames)")
        let noPermissions = SyntheticPrompt(.install), byOther = SyntheticPrompt(.uninstall)
        byOther.triggeringExtensionName = "Other"; byOther.chromiumTitle = "Other wants to remove Sample from Chrome"
        texts = texts && ExtensionPromptText(noPermissions).bodyHeading == "This extension requires no special permissions."
            && ExtensionPromptText(byOther).title == "Other wants to remove Sample from Open"
        var released: ExtensionPromptSheet? = ExtensionPromptSheet(model: noPermissions); released?.answer(false); released?.answer(true); released = nil
        texts = texts && noPermissions.cancels == 1 && noPermissions.accepts == 0
        let abandoned = SyntheticPrompt(.permissions)
        autoreleasepool { let sheet = ExtensionPromptSheet(model: abandoned); sheet?.orderOut(nil) }
        texts = texts && abandoned.cancels == 1
        let queueWindow = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        queueWindow.isReleasedWhenClosed = false
        let queue = ExtensionPromptQueue(window: queueWindow)
        defer { queue.cancelAll(); queueWindow.close() }
        let first = SyntheticPrompt(.install), second = SyntheticPrompt(.permissions), third = SyntheticPrompt(.uninstall)
        queue.enqueue(first); queue.enqueue(second); queue.enqueue(third)
        let fifo1 = queue.active?.promptView.model === first && queue.queuedCount == 3
        queue.active?.answer(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let fifo2 = queue.active?.promptView.model === second && queue.queuedCount == 2
        if let sheet = queue.active { sheet.makeFirstResponder(sheet.promptView); sheet.sendEvent(Scenes.key(53, window: sheet.windowNumber)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let fifo3 = queue.active?.promptView.model === third
        queue.cancelAll(); queue.cancelAll()
        let fifo = fifo1 && fifo2 && fifo3 && first.accepts == 1 && second.cancels == 1 && third.cancels == 1 && queue.queuedCount == 0
        texts = texts && fifo
        // Boundary and one-over inputs pass through the public view/menu/model entry points.
        let limit = (0..<512).map { ExtensionActionInfo(extensionID: "limit.\($0)", name: String(repeating: "a", count: 4096)) }
        var over = limit; over.append(.init(extensionID: "over", name: "over"))
        let bounded = ExtensionsUIContext.accepts(limit) && !ExtensionsUIContext.accepts(over)
            && !ExtensionsUIContext.accepts([.init(extensionID: "x", name: String(repeating: "x", count: 4097))])
        check("prompt.text", texts && bounded, "all7 types; native Return; once-only; FIFO=\(fifo),limits=\(bounded),cancel=\(noPermissions.cancels),release=\(abandoned.cancels); " + promptReceipts.joined(separator: "; "))
        let result = try idle(); check("strip.no-idle-work", result.0, result.1)
        print("extensions-render check: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
