import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Real composed sidebar, synthetic native events; no desktop input (§8.2).
@MainActor enum MediaChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func animatedLayers(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animatedLayers($1) }
    }
    static func runRowIndicators() {
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let tab = model.spaces.first?.today.compactMap(\.tab).first else { return }
        let context = SidebarContext(model: model, windowID: window.id), delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close(); SidebarDiagnostics.mediaReduceMotionOverride = nil }
        func pump(_ time: TimeInterval = 0.03) { OffscreenRenderer.settle(scene, runLoop: time) }
        func speaker() -> NSView? { descendants(scene.sidebar).first { !$0.isHidden && ["Mute tab", "Unmute tab"].contains($0.accessibilityLabel() ?? "") } }
        pump()
        Checks.check(speaker() == nil, "RI1 silent unmuted row builds no speaker")
        tab.live.isAudible = true; model.setMuted(tabID: tab.id, muted: true); pump()
        guard let button = speaker() else { Checks.check(false, "RI1 speaker exists"); return }
        let symbol = descendants(button).compactMap { $0 as? NSImageView }.first
        Checks.check(button.frame.size == CGSize(width: 20, height: 20) && button.frame.minY == 10 && symbol?.image === Glyph.audioMuted.image && button.accessibilityLabel() == "Unmute tab", "RI1 muted audible speaker frame and symbol")
        let selection = window.selectedNodeBySpace
        let point = button.convert(CGPoint(x: 10, y: 10), to: nil), time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        button.mouseDown(with: down); button.mouseUp(with: up); pump()
        Checks.check(delegate.log.last == .toggleMute(tabID: tab.id) && window.selectedNodeBySpace == selection && !tab.isMuted, "RI2 speaker click sends toggleMute without selecting")
        tab.live.isCapturing = true; pump()
        let recording = descendants(scene.sidebar).first { $0.accessibilityLabel() == "This tab is using your camera or microphone" }
        Checks.check(recording?.frame.size == CGSize(width: 20, height: 20) && recording?.frame.maxX == button.frame.minX && recording?.accessibilityHelp() == "This tab is using your camera or microphone", "RI3 recording slot before speaker; exact tooltip")
        SidebarDiagnostics.mediaReduceMotionOverride = false
        let before = SidebarDiagnostics.rowMediaSymbolTransitions
        model.setMuted(tabID: tab.id, muted: true); pump()
        let after = SidebarDiagnostics.rowMediaSymbolTransitions
        pump(1)
        Checks.check(after == before + 1 && SidebarDiagnostics.rowMediaSymbolTransitions == after && animatedLayers(symbol?.layer) == 0, "RI4 exactly one mute transition and no remaining animation")
        SidebarDiagnostics.mediaReduceMotionOverride = true
        model.setMuted(tabID: tab.id, muted: false); pump()
        Checks.check(SidebarDiagnostics.rowMediaSymbolTransitions == after && descendants(button).allSatisfy { !($0 is NSImageView) } && animatedLayers(button.layer) == 0, "RI4 Reduce Motion uses a static glyph with no symbol layer or animation")
    }
}
