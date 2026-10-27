import AppKit
import Darwin
import OpenDesign
import OpenModel
import OpenSidebar
import OpenMedia
import OpenWeb

/// Real composed sidebar, hit testing, native symbol layers and tooltip read-back.
@MainActor enum MediaChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func animationKeys(_ layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animationKeys)
    }
    static func hasFallback(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return (layer.animationKeys() ?? []).contains { layer.animation(forKey: $0)?.value(forKey: "openMediaFallback") as? Bool == true }
            || (layer.sublayers ?? []).contains { hasFallback($0) }
    }
    static func animatedLayers(_ layer: CALayer?) -> Int { animationKeys(layer).count }
    static func inkLeft(_ view: NSView, direct: Bool = false) -> CGFloat? {
        guard let glyph = direct ? view : descendants(view).first(where: { $0.identifier?.rawValue == "media.speakerGlyph" }),
              let bitmap = glyph.bitmapImageRepForCachingDisplay(in: glyph.bounds) else { return nil }
        // The static glyph draws with AppKit. Read it synchronously rather than sampling
        // a GPU layer clone while its contents are still being published.
        glyph.cacheDisplay(in: glyph.bounds, to: bitmap)
        var left = bitmap.pixelsWide
        for y in (bitmap.pixelsHigh / 2 - 2)..<(bitmap.pixelsHigh / 2 + 2) {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.03 { left = min(left, x) }
        }
        return left < bitmap.pixelsWide ? CGFloat(left) * glyph.bounds.width / CGFloat(bitmap.pixelsWide) : nil
    }
    static func runRowIndicators() {
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let tab = model.spaces.first?.today.compactMap(\.tab).first else { return }
        let context = SidebarContext(model: model, windowID: window.id), delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 2)
        // A real window context is required by AppKit's symbol/tooltip implementation.
        // It stays at -20000,-20000 and orders behind other windows; it never becomes key.
        host.orderBack(nil)
        defer { host.orderOut(nil); host.contentView = nil; host.close(); SidebarDiagnostics.mediaReduceMotionOverride = nil }
        func pump(_ time: TimeInterval = 0.02) { OffscreenRenderer.settle(scene, runLoop: time) }
        func speaker() -> NSView? { descendants(scene.sidebar).first { !$0.isHidden && ["Mute tab", "Unmute tab"].contains($0.accessibilityLabel() ?? "") } }
        func recording() -> NSView? { descendants(scene.sidebar).first { !$0.isHidden && $0.accessibilityLabel() == "This tab is using your camera or microphone" } }
        func event(_ type: NSEvent.EventType, _ view: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        func tooltip(_ button: NSView, _ text: String) {
            button.mouseEntered(with: event(.mouseMoved, button))
            let shown = Checks.waitFor(settle: scene) { TooltipController.shared.visibleTooltip?.title == text }
            Checks.check(shown && button.accessibilityHelp() == text,
                         "RI tooltip and help are exact: \(text)")
            button.mouseExited(with: event(.mouseMoved, button)); pump(0.05)
        }
        SidebarDiagnostics.mediaReduceMotionOverride = false
        pump()
        Checks.check(speaker() == nil, "RI1 silent unmuted row builds no speaker")
        Checks.check(host.frame.maxX < 0 && !host.isKeyWindow, "RI animation window stays offscreen and non-key (visible \(host.isVisible), occlusion \(host.occlusionState.rawValue))")
        tab.live.isAudible = true
        _ = Checks.waitFor(settle: scene) { speaker() != nil }
        guard let button = speaker() else { Checks.check(false, "RI1 audible speaker exists"); return }
        let symbol = descendants(button).compactMap { $0 as? NSImageView }.first
        Checks.check(button.frame.size == CGSize(width: 20, height: 20) && button.frame.minY == 10 && symbol?.image === Glyph.audioPlaying.image && button.accessibilityLabel() == "Mute tab", "RI1 audible unmuted frame and symbol")
        tooltip(button, "Mute tab")
        let audibleLeft = symbol?.frame.minX
        let before = symbol?.image
        model.setMuted(tabID: tab.id, muted: true)
        pump(0.005)
        symbol?.displayIfNeeded(); symbol?.layer?.displayIfNeeded(); CATransaction.flush()
        let during = animationKeys(symbol?.layer)
        let active = during.filter { $0 != "position" && $0 != "bounds" }
        let path = hasFallback(symbol?.layer) ? "approved finite fallback" : "native symbol effect"
        Checks.check(symbol?.image !== before && !active.isEmpty, "RI4 image changes and an actual \(path) animation is active: \(active)")
        Checks.check(symbol?.layer?.animationKeys()?.contains(where: { $0 == "position" || $0 == "bounds" }) != true, "RI4 image-view layer has no position or bounds animation")
        pump(0.35)
        Checks.check(animationKeys(symbol?.layer).isEmpty, "RI4 actual transition finishes with no keys")
        let mutedLeft = symbol?.frame.minX
        Checks.check(audibleLeft != nil && mutedLeft != nil && abs((audibleLeft ?? -100) - (mutedLeft ?? 100)) <= 0.5,
                     "RI image-view left edge stays within 0.5 pt (audible \(String(describing: audibleLeft)), muted \(String(describing: mutedLeft)))")
        Checks.check(symbol?.imageAlignment == .alignLeft && symbol?.frame.minX == RowMediaMetrics.glyphInsetX, "RI speaker uses slot x + 2 left anchor")
        tooltip(button, "Unmute tab")
        let selection = window.selectedNodeBySpace
        let center = button.convert(CGPoint(x: 10, y: 10), to: nil)
        Checks.check(host.contentView?.hitTest(center) === button, "RI2 window hitTest resolves speaker button")
        host.sendEvent(event(.leftMouseDown, button)); host.sendEvent(event(.leftMouseUp, button)); pump(0.12)
        Checks.check(delegate.log.last == .toggleMute(tabID: tab.id) && window.selectedNodeBySpace == selection && !tab.isMuted, "RI2 window events toggle mute without selecting")
        button.mouseDown(with: event(.leftMouseDown, button)); button.mouseUp(with: event(.leftMouseUp, button)); pump(0.12)
        Checks.check(delegate.log.last == .toggleMute(tabID: tab.id) && tab.isMuted && window.selectedNodeBySpace == selection, "RI2 direct native control click also works")
        tab.live.isAudible = false; pump()
        Checks.check(speaker() === button && button.accessibilityLabel() == "Unmute tab", "RI muted silent row retains speaker")
        model.setMuted(tabID: tab.id, muted: false); pump()
        Checks.check(speaker() == nil, "RI4 unmute while inaudible hides speaker")
        tab.live.isAudible = true; pump(0.005)
        Checks.check(button.accessibilityLabel() == "Mute tab" && symbol?.image?.size == Glyph.audioPlaying.image?.size && animationKeys(symbol?.layer).allSatisfy { $0 == "position" || $0 == "bounds" }, "RI4 reveal does not replay hidden unmute")
        tab.live.isCapturing = true; pump()
        Checks.check(recording()?.frame.size == CGSize(width: 14, height: 20) && recording()?.frame.maxX == button.frame.minX && recording()?.accessibilityHelp() == "This tab is using your camera or microphone", "RI3 14x20 recording slot before speaker; exact tooltip")
        tab.live.isAudible = false; pump()
        Checks.check(recording() != nil && speaker() == nil, "RI recording-only row has dot and no speaker")
        SidebarDiagnostics.mediaReduceMotionOverride = true
        tab.live.isAudible = true; pump()
        let staticLeft = inkLeft(button)
        Checks.check(descendants(button).allSatisfy { !($0 is NSImageView) } && animationKeys(button.layer).isEmpty && staticLeft != nil,
                     "RI4 Reduce Motion uses static glyph without animation keys")
        model.setMuted(tabID: tab.id, muted: true); pump()
        let staticMutedLeft = inkLeft(button)
        Checks.check(staticLeft != nil && staticMutedLeft != nil && (staticLeft ?? 0) >= RowMediaMetrics.glyphInsetX && abs((staticLeft ?? -100) - (staticMutedLeft ?? 100)) <= 0.5, "RI static glyph shares the left anchor in both states (\(String(describing: staticLeft)), \(String(describing: staticMutedLeft))); same button \(speaker() === button), hidden \(button.isHidden), size \(button.bounds.size)")
        runNarrowRecording()
        Checks.check(PiPMetrics.compactPlayGlyph == 24, "RI compact PiP play/pause token is 24 pt")
    }
    static func runNarrowRecording() {
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let space = model.spaces.first, let tab = space.today.compactMap(\.tab).first else { return }
        space.pinned = []; space.today = [.tab(tab)]; model.rebuildIndex()
        tab.live.isAudible = true; tab.live.isCapturing = true; tab.live.hasWebContent = true
        var node = tab.id
        for i in 0..<8 {
            guard let folder = model.createFolder(in: .spacePinned(space.id), title: "Folder \(i)", withNodes: [node]) else { break }
            node = folder.id
        }
        window.sidebarWidth = 228
        let context = SidebarContext(model: model, windowID: window.id); context.forcedHover = .row(tab.id)
        let delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 2)
        defer { host.contentView = nil; host.close() }
        OffscreenRenderer.settle(scene, runLoop: 0.02)
        let views = descendants(scene.sidebar)
        let speaker = views.first { !$0.isHidden && $0.accessibilityLabel() == "Mute tab" }
        let dot = views.first { !$0.isHidden && $0.accessibilityLabel() == "This tab is using your camera or microphone" }
        Checks.check(speaker?.frame.width == 20 && dot == nil, "RI narrow deep hovered row hides dot before speaker")
    }
}

