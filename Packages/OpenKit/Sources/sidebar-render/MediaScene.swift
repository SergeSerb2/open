import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenMedia
import OpenWeb

/// Real row and mini-player scenes driven by the runtime media store.
@MainActor enum MediaScene {
    static func delegate(context: SidebarContext) -> MediaHarnessDelegate {
        let delegate = MediaHarnessDelegate(context: context)
        for source in context.media?.sources.values.map({ $0 }) ?? [] {
            guard let id = source.tabID, let tab = context.model.tab(id: id) else { continue }
            let state = WebMediaState(playback: source.playback, isControllable: source.isControllable,
                hasVideo: source.hasVideo, largestVideoArea: source.largestVideoArea, actions: source.actions,
                microphoneMuted: source.microphoneOn.map { !$0 }, cameraOn: source.cameraOn, volume: source.volume)
            delegate.hosts[id] = FakeSidebarMediaHost(tab: tab, context: context, state: state)
        }
        return delegate
    }
    static func apply(_ args: [String], context: SidebarContext) throws {
        if args.contains("--media-increase-contrast") { SidebarDiagnostics.mediaIncreaseContrastOverride = true }
        if args.contains("--reduce-motion") { SidebarDiagnostics.mediaReduceMotionOverride = true }
        if let theme = RenderCLI.value(args, "--media-theme"), let space = context.focusedSpace {
            switch theme {
            case "default": space.theme = SpaceTheme()
            case "red":
                space.theme = SpaceTheme(importedArcThemeJSON: Synthetic.themeJSON(base: [0xCC334D, 0xFF6655], overlay: nil, noise: 0,
                    intensity: 0.8, appearance: context.systemAppearance == .dark ? "dark" : "light"))
            default: throw CLIError(description: "invalid media theme: \(theme)")
            }
        }
        guard let spec = RenderCLI.value(args, "--media") else { return }
        // LayerCloner does not preserve the native RBSymbolLayer tint. Static SF glyphs
        // use the same left anchor and draw the correct role color (lead D2 option).
        SidebarDiagnostics.mediaReduceMotionOverride = true
        final class SceneClock { var now = Date() }
        let clock = SceneClock(), present = Date()
        let store = MediaSourceStore(clock: { clock.now }); context.media = store
        var finalStates: [(Tab, WebMediaState)] = []
        for item in spec.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let id = RenderCLI.resolve(pair[0], context: context), let tab = context.model.tab(id: id) else {
                throw CLIError(description: "invalid row media spec: \(item)")
            }
            let flags = Set(pair[1].split(separator: ":").map(String.init))
            let valid: Set<String> = ["audible", "playing", "paused", "silent", "muted", "recording", "video", "tracks", "long"]
            guard flags.filter({ !$0.hasPrefix("paused-min=") }).allSatisfy({ valid.contains($0) }) else { throw CLIError(description: "invalid row media state: \(pair[1])") }
            tab.live.hasWebContent = true
            tab.live.isAudible = flags.contains("audible") || flags.contains("playing")
            context.model.setMuted(tabID: tab.id, muted: flags.contains("muted"))
            tab.live.isCapturing = flags.contains("recording")
            if flags.contains("long") { tab.title = "A long media title that stays still and truncates at the end of the mini player" }
            let pausedMinutes = flags.first(where: { $0.hasPrefix("paused-min=") }).flatMap { Double($0.dropFirst(11)) } ?? 0
            clock.now = present.addingTimeInterval(-max(0, pausedMinutes) * 60)
            let playback: WebMediaState.Playback = flags.contains("playing") || flags.contains("audible") ? .playing : (flags.contains("paused") || pausedMinutes > 0 ? .paused : .none)
            var actions: WebMediaActions = [.play, .pause]
            if flags.contains("tracks") { actions.formUnion([.previousTrack, .nextTrack]) }
            if flags.contains("recording") { actions.formUnion([.toggleMicrophone, .toggleCamera]) }
            let state = WebMediaState(playback: playback, isControllable: true, hasVideo: flags.contains("video"),
                largestVideoArea: flags.contains("video") ? 640 * 360 : 0, actions: actions,
                microphoneMuted: flags.contains("recording") ? false : nil, cameraOn: flags.contains("recording") ? true : nil, volume: 1)
            store.update(tabID: id, windowID: context.windowID, state: state, isMuted: tab.isMuted, isCapturing: tab.live.isCapturing)
            if let path = RenderCLI.value(args, "--media-title-from-ax") { tab.title = try titleFromAX(path) }
            if let path = RenderCLI.value(args, "--row-title-from-ax") { tab.title = try RowMediaCompare.arcRow(axPath: path).title }
            finalStates.append((tab, state))
            if let depth = RenderCLI.value(args, "--media-depth").flatMap(Int.init), depth > 0,
               let space = context.focusedSpace {
                var node = tab.id
                for level in 0..<min(depth, 20) {
                    guard let folder = context.model.createFolder(in: .spacePinned(space.id), title: "Media folder \(level + 1)", withNodes: [node]) else { break }
                    node = folder.id
                }
            }
        }
        // A later duration event uses the current fixture clock, like metadata arriving
        // after the initial session event. Paused-min fixtures retain their original pause time.
        clock.now = present
        for (tab, var state) in finalStates {
            state.duration = 180
            store.update(tabID: tab.id, windowID: context.windowID, state: state, isMuted: tab.isMuted, isCapturing: tab.live.isCapturing)
        }
        let sources = store.visibleSources(windowID: context.windowID, displayed: context.displayedTabIDs)
        if let hover = RenderCLI.value(args, "--media-hover") {
            if hover == "expanded" { context.forcedMediaHover = .expanded }
            else {
                let parts = hover.split(separator: ":")
                guard parts.count == 2, let index = Int(parts[1]), sources.indices.contains(index), let id = sources[index].tabID,
                      parts[0] == "title" else { throw CLIError(description: "invalid media hover: \(hover)") }
                context.forcedMediaHover = .title(id)
            }
        }
        if let index = RenderCLI.value(args, "--media-drawer").flatMap(Int.init) {
            guard sources.indices.contains(index), let id = sources[index].tabID else { throw CLIError(description: "invalid media drawer") }
            context.mediaDrawers.insert(id)
        }

    }
    static func captureInteraction(_ scene: RenderScene, args: [String], scale: CGFloat) throws -> CGImage {
        let host = OffscreenRenderer.host(scene, scale: scale)
        host.orderBack(nil)
        defer { TooltipController.shared.visibleTooltipView?.removeFromSuperview(); host.contentView = nil; host.close() }
        OffscreenRenderer.settle(scene, runLoop: 0.03)
        let parts = (RenderCLI.value(args, "--media-button-hover") ?? "play").split(separator: ":").map(String.init)
        let cards = scene.sidebar.mediaControls.cards, index = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard parts.count <= 2, cards.indices.contains(index), let button = cards[index].control(named: parts[0])?.view else { throw CLIError(description: "unknown media button") }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        button.mouseEntered(with: event(.mouseMoved))
        if args.contains("--media-button-pressed") { button.mouseDown(with: event(.leftMouseDown)) }
        OffscreenRenderer.settle(scene, runLoop: args.contains("--media-tooltip") ? 0.22 : 0.03)
        if args.contains("--media-tooltip") {
            guard let tooltip = TooltipController.shared.visibleTooltipView, let tipWindow = tooltip.window else { throw CLIError(description: "media tooltip did not appear") }
            let screen = tipWindow.convertToScreen(tooltip.convert(tooltip.bounds, to: nil))
            let frame = scene.convert(host.convertFromScreen(screen), from: nil)
            tooltip.removeFromSuperview(); scene.addSubview(tooltip); tooltip.frame = frame
        }
        OffscreenRenderer.settle(scene)
        return OffscreenRenderer().snapshot(scene, scale: scale)
    }

    /// Reads only a local capture. The title stays in memory; errors never include it.
    static func titleFromAX(_ path: String) throws -> String {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        var hosting: Any?
        func find(_ value: Any) {
            if let d = value as? [String: Any] {
                if d["subrole"] as? String == "AXHostingView", let children = d["children"] as? [[String:Any]],
                   children.contains(where: { ($0["id"] as? String)?.hasPrefix("mediaControls") == true }) { hosting = d }
                for key in d.keys.sorted() { if let value = d[key] { find(value) } }
            } else if let a = value as? [Any] { for v in a { find(v) } }
        }
        find(root)
        var title: String?
        func text(_ value: Any) {
            if let d = value as? [String: Any] {
                if d["role"] as? String == "AXStaticText", let s = (d["value"] ?? d["AXValue"]) as? String, !s.isEmpty { title = s }
                for key in d.keys.sorted() { if let value = d[key] { text(value) } }
            } else if let a = value as? [Any] { for v in a { text(v) } }
        }
        if let hosting { text(hosting) }
        guard let title else { throw CLIError(description: "mini-player AX title unavailable") }
        return title
    }

}
