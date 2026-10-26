import AppKit
import OpenDesign
import OpenFeatures
import OpenMedia
import OpenWeb

/// The only PiP stand-in: an engine-free video surface with a visible size label.
@MainActor final class FakePiPHost: WebPictureInPictureHost {
    enum Call: Equatable { case playPause, next, previous, ad, microphone, camera, hangUp, nextSlide, previousSlide, seek(Double), scrub(Double), muted(Bool), close(Bool) }
    let videoView: NSView = FakePiPVideoView()
    var naturalSize = CGSize(width: 384, height: 216)
    var sourceBounds = CGRect(x: 20, y: 30, width: 640, height: 360)
    var mediaState = WebMediaState(playback: .playing, isControllable: true, hasVideo: true,
        actions: [.play, .pause, .seekTo, .previousTrack, .nextTrack], duration: 180)
    var currentTime: Double = 60
    var playbackRate: Double { mediaState.playback == .playing ? 1 : 0 }
    var positionUpdatedAt = Date()
    var endOfMedia = false
    var sourceTitle = "Example video"
    var favicon: NSImage? { CustomIcon.letterFavicon("O", size: 16, fill: Core.brandBlue.nsColor, text: PiPRole.glyph.nsColor) }
    var mediaMuted = false
    var windowFrame = CGRect.zero
    var windowVisible = false
    var calls: [Call] = []
    func togglePlayPause() {
        calls.append(.playPause)
        if endOfMedia { currentTime = 0; endOfMedia = false }
        mediaState.playback = mediaState.playback == .playing ? .paused : .playing; positionUpdatedAt = Date()
    }
    func nextTrack() { calls.append(.next) }
    func previousTrack() { calls.append(.previous) }
    func skipAd() { calls.append(.ad) }
    func toggleMicrophone() { calls.append(.microphone); mediaState.microphoneMuted = !(mediaState.microphoneMuted ?? false) }
    func toggleCamera() { calls.append(.camera); mediaState.cameraOn = !(mediaState.cameraOn ?? true) }
    func hangUp() { calls.append(.hangUp) }
    func nextSlide() { calls.append(.nextSlide) }
    func previousSlide() { calls.append(.previousSlide) }
    func seekTo(_ time: Double) { calls.append(.seek(time)); currentTime = time; positionUpdatedAt = Date() }
    func scrubTo(_ time: Double) { calls.append(.scrub(time)); currentTime = time; positionUpdatedAt = Date() }
    func setMuted(_ value: Bool) { calls.append(.muted(value)); mediaMuted = value }
    func closePausingVideo(_ pause: Bool) { calls.append(.close(pause)); if pause { mediaState.playback = .paused }; windowVisible = false }
}

@MainActor private final class FakePiPVideoView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func layout() { super.layout(); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func updateLayer() {
        // Supply a plain bitmap layer: AppKit's large-view tiling cannot be cloned
        // reliably by the offscreen renderer. This is only the synthetic video.
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.18, blue: 0.31, alpha: 1), ending: NSColor(srgbRed: 0.19, green: 0.44, blue: 0.39, alpha: 1))?.draw(in: bounds, angle: 35)
        let text = "\(Int(bounds.width))×\(Int(bounds.height))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = context.makeImage(); layer?.contentsScale = scale
        CATransaction.commit()
    }
}