extension MediaChecks {
    static func runMiniPlayers() {
        print("MC1–MC10: composed sidebar, fake media hosts, native events and idle layers")
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let space = model.spaces.first else { return }
        let context = SidebarContext(model: model, windowID: window.id)
        let store = MediaSourceStore(); context.media = store
        let delegate = MediaHarnessDelegate(context: context)
        let tab = model.newTab(in: space.id, url: URL(string: "https://media.example.test/song")!, title: "A short media title")
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let windowHost = OffscreenRenderer.host(scene, scale: 2)
        let controls = scene.sidebar.mediaControls
        let priorForce = SidebarDiagnostics.forceAnimations
        SidebarDiagnostics.forceAnimations = true; SidebarDiagnostics.mediaReduceMotionOverride = false
        windowHost.orderBack(nil)
        defer {
            windowHost.orderOut(nil); windowHost.contentView = nil; windowHost.close()
            SidebarDiagnostics.forceAnimations = priorForce; SidebarDiagnostics.mediaReduceMotionOverride = nil
        }
        func pump(_ seconds: Double = 0.05) { OffscreenRenderer.settle(scene, runLoop: seconds / 3) }
        func event(_ type: NSEvent.EventType, _ view: NSView, fraction: CGFloat = 0.5) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: view.bounds.width * fraction, y: view.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowHost.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        func click(_ view: NSView, _ name: String, fraction: CGFloat = 0.5) {
            let down = event(.leftMouseDown, view, fraction: fraction)
            Checks.check(windowHost.contentView?.hitTest(down.locationInWindow) === view, "MC5 native hit test: \(name)")
            windowHost.sendEvent(down); windowHost.sendEvent(event(.leftMouseUp, view, fraction: fraction)); pump(0.2)
        }
        func card() -> MiniPlayerCardView? { controls.cards.first { $0.source.tabID == tab.id } }
        pump(0.2)
        Checks.check(controls.requiredHeight == 0 && controls.frame.height == 0 && scene.sidebar.focusedOutline?.enclosingScrollView?.frame.height != nil,
                     "MC1 no source reserves no media height")
        let emptyPagerBottom = descendants(scene.sidebar).first { String(describing: type(of: $0)) == "SpacePagerView" }?.frame.maxY
        Checks.check(emptyPagerBottom == scene.sidebar.bounds.height - 50, "MC1 pager ends at h - 50")
        let state = WebMediaState(playback: .playing, isControllable: true, hasVideo: true, largestVideoArea: 640 * 360,
                                  actions: [.play, .pause, .previousTrack, .nextTrack], volume: 0.5)
        let mediaHost = delegate.add(tab: tab, state: state); pump(0.5)
        guard let first = card() else { Checks.check(false, "MC2 first card exists"); return }
        let global = first.convert(first.bounds, to: scene.sidebar)
        Checks.check(controls.requiredHeight == 76 && abs(global.minX - 8) <= 0.5 && abs(global.minY - (900 - 50 - 72)) <= 0.5 &&
                     abs(global.width - (scene.sidebar.bounds.width - 16)) <= 0.5 && global.height == 68, "MC2 first card frame and C=76: \(global)")
        let specs: [(String, CGFloat, CGFloat, Glyph, String)] = [
            ("previous", 6, 40, .mediaPrevious, "Previous Track"), ("play", 34, 40, .mediaPause, "Pause"),
            ("next", 62, 40, .mediaNext, "Next Track"), ("volume", first.bounds.width - 30, 40, .mediaVolume, "Adjust Tab Volume"),
            ("pip", first.bounds.width - 30, 6, .mediaPiP, "Open Picture in Picture")]
        for (id, x, y, glyph, title) in specs {
            let item = first.control(named: id)
            Checks.check(item?.view.frame == CGRect(x: x, y: y, width: 24, height: 24) && item?.glyph == glyph &&
                         item?.tooltip?.title == title && item?.tooltip?.placement == .above && item?.tooltip?.showDelay == 0.45 && item?.view.accessibilityHelp() == title,
                         "MC3 frame, glyph, tooltip and help: \(id)")
        }
        if let play = first.control(named: "play")?.view {
            play.mouseEntered(with: event(.mouseMoved, play))
            let tooltipShown = Checks.waitFor(settle: scene) { TooltipController.shared.visibleTooltip?.title == "Pause" }
            Checks.check(tooltipShown, "MC3 actual media tooltip appears after its 0.45 s delay")
            play.mouseExited(with: event(.mouseMoved, play)); pump(0.2)
        }
        Checks.check(first.control(named: "close")?.view.frame.width == 0, "MC4 close starts 0 wide")
        context.forcedMediaHover = .card(tab.id); pump(0.25)
        Checks.check(first.control(named: "close")?.view.frame.width == 24 && first.control(named: "close")?.view.alphaValue == 1, "MC4 hover reveals 24 pt close")
        context.forcedMediaHover = nil; pump(0.25)
        Checks.check(first.control(named: "close")?.view.frame.width == 0, "MC4 exit hides close")
        let selection = window.selectedNodeBySpace
        for id in ["previous", "next", "play", "play"] { if let button = first.control(named: id)?.view { click(button, id) } }
        Checks.check(mediaHost.calls.contains(.action(.previousTrack)) && mediaHost.calls.contains(.action(.nextTrack)) &&
                     mediaHost.calls.contains(.action(.pause)) && mediaHost.calls.contains(.action(.play)) && window.selectedNodeBySpace == selection,
                     "MC5 playback controls reach the fake host without selecting")
        mediaHost.mediaState.actions = [.play, .pause]; mediaHost.publish(); pump()
        Checks.check(first.control(named: "previous")?.view.isHidden == true && first.control(named: "next")?.view.isHidden == true &&
                     first.control(named: "play")?.view.frame.minX == 6, "MC3 previous/next hide and play shifts to x=6")
        if let volume = first.control(named: "volume")?.view { click(volume, "volume drawer") }
        Checks.check(first.drawerIsOpen && first.cardHeight == 96 && controls.requiredHeight == 104, "MC3 drawer adds 28 pt")
        if let slider = descendants(first).first(where: { $0.accessibilityLabel() == "Tab Volume" }) {
            click(slider, "volume slider", fraction: (6 + 0.4 * (slider.bounds.width - 12)) / slider.bounds.width)
            Checks.check(mediaHost.calls.contains(.volume(0.4)) && slider.accessibilityValue() as? String == "40%", "MC5 slider delivers volume and percentage")
            _ = slider.accessibilityPerformIncrement(); pump()
            Checks.check(abs((mediaHost.mediaState.volume ?? -1) - 0.5) < 0.001, "MC5 slider accessibility increments by 10 percent")
        } else { Checks.check(false, "MC3 volume slider exists") }
        if let volume = first.control(named: "volume")?.view { click(volume, "close drawer") }
        mediaHost.mediaState.volume = nil; mediaHost.publish(); pump()
        if let volume = first.control(named: "volume")?.view { click(volume, "interim mute toggle") }
        Checks.check(tab.isMuted && !first.drawerIsOpen && first.control(named: "volume")?.glyph == .mediaVolumeMuted,
                     "MC5 interim volume control toggles mute when volume is unavailable")
        let extra1 = model.newTab(in: space.id, url: URL(string: "https://media.example.test/second")!, title: "Second")
        let extra2 = model.newTab(in: space.id, url: URL(string: "https://media.example.test/third")!, title: "Third")
        _ = delegate.add(tab: extra1, state: WebMediaState(playback: .playing, isControllable: true))
        _ = delegate.add(tab: extra2, state: WebMediaState(playback: .paused, isControllable: true)); pump(0.7)
        Checks.check(controls.cards.count == 3 && controls.stackHeight == 78 && controls.requiredHeight == 86,
                     "MC6 three collapsed cards reserve 68+10 pt")
        Checks.check(controls.cards.dropFirst().allSatisfy { ($0.layer?.mask as? CAShapeLayer)?.path?.boundingBox.height == 5 && !$0.marquee.isRunning },
                     "MC6 back cards are clipped and their marquees stop")
        controls.mouseEntered(with: event(.mouseMoved, controls))
        let expanded = Checks.waitFor(settle: scene) { controls.isExpanded && controls.stackHeight == 216 && controls.cards.allSatisfy { $0.layer?.mask == nil } }
        Checks.check(expanded, "MC6 hover expands to 3*68+12")
        controls.mouseExited(with: event(.mouseMoved, controls))
        // Logic, not wall clock: the exit schedules one collapse at 0.3 s and
        // the stack is still expanded until that work runs.
        Checks.check(controls.isExpanded && controls.pendingCollapseCount == 1 && controls.pendingCollapseDelay == 0.3, "MC6 exit waits 0.3 s")
        let collapsed = Checks.waitFor(settle: scene) { !controls.isExpanded && controls.pendingCollapseCount == 0 }
        Checks.check(collapsed && controls.stackHeight == 78, "MC6 real delayed work collapses the stack")
        store.remove(tabID: extra1.id); store.remove(tabID: extra2.id); pump(0.7)
        tab.title = "A deliberately long playing title which must overflow this narrow mini player and keep scrolling"; mediaHost.perform(.play); pump(0.25)
        Checks.check(first.marquee.isOverflowing && first.marquee.isRunning, "MC7 overflowing playing title runs in a visible window")
        Checks.check(inkLeft(first.marquee, direct: true) != nil, "MC7 live cacheDisplay snapshot contains playing long-title ink")
        context.forcedMediaHover = .title(tab.id); pump(0.25)
        Checks.check(!first.marquee.isRunning, "MC7 title hover stops the marquee")
        context.forcedMediaHover = nil; mediaHost.perform(.pause); pump(0.25)
        Checks.check(!first.marquee.isRunning, "MC7 paused title is static")
        mediaHost.perform(.play); tab.title = "Short"; pump(0.25)
        let copies = first.marquee.layer?.sublayers?.first?.sublayers?.compactMap { $0 as? CATextLayer } ?? []
        Checks.check(!first.marquee.isOverflowing && !first.marquee.isRunning && copies.filter { !$0.isHidden }.count == 1, "MC7 fitting title has one visible copy and never starts a marquee")
        tab.title = "A deliberately long title for the visibility and Reduce Motion checks"; pump(0.25)
        SidebarDiagnostics.mediaReduceMotionOverride = true; context.forcedMediaHover = .card(tab.id); pump(0.25)
        Checks.check(!first.marquee.isRunning, "MC7 Reduce Motion stops the marquee")
        SidebarDiagnostics.mediaReduceMotionOverride = false; context.forcedMediaHover = nil; pump(0.25)
        scene.sidebar.isHidden = true; pump(0.1)
        Checks.check(!first.marquee.isRunning, "MC7 hidden sidebar stops the marquee")
        scene.sidebar.isHidden = false; pump(0.1)
        windowHost.orderOut(nil); pump(0.15)
        Checks.check(!first.marquee.isRunning, "MC7 ordered-out window stops the marquee")
        windowHost.orderBack(nil); mediaHost.perform(.pause); tab.title = "Paused"; pump(1.2)
        Checks.check(animationKeys(scene.layer).isEmpty && !first.marquee.isRunning && controls.pendingCollapseCount == 0 && store.pendingWorkItemCount == 1,
                     "MC8 idle paused window has no CA animations and only the one store dismiss item")
        func cpuSeconds() -> Double {
            var time = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }
        let cpuStart = cpuSeconds(), wallStart = CACurrentMediaTime()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let idleCPU = 100 * (cpuSeconds() - cpuStart) / (CACurrentMediaTime() - wallStart)
        Checks.check(idleCPU <= 0.5, String(format: "MC8 idle paused CLI CPU %.3f%% (budget 0.5%%); no media Timer or display link", idleCPU))
        context.shownPeek = SidebarShownPeek(sourceNodeID: tab.id, url: URL(string: "https://peek.example.test/")!); pump(0.15)
        Checks.check(controls.alphaValue == SidebarRole.peekBottomBarOpacity, "MC10 mini controls dim with the bottom bar in Peek")
        context.shownPeek = nil; pump(0.15)
        Checks.check(controls.alphaValue == 1, "MC10 closing Peek restores opacity")
        if let pip = first.control(named: "pip")?.view { click(pip, "picture in picture") }
        Checks.check(mediaHost.calls.contains(.enterPiP) && controls.cards.isEmpty, "MC5 PiP request reaches the fake host and hides the active source")
        mediaHost.exitPictureInPicture(pausing: false); mediaHost.perform(.play); pump(0.6)
        if let current = card(), let title = descendants(current).first(where: { $0.accessibilityIdentifier() == "media.title" }) { click(title, "title back to tab") }
        Checks.check(delegate.intents.last == .backToTab(tab.id) && controls.cards.isEmpty, "MC5 title returns to the tab")
        context.displayedTabIDs = []; pump(0.6)
        context.forcedMediaHover = .card(tab.id); pump(0.2)
        if let close = card()?.control(named: "close")?.view { click(close, "close mini player") }
        pump(0.5)
        Checks.check(delegate.intents.last == .close(tab.id) && mediaHost.calls.last == .action(.pause) && controls.cards.isEmpty && controls.requiredHeight == 0,
                     "MC5 close pauses and removes the last card")
        mediaHost.perform(.play); pump(0.5)
        let old = card(); store.remove(tabID: tab.id); mediaHost.publish(); pump(0.01)
        if let old, let replacement = card(), let button = replacement.control(named: "play")?.view {
            // Put A above B to prove A itself refuses hits throughout its finite fade.
            controls.addSubview(old, positioned: .above, relativeTo: replacement)
            Checks.check(old.isRetiring && !old.isHidden && old.layer?.animation(forKey: "media.disappear") != nil,
                         "MC retiring card stays visible for its fade but is marked non-interactive")
            let before = mediaHost.calls.count
            click(button, "replacement B during A fade")
            Checks.check(mediaHost.calls.count == before + 1 && mediaHost.calls.last == .action(.pause), "MC replacement B receives the click during A fade")
        } else { Checks.check(false, "MC replacement card exists during fade") }
        pump(0.8)
        Checks.check(card() !== old && controls.cards.count == 1 && controls.subviews.compactMap { $0 as? MiniPlayerCardView }.count == 1,
                     "MC source replacement within one event turn leaves one fresh card and no retired view")
        if let volume = card()?.control(named: "volume")?.view { mediaHost.mediaState.volume = 1; mediaHost.publish(); pump(); click(volume, "drawer before tab close") }
        Checks.check(context.mediaDrawers.contains(tab.id), "MC3 drawer is open before tab close")
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.closeTab(id: tab.id); store.remove(tabID: tab.id); pump(0.25)
        Checks.check(!context.mediaDrawers.contains(tab.id), "MC5 tab close prunes its drawer ID")
        undo.undo(); mediaHost.publish(); pump(0.4)
        Checks.check(card()?.cardHeight == 68 && card()?.drawerIsOpen == false, "MC3 recreated source returns as a 68 pt card")
        model.undoManager = nil
        store.remove(tabID: tab.id); context.forcedMediaHover = nil; pump(0.5)
        let recording = model.newTab(in: space.id, url: URL(string: "https://meeting.example.test/")!, title: "Meeting")
        recording.live.isCapturing = true
        let recordingHost = delegate.add(tab: recording, state: WebMediaState(isControllable: true, actions: [.toggleMicrophone, .toggleCamera], microphoneMuted: false, cameraOn: true))
        pump(0.5)
        if let recordingCard = controls.cards.first {
            Checks.check(recordingCard.control(named: "play")?.view.isHidden == true && recordingCard.control(named: "volume")?.view.isHidden == true &&
                         recordingCard.control(named: "microphone")?.view.frame == CGRect(x: 6, y: 40, width: 24, height: 24) && recordingCard.control(named: "camera")?.view.frame == CGRect(x: 34, y: 40, width: 24, height: 24),
                         "MC3 recording card shows microphone/camera instead of play and volume")
            for id in ["microphone", "camera"] { if let button = recordingCard.control(named: id)?.view { click(button, id) } }
            Checks.check(recordingHost.calls == [.action(.toggleMicrophone), .action(.toggleCamera)] && recordingCard.control(named: "microphone")?.glyph == .mediaMicrophoneMuted && recordingCard.control(named: "camera")?.glyph == .mediaCameraOff,
                         "MC5 recording controls reach the host and update their glyphs")
        } else { Checks.check(false, "MC3 recording card exists") }
    }
}
