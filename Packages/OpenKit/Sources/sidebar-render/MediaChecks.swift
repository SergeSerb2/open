import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

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
    static func inkLeft(_ view: NSView) -> CGFloat? {
        for child in descendants(view) { child.displayIfNeeded(); child.layer?.displayIfNeeded() }
        CATransaction.flush()
        let image = OffscreenRenderer().snapshot(view, scale: 2)
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        var left = image.width
        // Compare the speaker body at the center; the slash extends beyond it at the top.
        for y in (image.height / 2 - 2)..<(image.height / 2 + 2) { for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] > 8 { left = min(left, x) } }
        return left < image.width ? CGFloat(left) / 2 : nil
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
            button.mouseEntered(with: event(.mouseMoved, button)); pump(0.24)
            Checks.check(TooltipController.shared.visibleTooltip?.title == text && button.accessibilityHelp() == text,
                         "RI tooltip and help are exact: \(text)")
            button.mouseExited(with: event(.mouseMoved, button)); pump(0.05)
        }
        SidebarDiagnostics.mediaReduceMotionOverride = false
        pump()
        Checks.check(speaker() == nil, "RI1 silent unmuted row builds no speaker")
        Checks.check(host.frame.maxX < 0 && !host.isKeyWindow, "RI animation window stays offscreen and non-key (visible \(host.isVisible), occlusion \(host.occlusionState.rawValue))")
        tab.live.isAudible = true; pump(0.12)
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
        Checks.check(staticLeft != nil && staticMutedLeft != nil && abs((staticLeft ?? -100) - (staticMutedLeft ?? 100)) <= 0.5, "RI static glyph shares the left anchor in both states (\(String(describing: staticLeft)), \(String(describing: staticMutedLeft))); same button \(speaker() === button), hidden \(button.isHidden), size \(button.bounds.size)")
        runNarrowRecording()
        Checks.check(PiPMetrics.compactPlayGlyph == 22, "RI compact PiP play/pause token is 22 pt")
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
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: RecordingDelegate())
        let host = OffscreenRenderer.host(scene, scale: 2)
        defer { host.contentView = nil; host.close() }
        OffscreenRenderer.settle(scene, runLoop: 0.02)
        let views = descendants(scene.sidebar)
        let speaker = views.first { !$0.isHidden && $0.accessibilityLabel() == "Mute tab" }
        let dot = views.first { !$0.isHidden && $0.accessibilityLabel() == "This tab is using your camera or microphone" }
        Checks.check(speaker?.frame.width == 20 && dot == nil, "RI narrow deep hovered row hides dot before speaker")
    }
}