@MainActor enum PiPScene {
    static let screen = CGRect(x: -20000, y: -20000, width: 1600, height: 900)
    static func menuDump(_ menu: NSMenu) -> String {
        var lines: [String] = []
        func walk(_ menu: NSMenu, depth: Int) {
            for (i, item) in menu.items.enumerated() {
                let state = item.state == .on ? "on" : (item.state == .mixed ? "mixed" : "off")
                lines.append(String(repeating: "  ", count: depth) + "[\(i)] title=\(String(reflecting: item.title)) separator=\(item.isSeparatorItem) state=\(state) enabled=\(item.isEnabled) key=\(String(reflecting: item.keyEquivalent)) modifiers=0x\(String(item.keyEquivalentModifierMask.rawValue, radix: 16))")
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
        }
        walk(menu, depth: 0); return lines.joined(separator: "\n") + "\n"
    }
    static func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    static func run(_ args: [String]) throws {
        guard let output = RenderCLI.value(args, "--out") else { throw CLIError(description: "pip requires --out") }
        let dimensions = (RenderCLI.value(args, "--size") ?? "384x216").split(separator: "x").compactMap { Double($0) }
        guard dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 && $0 <= 8192 }) else { throw CLIError(description: "invalid PiP size") }
        let size = CGSize(width: dimensions[0], height: dimensions[1])
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        func sizeOption(_ flag: String) throws -> CGSize? {
            guard let value = RenderCLI.value(args, flag) else { return nil }
            let parts = value.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 8192 }) else { throw CLIError(description: "invalid " + flag) }
            return CGSize(width: parts[0], height: parts[1])
        }
        let visibleScreen = CGRect(origin: screen.origin, size: try sizeOption("--screen") ?? screen.size)
        let host = FakePiPHost(); host.naturalSize = try sizeOption("--natural-size") ?? size
        switch RenderCLI.value(args, "--state") ?? "playing" {
        case "playing": break
        case "paused": host.mediaState.playback = .paused
        case "ended": host.mediaState.playback = .paused; host.endOfMedia = true; host.currentTime = host.mediaState.duration ?? 0
        default: throw CLIError(description: "invalid PiP state")
        }
        if args.contains("--meeting") { host.mediaState.actions = [.toggleMicrophone, .toggleCamera, .hangUp]; host.mediaState.microphoneMuted = false; host.mediaState.cameraOn = true }
        let url: URL
        switch RenderCLI.value(args, "--site") ?? "none" {
        case "none": url = URL(string: "https://example.test/video")!
        case "twitch": url = URL(string: "https://www.twitch.tv/video")!
        case "meet": url = URL(string: "https://meet.google.com/example")!
        case "youtube": url = URL(string: "https://www.youtube.com/watch?v=example")!
        default: throw CLIError(description: "invalid PiP site")
        }
        let settings = MediaSettings(defaults: FeatureCLI.defaults()), rules = try PiPSiteRules.bundled()
        let root: NSView, menu: NSMenu, cleanup: () -> Void
        if args.contains("--document") {
            guard let controller = DocumentPiPWindowController(host: host, sourceURL: url, requestedSize: CGSize(width: size.width, height: max(0, size.height - PiPMetrics.documentTopBar)), settings: settings, topBarTitle: RenderCLI.value(args, "--top-bar-title"), screenVisibleFrame: visibleScreen) else { throw CLIError(description: "cannot create Document PiP") }
            controller.presentWindows = false; root = controller.contentView; menu = controller.makeMenu()
            if args.contains("--document-hover-options"), let button = controller.topBar.subviews.first(where: { $0.accessibilityIdentifier() == "pip.document.settings" }) {
                button.mouseEntered(with: event(.mouseMoved, in: button, at: CGPoint(x: button.bounds.midX, y: button.bounds.midY)))
            }
            if args.contains("--document-pressed-options"), let button = controller.topBar.subviews.first(where: { $0.accessibilityIdentifier() == "pip.document.settings" }) {
                button.mouseDown(with: event(.leftMouseDown, in: button, at: CGPoint(x: 10, y: 10)))
            }
            cleanup = { controller.close() }
        } else {
            guard let controller = PictureInPictureWindowController(host: host, sourceURL: url, settings: settings, rules: rules, screenVisibleFrame: visibleScreen) else { throw CLIError(description: "cannot create video PiP") }
            controller.presentWindows = false
            let firstFrame = controller.window!.frame
            if let path = RenderCLI.value(args, "--geometry-report") {
                // This read precedes every explicit resize in this fresh CLI process.
                controller.resize(to: CGSize(width: 1, height: 1))
                let minimumFrame = controller.window!.frame
                let report: [String: [Double]] = [
                    "screen": [visibleScreen.width, visibleScreen.height],
                    "natural": [host.naturalSize.width, host.naturalSize.height],
                    "firstSize": [firstFrame.width, firstFrame.height],
                    "minimumSize": [minimumFrame.width, minimumFrame.height],
                    "firstBottomLeft": [firstFrame.minX - visibleScreen.minX, firstFrame.minY - visibleScreen.minY],
                    "firstTopLeft": [firstFrame.minX - visibleScreen.minX, visibleScreen.maxY - firstFrame.maxY],
                    "insets": [visibleScreen.maxX - firstFrame.maxX, firstFrame.minY - visibleScreen.minY]
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            if args.contains("--first-open") {
                if RenderCLI.value(args, "--geometry-report") != nil { controller.window!.setFrame(firstFrame, display: false) }
            } else { controller.resize(to: size) }
            root = controller.contentView
            OffscreenRenderer.settle(root, runLoop: 0.01)
            if let multiple = RenderCLI.value(args, "--drag-precision").flatMap(Int.init) {
                guard (1...8).contains(multiple) else { throw CLIError(description: "precision must be 1...8") }
                let scrubber = controller.overlay.scrubber, point = CGPoint(x: scrubber.bounds.width / 3, y: scrubber.bounds.midY)
                scrubber.mouseDown(with: event(.leftMouseDown, in: scrubber, at: point))
                scrubber.mouseDragged(with: event(.leftMouseDragged, in: scrubber, at: CGPoint(x: point.x + scrubber.bounds.width * 0.15, y: point.y - CGFloat(multiple - 1) * PiPMetrics.precisionStep)))
            }
            if args.contains("--hover-skip-ahead"), let button = controller.overlay.control(named: "forward")?.view {
                button.mouseEntered(with: event(.mouseMoved, in: button, at: CGPoint(x: button.bounds.midX, y: button.bounds.midY)))
            }
            controller.overlay.setControlsVisible(RenderCLI.value(args, "--controls") != "hidden", animated: false)
            menu = controller.overlay.makeMenu(); cleanup = { controller.dismiss(reason: .sourceGone) }
        }
        defer { cleanup() }
        let renderer = OffscreenRenderer(), image = renderer.render(root, scale: scale)
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: output))
        if args.contains("--menu") {
            let dump = menuDump(menu), path = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("menu.txt")
            try dump.write(to: path, atomically: true, encoding: .utf8); print(dump, terminator: ""); print("menu dump: \(path.path)")
        }
        print("wrote \(output) \(image.width)x\(image.height)")
    }
}
