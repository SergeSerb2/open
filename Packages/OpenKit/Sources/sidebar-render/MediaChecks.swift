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
    /// Ink box of the static speaker glyph in its own points: pixels with at least half of the
    /// peak alpha (the docs/design.md §7 50 % rule on a transparent background).
    static func inkBox(_ view: NSView) -> CGRect? {
        guard let glyph = descendants(view).first(where: { $0.identifier?.rawValue == "media.speakerGlyph" }) else { return nil }
        guard let bitmap = glyph.bitmapImageRepForCachingDisplay(in: glyph.bounds) else { return nil }
        // The static glyph draws with AppKit. Read it synchronously rather than sampling
        // a GPU layer clone while its contents are still being published. (The image-view
        // path is not measured this way: after a symbol transition neither cacheDisplay nor
        // layer.render shows what the window composites. Its frame and alignment are checked.)
        glyph.cacheDisplay(in: glyph.bounds, to: bitmap)
        var peak: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide { peak = max(peak, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
        guard peak > 0.1 else { return nil }
        var box: CGRect?
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 * peak {
            box = (box ?? CGRect(x: x, y: y, width: 0, height: 0)).union(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let s = glyph.bounds.width / CGFloat(bitmap.pixelsWide)
        return box.map { CGRect(x: $0.minX * s, y: $0.minY * s, width: $0.width * s, height: $0.height * s) }
    }
    /// The row title label beside a media view (the cell's `TextLabel`), in cell points.
    static func titleFrame(_ media: NSView) -> CGRect? {
        media.superview?.subviews.first { String(describing: type(of: $0)) == "TextLabel" }?.frame
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
        Checks.check(button.frame == CGRect(x: 41, y: 7, width: 26, height: 26) && symbol?.image === Glyph.audioPlaying.image && Glyph.audioPlaying.spec.symbol == "speaker.wave.3" &&
                     button.accessibilityLabel() == "Mute tab" && button.accessibilityIdentifier() == "sidebarTabCellMuteButton",
                     "RI1 audible unmuted: leading [41, 7, 26, 26], outline speaker.wave.3, AX id (\(button.frame))")
        Checks.check(titleFrame(button)?.minX == 69, "RI1 title frame moves to x 69 (text origin 70): \(String(describing: titleFrame(button)))")
        tooltip(button, "Mute this tab")
        button.mouseEntered(with: event(.mouseMoved, button)); pump(0.3)
        let plate = button.layer?.sublayers?.first { $0.cornerRadius == 6 }
        Checks.check(plate?.frame == button.bounds && plate?.opacity == 1 && plate?.cornerCurve == .continuous,
                     "RI speaker hover plate like the close button: button frame, radius 6 (guess)")
        button.mouseExited(with: event(.mouseMoved, button)); TooltipController.shared.cancel(for: button); pump(0.3)
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
        Checks.check(symbol?.image === Glyph.audioMuted.image && Glyph.audioMuted.spec.symbol == "speaker.slash" && button.frame == CGRect(x: 41, y: 7, width: 26, height: 26),
                     "RI1 muted audible: outline speaker.slash in the same leading frame")
        Checks.check(symbol?.imageAlignment == .alignCenter && symbol?.frame == button.bounds, "RI speaker image view is one fixed frame equal to the button, centered")
        tooltip(button, "Unmute this tab")
        let selection = window.selectedNodeBySpace
        let center = button.convert(CGPoint(x: 13, y: 13), to: nil)
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
        Checks.check(recording()?.frame == CGRect(x: 41, y: 10, width: 14, height: 20) && recording()?.frame.maxX == button.frame.minX && button.frame.minX == 55 &&
                     titleFrame(button)?.minX == 83 && recording()?.accessibilityHelp() == "This tab is using your camera or microphone",
                     "RI3 leading 14x20 recording slot after the favicon, speaker at 55, title at 83; exact tooltip (\(String(describing: recording()?.frame)))")
        tab.live.isAudible = false; pump()
        Checks.check(recording()?.frame.minX == 41 && speaker() == nil && recording().flatMap(titleFrame)?.minX == 57,
                     "RI recording-only row has the leading dot, no speaker, title at 57")
        SidebarDiagnostics.mediaReduceMotionOverride = true
        tab.live.isAudible = true; pump()
        let staticBox = inkBox(button)
        Checks.check(descendants(button).allSatisfy { !($0 is NSImageView) } && animationKeys(button.layer).isEmpty && staticBox != nil,
                     "RI4 Reduce Motion uses static glyph without animation keys")
        model.setMuted(tabID: tab.id, muted: true); pump()
        let staticMutedBox = inkBox(button)
        func centered(_ b: CGRect?) -> Bool { b.map { abs($0.midX - 13) <= 1 && abs($0.midY - 13) <= 1 } ?? false }
        Checks.check(centered(staticBox) && centered(staticMutedBox),
                     "RI static glyph is centered in the 26 pt button in both states (\(String(describing: staticBox)), \(String(describing: staticMutedBox))); same button \(speaker() === button), hidden \(button.isHidden), size \(button.bounds.size)")
        runNarrowRecording()
        runLeadingSpeaker()
        Checks.check(PiPMetrics.compactPlayGlyph == 24, "RI compact PiP play/pause token is 24 pt")
    }
    /// RI5 (media plan §8.2, Step 2b): a real 1x render of the selected row in the default
    /// dark theme, measured with the docs/design.md §7 ink method against the values that
    /// `compare-media --state row-audible|row-muted` measured in S2 12/0022 and 12/0027
    /// (row-relative points, sRGB from the unclipped float path). No capture pixels here.
    static func runLeadingSpeaker() {
        struct Fact { var state: String; var ink: CGRect; var core: [Double]; var peak: [Double] }
        let facts = [Fact(state: "audible", ink: CGRect(x: 44, y: 15, width: 19, height: 11), core: [0xB3, 0xB3, 0xBA], peak: [0xB8, 0xB8, 0xBF]),
                     Fact(state: "audible:muted", ink: CGRect(x: 47, y: 13, width: 14, height: 14), core: [0xB5, 0xB5, 0xBC], peak: [0xB8, 0xB8, 0xBE])]
        defer { SidebarDiagnostics.mediaReduceMotionOverride = nil }
        for fact in facts {
            let model = Synthetic.model(); model.rebuildIndex()
            guard let context = try? RenderCLI.makeContext(["--appearance", "dark", "--media-theme", "default", "--select", "today:0", "--media", "today:0=\(fact.state)"], model: model),
                  let space = context.focusedSpace, let tab = space.today.first?.tab, let silent = space.today.dropFirst().first?.tab else {
                Checks.check(false, "RI5 \(fact.state) scene"); continue
            }
            let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: MediaScene.delegate(context: context))
            let image = OffscreenRenderer().render(scene, scale: 1)
            let views = descendants(scene.sidebar)
            guard let button = views.first(where: { !$0.isHidden && $0.accessibilityIdentifier() == "sidebarTabCellMuteButton" }),
                  let row = scene.sidebar.rowFrame(nodeID: tab.id), let silentRow = scene.sidebar.rowFrame(nodeID: silent.id),
                  let silentTitle = views.first(where: { String(describing: type(of: $0)) == "TextLabel" && $0.superview.map { $0.convert($0.bounds, to: scene.sidebar).minY } == silentRow.minY })?.frame
            else { Checks.check(false, "RI5 \(fact.state) speaker row exists"); continue }
            let glyph = tab.isMuted ? Glyph.audioMuted : Glyph.audioPlaying
            let title = titleFrame(button)
            Checks.check(button.frame == CGRect(x: 41, y: 7, width: 26, height: 26) && !glyph.spec.symbol.contains(".fill") &&
                         title?.minX == 69 && title.map { $0.minX + SpaceListMetrics.textInset } == 70 && title?.maxX == silentTitle.maxX,
                         "RI5 \(fact.state): speaker [41, y + 7, 26, 26], outline \(glyph.spec.symbol), title origin 70, right end unchanged (\(String(describing: title)) vs \(silentTitle))")
            let origin = scene.convert(row.origin, from: scene.sidebar)
            let bitmap = Bitmap(image: image)
            guard let ink = RowMediaCompare.ink(bitmap, RowMediaCompare.glyphRegion.offsetBy(dx: origin.x, dy: origin.y)) else {
                Checks.check(false, "RI5 \(fact.state) glyph ink"); continue
            }
            let box = ink.box.offsetBy(dx: -origin.x, dy: -origin.y)
            let edge = [abs(box.minX - fact.ink.minX), abs(box.minY - fact.ink.minY), abs(box.maxX - fact.ink.maxX), abs(box.maxY - fact.ink.maxY)].max()!
            let core = ink.core.reduce([0.0, 0, 0]) { s, p in zip(s, bitmap.pixel(p.0, p.1)).map(+) }.map { $0 / Double(max(1, ink.core.count)) }
            let coreDE = ColorMath.deltaE2000(core, fact.core), peakDE = ColorMath.deltaE2000(bitmap.pixel(ink.peak.0, ink.peak.1), fact.peak)
            Checks.check(edge <= 1 && coreDE <= 2 && peakDE <= 2,
                         String(format: "RI5 %@: ink box %@ vs Arc %@ (edge %.1f pt ≤ 1), core ΔE00 %.2f ≤ 2, peak ΔE00 %.2f ≤ 2", fact.state, "\(box)", "\(fact.ink)", edge, coreDE, peakDE))
        }
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
        Checks.check(speaker?.frame.width == 26 && dot == nil, "RI narrow deep hovered row hides dot before speaker")
    }
}

extension MediaChecks {
    static func runMiniPlayers() {
        print("MC1–MC15: real composed sidebar, native events, offscreen layers (MC9 uses compare-bench.py)")
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let space = model.spaces.first else { return }
        window.sidebarWidth = 228; space.theme = SpaceTheme()
        let context = SidebarContext(model: model, windowID: window.id); context.systemAppearance = .dark
        let store = MediaSourceStore(); context.media = store
        let delegate = MediaHarnessDelegate(context: context)
        let tab = model.newTab(in: space.id, url: URL(string: "https://media.example.test/song")!, title: "A short media title")
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let windowHost = OffscreenRenderer.host(scene, scale: 2), controls = scene.sidebar.mediaControls
        let priorForce = SidebarDiagnostics.forceAnimations, priorReduce = Motion.reduceMotionOverride
        SidebarDiagnostics.forceAnimations = true; SidebarDiagnostics.mediaReduceMotionOverride = false
        windowHost.orderBack(nil)
        defer {
            windowHost.orderOut(nil); windowHost.contentView = nil; windowHost.close()
            SidebarDiagnostics.forceAnimations = priorForce; SidebarDiagnostics.mediaReduceMotionOverride = nil; Motion.reduceMotionOverride = priorReduce
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
        func named(_ card: NSView, _ name: String) -> NSView? { descendants(card).first { $0.identifier?.rawValue == name } }
        func pager() -> NSView? { descendants(scene.sidebar).first { String(describing: type(of: $0)) == "SpacePagerView" } }
        func closeEnough(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) <= 0.5 }
        pump(0.2)
        Checks.check(controls.requiredHeight == 0 && controls.frame.height == 0 && pager()?.frame.maxY == 850, "MC1 no source: C=0, pager ends at h-50")
        let state = WebMediaState(playback: .playing, isControllable: true, hasVideo: true, largestVideoArea: 640 * 360,
                                  actions: [.play, .pause, .previousTrack, .nextTrack], volume: 0.5)
        let mediaHost = delegate.add(tab: tab, state: state); pump(0.8)
        guard let first = card() else { Checks.check(false, "MC2 first card exists"); return }
        let global = first.convert(first.bounds, to: scene.sidebar)
        Checks.check(controls.requiredHeight == 41 && global == CGRect(x: 8, y: 817, width: 212, height: 33) && pager()?.frame.maxY == 809,
                     "MC2 rest card [8,h-83,W-16,33], C=41 and pager h-91: \(global)")
        let specs: [(String, CGFloat, Glyph?, String)] = [
            ("favicon",10,nil,"Back to Tab"), ("previous",52,.mediaPrevious,"Previous Track"),
            ("play",94,.mediaPause,"Pause"), ("next",136,.mediaNext,"Next Track"), ("volume",178,.mediaVolume,"Adjust Tab Volume")]
        for (id,x,glyph,title) in specs {
            let item = first.control(named:id)
            Checks.check(item?.view.frame == CGRect(x:x,y:5,width:24,height:24) && item?.glyph == glyph && item?.view.accessibilityLabel() == title &&
                         (id == "favicon" ? item?.tooltip == nil : (item?.tooltip?.title == title && item?.tooltip?.placement == .beside && item?.tooltip?.showDelay == 0.45)),
                         "MC3 slot, glyph, tooltip: \(id)")
        }
        mediaHost.mediaState.actions = [.play,.pause]; mediaHost.publish(); pump()
        for id in ["previous","next"] {
            guard let b = first.control(named:id)?.view else { Checks.check(false,"MC3 disabled control exists"); continue }
            let count = delegate.intents.count
            b.mouseEntered(with:event(.mouseMoved,b)); pump(0.15)
            let plates = b.layer?.sublayers?.filter { $0.cornerRadius == MiniPlayerMetrics.buttonPlateRadius } ?? []
            Checks.check(!b.isHidden && !b.isAccessibilityEnabled() && first.control(named:id)?.tooltip == nil && plates.count == 1 && plates.allSatisfy { $0.opacity == 0 }, "MC3 disabled \(id) is present, no tooltip or hover plate")
            click(b,id); b.mouseExited(with:event(.mouseMoved,b))
            Checks.check(delegate.intents.count == count, "MC3 disabled \(id) sends no intent")
        }
        mediaHost.mediaState.actions = state.actions; mediaHost.publish(); pump()
        Checks.check(["previous","next"].allSatisfy { first.control(named:$0)?.view.isAccessibilityEnabled() == true }, "MC3 track actions enable both controls")
        if let play = first.control(named:"play")?.view {
            play.mouseEntered(with:event(.mouseMoved,play))
            let shown = Checks.waitFor(settle: scene) { TooltipController.shared.visibleTooltip?.title == "Pause" }
            Checks.check(shown, "MC3 actual delayed tooltip")
            play.mouseExited(with:event(.mouseMoved,play)); pump(0.2)
        }
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.01)
        Checks.check(!animationKeys(first.layer).isEmpty && !animationKeys(pager()?.layer).isEmpty && !animationKeys(named(first,"media.titleRow")?.layer).isEmpty,
                     "MC15 hover starts card, pager and title-row animations")
        pump(0.8)
        let expandedFrame = first.convert(first.bounds,to:scene.sidebar)
        Checks.check(controls.isExpanded && controls.requiredHeight == 74 && expandedFrame == CGRect(x:8,y:784,width:212,height:66) &&
                     first.titleState.frame == CGRect(x:14,y:0,width:130,height:33) && first.titleState.baseline == 22 && first.titleState.fontSize == 13 && first.control(named:"pip")?.view.frame == CGRect(x:154,y:5,width:24,height:24) &&
                     first.control(named:"close")?.view.frame == CGRect(x:178,y:5,width:24,height:24), "MC4 one card hover expands with title, PiP and Close")
        Checks.check(animationKeys(scene.layer).isEmpty, "MC15 all finite hover animations finish")
        mediaHost.mediaState.hasVideo = false; mediaHost.publish(); pump()
        Checks.check(first.control(named:"pip")?.view.isHidden == true && named(first,"media.titleLabel")?.frame.width == 154, "MC4 audio-only title ends 10 pt before Close")
        mediaHost.mediaState.hasVideo = true; mediaHost.publish(); pump()
        let selection = window.selectedNodeBySpace
        for id in ["previous","next","play","play"] { if let b = first.control(named:id)?.view { click(b,id) } }
        Checks.check(mediaHost.calls.contains(.action(.previousTrack)) && mediaHost.calls.contains(.action(.nextTrack)) && mediaHost.calls.contains(.action(.pause)) && mediaHost.calls.contains(.action(.play)) && window.selectedNodeBySpace == selection,
                     "MC5 native controls reach host without selecting")
        if let b = first.control(named:"volume")?.view { click(b,"open drawer") }
        Checks.check(first.drawerIsOpen && first.cardHeight == 99 && controls.requiredHeight == 107 && named(first,"media.drawerRow")?.frame == CGRect(x:0,y:33,width:212,height:33), "MC13 drawer between title and controls gives C=107")
        if let slider = descendants(first).first(where: { $0.accessibilityLabel() == "Tab Volume" }) {
            Checks.check(slider.frame == CGRect(x:44,y:0,width:124,height:33), "MC13 33 pt drawer slider geometry")
            click(slider,"volume slider",fraction:(6+0.4*(slider.bounds.width-12))/slider.bounds.width)
            Checks.check(mediaHost.calls.contains(.volume(0.4)) && slider.accessibilityValue() as? String == "40%", "MC5 slider sets host volume")
            _ = slider.accessibilityPerformIncrement(); pump()
            Checks.check(abs((mediaHost.mediaState.volume ?? -1)-0.45) < 0.001, "MC13 slider AX uses 0.05 steps")
        }
        controls.mouseExited(with:event(.mouseMoved,controls))
        Checks.check(controls.isExpanded && controls.pendingCollapseCount == 1 && controls.pendingCollapseDelay == 0.3, "MC4 exit schedules exactly one collapse at 0.3 s")
        pump(0.6)
        Checks.check(first.cardHeight == 33 && controls.requiredHeight == 41 && !first.drawerIsOpen && context.mediaDrawers.isEmpty && named(first,"media.titleRow")?.isHidden == true,
                     "MC4/MC13 collapse closes drawer and hides title hit targets")
        mediaHost.mediaState.volume = nil; mediaHost.publish(); pump()
        if let b = first.control(named:"volume")?.view { click(b,"interim mute") }
        Checks.check(tab.isMuted && !first.drawerIsOpen && first.control(named:"volume")?.glyph == .mediaVolumeMuted, "MC5 Q8 volume toggles mute without EM-2")
        let extra1 = model.newTab(in:space.id,url:URL(string:"https://media.example.test/second")!,title:"Second")
        let extra2 = model.newTab(in:space.id,url:URL(string:"https://media.example.test/third")!,title:"Third")
        _ = delegate.add(tab:extra1,state:WebMediaState(playback:.paused,isControllable:true))
        _ = delegate.add(tab:extra2,state:WebMediaState(playback:.paused,isControllable:true)); pump(0.8)
        Checks.check(controls.cards.count == 3 && controls.requiredHeight == 55 && controls.stackHeight == 47 && controls.hoverRect == CGRect(x:8,y:8,width:212,height:47), "MC6 collapsed stack C=55 and exact hover rect")
        for (i,c) in controls.cards.enumerated() {
            Checks.check(c.frame == CGRect(x:8+5*CGFloat(i),y:22-7*CGFloat(i),width:212-10*CGFloat(i),height:33) && abs(c.alphaValue-(1-0.2*CGFloat(i))) < 0.002 && c.layer?.mask == nil && c.layer?.allowsGroupOpacity == true && c.layer?.shouldRasterize == false,
                         "MC6 card \(i) frame, opacity, no mask or rasterization")
            if i > 0 {
                let p = CGPoint(x:c.frame.midX,y:c.frame.minY+2)
                Checks.check(c.hitTest(p) == nil, "MC6 back strip \(i) takes no hit")
                let expected: [CGFloat] = i == 1 ? [23,62.5,102,141.5,181] : [28,65,102,139,176]
                for (k,id) in ["favicon","previous","play","next","volume"].enumerated() {
                    if let b = c.control(named:id)?.view { Checks.check(closeEnough(b.convert(b.bounds,to:controls).minX,expected[k]),"MC6 back card \(i) slot \(k) at scale 2") }
                }
            }
        }
        windowHost.scale = 1
        for c in controls.cards { c.needsLayout = true }; pump()
        for (i,c) in controls.cards.enumerated() where i > 0 {
            let expected: [CGFloat] = i == 1 ? [23,63,102,142,181] : [28,65,102,139,176]
            for (k,id) in ["favicon","previous","play","next","volume"].enumerated() {
                if let b=c.control(named:id)?.view { Checks.check(b.convert(b.bounds,to:controls).minX == expected[k],"MC6 back card \(i) slot \(k) rounds halves up at 1x") }
            }
        }
        windowHost.scale = 2; for c in controls.cards { c.needsLayout = true }; pump()
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.8)
        Checks.check(controls.requiredHeight == 216 && controls.cards.enumerated().allSatisfy { i,c in c.frame == CGRect(x:8,y:150-71*CGFloat(i),width:212,height:66) && c.alphaValue == 1 && c.control(named:"close")?.view.isHiddenOrHasHiddenAncestor == false }, "MC6 expanded stack C=216, 5 pt gaps, all Close buttons")
        controls.mouseExited(with:event(.mouseMoved,controls))
        Checks.check(controls.isExpanded && controls.pendingCollapseCount == 1 && controls.pendingCollapseDelay == 0.3, "MC6 exit schedules exactly one collapse at 0.3 s")
        let collapsed = Checks.waitFor(settle: scene) { !controls.isExpanded && controls.pendingCollapseCount == 0 }
        Checks.check(collapsed && controls.requiredHeight == 55, "MC6 real delayed work collapses to C=55")
        store.remove(tabID:extra1.id); store.remove(tabID:extra2.id); pump(0.8)
        tab.title = "A deliberately long media title whose last words must be truncated at the end"; mediaHost.perform(.play)
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.8)
        let label = named(first,"media.titleLabel")
        if let label, let bitmap = label.bitmapImageRepForCachingDisplay(in:label.bounds) {
            label.cacheDisplay(in:label.bounds,to:bitmap)
            var ink = 0, outside = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.2 { ink += 1; if CGFloat(y) * label.bounds.height / CGFloat(bitmap.pixelsHigh) > 26 || CGFloat(y) * label.bounds.height / CGFloat(bitmap.pixelsHigh) < 7 { outside += 1 } } }
            Checks.check(ink > 0 && outside == 0 && label.frame.width == 130 && (tab.displayTitle as NSString).size(withAttributes:[.font:Typography.miniPlayerTitle.font]).width > 130,
                         "MC7 long title draws one static, bounded line at baseline 22 (ink \(ink), outside \(outside), pixels \(bitmap.pixelsHigh))")
            Checks.check(first.titleState.wasTruncated && first.titleState.drawnText.hasSuffix("…") && first.titleState.drawnWidth <= first.titleState.frame.width && first.titleState.baseline == 22,"MC7 public title receipt contains the actual tail ellipsis and fits its width")
        } else { Checks.check(false,"MC7 title bitmap exists") }
        for playback in [WebMediaState.Playback.playing,.paused] {
            mediaHost.mediaState.playback = playback; mediaHost.publish(); pump(0.8)
            Checks.check(animationKeys(label?.layer).isEmpty && descendants(first).allSatisfy { String(describing:type(of:$0)) != "MarqueeLabel" }, "MC7 title has no animation for \(playback)")
        }
        context.forcedMediaHover = .title(tab.id); pump(0.3)
        Checks.check(named(first,"media.titleRow")?.isHidden == false && animationKeys(label?.layer).isEmpty, "MC7 title hover cross-fade ends")
        context.forcedMediaHover = nil; controls.mouseExited(with:event(.mouseMoved,controls)); pump(1.5)
        Checks.check(!controls.isExpanded && first.cardHeight == 33 && animationKeys(scene.layer).isEmpty && controls.pendingCollapseCount == 0 && store.pendingWorkItemCount == 1, "MC8 paused at rest: collapsed 33 pt, zero layer keys, zero collapse work, one store expiry")
        func cpuSeconds() -> Double { var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t); return Double(t.tv_sec)+Double(t.tv_nsec)/1_000_000_000 }
        let cpu = cpuSeconds(), wall = CACurrentMediaTime()
        RunLoop.main.run(until:Date().addingTimeInterval(2))
        let percent = 100*(cpuSeconds()-cpu)/(CACurrentMediaTime()-wall)
        Checks.check(percent <= 0.5, String(format:"MC8 paused idle CPU %.3f%% (≤0.5%%); no media timer/display link",percent))
        context.shownPeek = SidebarShownPeek(sourceNodeID:tab.id,url:URL(string:"https://peek.example.test/")!); pump(0.15)
        Checks.check(controls.alphaValue == SidebarRole.peekBottomBarOpacity,"MC10 Peek dims controls with bottom bar")
        context.shownPeek = nil; pump()
        Checks.check(controls.alphaValue == 1, "MC10 closing Peek restores opacity")
        func rgba(_ c: CGColor?) -> [CGFloat] { guard let c, let n = NSColor(cgColor:c)?.usingColorSpace(.sRGB) else { return [] }; return [n.redComponent,n.greenComponent,n.blueComponent,n.alphaComponent] }
        func same(_ c: CGColor?, _ expected: RGBA) -> Bool {
            let a=rgba(c),b=rgba(expected.cgColor); return a.count == 4 && zip(a,b).allSatisfy { abs($0-$1) <= 0.002 }
        }
        for appearance in [ContentAppearance.dark,.light] {
            context.systemAppearance = appearance; pump(0.15)
            let expected = appearance == .dark ? DefaultThemePalette.darkBackgroundExtra : DefaultThemePalette.lightBackgroundExtra
            Checks.check(same(first.contentView.layer?.backgroundColor,expected),"MC11 default \(appearance) fill")
            Checks.check(abs(SidebarRole.mediaControlGlyph.resolved(appearance).alpha-(appearance == .dark ? 0.66:0.50)) <= 0.002 && abs(SidebarRole.mediaControlGlyphDisabled.resolved(appearance).alpha-(appearance == .dark ? 0.22:0.17)) <= 0.002 && SidebarRole.miniPlayerTitle == Core.foregroundPrimary && abs(SidebarRole.buttonHover.resolved(appearance).alpha-(appearance == .dark ? 0.08:0.07)) <= 0.002,"MC11 title, enabled/disabled glyph and plate roles \(appearance)")
            space.theme = SpaceTheme(importedArcThemeJSON:Synthetic.themeJSON(base:[0xCC334D,0xFF6655],overlay:nil,noise:0,intensity:0.8,appearance:appearance == .dark ? "dark":"light")); pump(0.15)
            let palette = context.style(for:space).palette(for:appearance)
            Checks.check(palette != nil && same(first.contentView.layer?.backgroundColor,palette!.backgroundExtra.withAlpha(1)),"MC11 red \(appearance) parsed backgroundExtra")
            space.theme = SpaceTheme(); pump()
        }
        context.systemAppearance = .dark; pump()
        for width in [CGFloat(164),228,500] {
            window.sidebarWidth = width; pump(0.1)
            let slots: [CGFloat] = width == 164 ? [10,36,62,88,114] : (width == 228 ? [10,52,94,136,178] : [10,120,230,340,450])
            Checks.check(["favicon","previous","play","next","volume"].enumerated().allSatisfy { k,id in first.control(named:id)?.view.frame.minX == slots[k] },"MC3 all five slots at W=\(width)")
            for expanded in [false,true] {
                if expanded { controls.mouseEntered(with:event(.mouseMoved,controls)) } else { controls.mouseExited(with:event(.mouseMoved,controls)) }; pump(0.8)
                let layer=first.contentView.layer, shadow=first.shadowLayer
                let path=CGPath(roundedRect:first.bounds,cornerWidth:10,cornerHeight:10,transform:nil)
                Checks.check(layer?.cornerRadius == 10 && layer?.cornerCurve == .continuous && layer?.masksToBounds == true && abs(shadow.shadowOpacity-0.21)<0.001 && shadow.shadowRadius == 4 && shadow.shadowOffset == .zero && rgba(shadow.shadowColor) == [0,0,0,1] && shadow.shadowPath == path,"MC12 corner/shadow follow frame at W=\(width), expanded=\(expanded)")
            }
        }
        window.sidebarWidth = 228; pump(0.8)
        controls.mouseExited(with:event(.mouseMoved,controls)); pump(0.8)
        SidebarDiagnostics.mediaReduceMotionOverride = nil
        Motion.reduceMotionOverride = true
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.005)
        func animations(_ l:CALayer?) -> [CAAnimation] { guard let l else {return []}; return (l.animationKeys() ?? []).compactMap {l.animation(forKey:$0)} + (l.sublayers ?? []).flatMap(animations) }
        let reduced = animations(controls.layer)+animations(pager()?.layer)
        Checks.check(Motion.reducesMotion && SidebarDiagnostics.mediaReducesMotion && animations(pager()?.layer).isEmpty && reduced.count == 1 && (reduced.first as? CATransition)?.type == .fade && abs((reduced.first?.duration ?? 0)-0.1)<0.001,
                     "MC15 shared Reduce Motion setting keeps one 0.1s media cross-fade and no pager or child movement")
        pump(0.016)
        Checks.check((pager()?.layer?.presentation()?.opacity ?? 0) >= 0.99 && (controls.layer?.presentation()?.opacity ?? 0) >= 0.99,
                     "MC15 Reduce Motion keeps pager and container fully opaque at +16ms")
        pump(0.8); Checks.check(animationKeys(scene.layer).isEmpty,"MC15 Reduce Motion leaves no keys")
        Motion.reduceMotionOverride = nil
        SidebarDiagnostics.mediaReduceMotionOverride = false
        if let b=first.control(named:"pip")?.view {click(b,"PiP")}
        Checks.check(mediaHost.calls.contains(.enterPiP) && controls.cards.isEmpty,"MC5 PiP reaches host and hides card")
        mediaHost.exitPictureInPicture(pausing:false); mediaHost.perform(.play); pump(0.8)
        for target in ["favicon","title","body"] {
            controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.8)
            if let c=card() {
                if target == "favicon", let b=c.control(named:"favicon")?.view {click(b,target)}
                else if target == "title", let b=named(c,"media.titleRow") {click(b,target,fraction:0.3)}
                else {click(c,target,fraction:0.02)}
            }
            Checks.check(delegate.intents.last == .backToTab(tab.id) && controls.cards.isEmpty,"MC5 \(target) returns to tab")
            context.displayedTabIDs=[]; pump(0.8)
        }
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.8)
        if let b=card()?.control(named:"close")?.view {click(b,"Close")}; pump(0.5)
        Checks.check(delegate.intents.last == .close(tab.id) && mediaHost.calls.last == .action(.pause) && controls.cards.isEmpty && controls.requiredHeight == 0,"MC5 Close pauses and removes last card")
        mediaHost.perform(.play); pump(0.8)
        let old=card(); store.remove(tabID:tab.id); mediaHost.publish(); pump(0.01)
        if let old,let replacement=card(),let button=replacement.control(named:"play")?.view {
            controls.addSubview(old,positioned:.above,relativeTo:replacement)
            Checks.check(old.isRetiring && old.layer?.animation(forKey:"media.disappear") != nil && old.hitTest(CGPoint(x:old.frame.midX,y:old.frame.midY)) == nil,"MC retiring card fades but cannot take hits")
            let before=mediaHost.calls.count;click(button,"replacement during fade")
            Checks.check(mediaHost.calls.count == before+1,"MC replacement receives exactly one action")
        } else {Checks.check(false,"MC replacement exists")}
        pump(0.8)
        Checks.check(card() !== old && controls.subviews.compactMap {$0 as? MiniPlayerCardView}.count == 1,"MC replacement removes retired view")
        controls.mouseEntered(with:event(.mouseMoved,controls)); pump(0.8)
        mediaHost.mediaState.volume = 1; mediaHost.publish(); pump()
        if let volume=card()?.control(named:"volume")?.view { click(volume,"drawer before tab close") }
        Checks.check(context.mediaDrawers.contains(tab.id),"MC13 drawer is open before tab close")
        let undo=UndoManager(); undo.groupsByEvent=false; model.undoManager=undo
        model.closeTab(id:tab.id); store.remove(tabID:tab.id); pump(0.3)
        Checks.check(!context.mediaDrawers.contains(tab.id),"MC5 tab close prunes its drawer ID")
        undo.undo(); mediaHost.publish(); pump(0.8)
        Checks.check(card()?.cardHeight == 33 && card()?.drawerIsOpen == false && !context.mediaDrawers.contains(tab.id),"MC5 undo returns a 33 pt card without a stale drawer")
        model.undoManager=nil
        store.remove(tabID:tab.id);pump(0.8)
        let recording=model.newTab(in:space.id,url:URL(string:"https://meeting.example.test/")!,title:"Meeting");recording.live.isCapturing=true
        let rh=delegate.add(tab:recording,state:WebMediaState(isControllable:true,actions:[.toggleMicrophone,.toggleCamera],microphoneMuted:false,cameraOn:true));pump(0.8)
        if let c=controls.cards.first {
            Checks.check(["play","previous","next","volume"].allSatisfy {c.control(named:$0)?.view.isHidden == true} && c.control(named:"microphone")?.view.frame == CGRect(x:52,y:5,width:24,height:24) && c.control(named:"camera")?.view.frame == CGRect(x:94,y:5,width:24,height:24),"MC14 recording uses slots 0/1/2 only")
            for id in ["microphone","camera"] {if let b=c.control(named:id)?.view {click(b,id)}}
            Checks.check(rh.calls == [.action(.toggleMicrophone),.action(.toggleCamera)] && c.control(named:"microphone")?.glyph == .mediaMicrophoneMuted && c.control(named:"camera")?.glyph == .mediaCameraOff,"MC14 recording actions update glyphs")
        } else {Checks.check(false,"MC14 recording card exists")}
    }
}
