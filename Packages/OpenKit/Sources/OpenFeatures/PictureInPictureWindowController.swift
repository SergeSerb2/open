import AppKit
import OpenDesign
import OpenMedia
import OpenWeb

/// Phase-2 video PiP. The App supplies the engine host and owns the session (PP-9/10).
@MainActor public final class PictureInPictureWindowController: NSWindowController, NSWindowDelegate {
    private static var lastFrame: CGRect?
    public let contentView: NSView
    public let overlay: PiPOverlayView
    public let menuBuilder: PiPMenuBuilder
    private let host: any WebPictureInPictureHost
    private weak var sourceWindow: NSWindow?
    private let presentationRect: CGRect?
    private var geometry: PiPWindowGeometry
    private var closing = false, animating = false
    private var preferredFrame = CGRect.zero
    public var presentWindows = true
    public var onBackToTab: (() -> Void)?
    public var onClosed: ((PiPSession.Reason) -> Void)?
    public var reduceMotionOverride: Bool?

    public init?(host: any WebPictureInPictureHost, sourceURL: URL?, settings: MediaSettings,
                 rules: PiPSiteRules, privateSession: MediaSettings.PrivateHosts? = nil,
                 sourceWindow: NSWindow? = nil, presentationSourceRect: CGRect? = nil, screenVisibleFrame: CGRect? = nil,
                 pasteboard: NSPasteboard = .general) {
        let screen = screenVisibleFrame ?? sourceWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard let geometry = PiPWindowGeometry(natural: host.naturalSize, screen: screen) else { return nil }
        self.geometry = geometry; self.host = host; self.sourceWindow = sourceWindow; presentationRect = presentationSourceRect
        menuBuilder = PiPMenuBuilder(host: host, sourceURL: sourceURL, settings: settings, privateSession: privateSession, pasteboard: pasteboard)
        overlay = PiPOverlayView(host: host, menuBuilder: menuBuilder, configuration: sourceURL.flatMap { rules.configuration(for: $0) })
        let frame = geometry.initialFrame(reusing: Self.lastFrame)
        let panel = PiPPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        let content = PiPVideoContentView(video: host.videoView, overlay: overlay, frame: CGRect(origin: .zero, size: frame.size))
        contentView = content
        super.init(window: panel)
        preferredFrame = frame
        panel.title = "Picture in Picture"; panel.contentView = content; panel.delegate = self
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.animationBehavior = .none; panel.acceptsMouseMovedEvents = true
        panel.level = settings.keepOnTop ? .floating : .normal
        applyLimits()
        menuBuilder.onTopChanged = { [weak panel] on in panel?.level = on ? .floating : .normal }
        overlay.onClose = { [weak self] in self?.dismiss(reason: .userClosed) }
        overlay.onMinimize = { [weak self] in self?.dismiss(reason: .minimized) }
        overlay.onBackToTab = { [weak self] in self?.dismiss(reason: .backToTab) }
        panel.playPause = { [weak self] in self?.host.togglePlayPause(); self?.overlay.refresh() }
        panel.closeRequested = { [weak self] in self?.dismiss(reason: .userClosed) }
        host.windowFrame = frame; host.windowVisible = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        window?.delegate = nil
        if !closing { host.closePausingVideo(false) }
        window?.orderOut(nil); window?.close()
    }
    private var reducesMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public override func showWindow(_ sender: Any?) { present() }
    public func present() {
        guard !closing, presentWindows, let window else { return }
        let target = window.frame
        let source = (presentationRect ?? sourceWindow.map { $0.convertToScreen(host.sourceBounds) }).flatMap {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 ? $0 : nil
        }
        animating = true
        window.alphaValue = 0
        if let source, source.width > 0, source.height > 0, !reducesMotion { window.setFrame(source, display: false) }
        window.orderFront(nil); host.windowVisible = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = source != nil && !self.reducesMotion ? Motion.pipPresentAlpha : Motion.pipFade
            window.animator().alphaValue = 1
            if let source, source.width > 0, source.height > 0, !self.reducesMotion {
                let spring = Motion.pipPresent.animation(keyPath: "frame")
                window.animations[NSAnimatablePropertyKey("frame")] = spring
                context.duration = spring.duration; window.animator().setFrame(target, display: true)
            }
        }, completionHandler: { [weak self] in MainActor.assumeIsolated {
            guard let self, !self.closing else { return }
            self.animating = false; self.host.windowFrame = target; Self.lastFrame = self.preferredFrame
        } })
        overlay.showControls()
    }
    public func refresh() {
        if let updated = PiPWindowGeometry(natural: host.naturalSize, screen: geometry.screen), updated.natural != geometry.natural {
            geometry = updated; applyLimits(); resize(to: window?.frame.size ?? geometry.minimum)
        }
        overlay.refresh(); host.windowVisible = window?.isVisible == true
    }
    private func applyLimits() {
        window?.contentAspectRatio = geometry.natural
        window?.contentMinSize = geometry.minimum; window?.contentMaxSize = geometry.maximum
    }
    public func resize(to proposed: CGSize) {
        guard let window else { return }
        let size = geometry.constrained(proposed)
        window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false)
        contentView.layoutSubtreeIfNeeded()
        if host.windowFrame != window.frame { host.windowFrame = window.frame }
        if !animating && !closing { preferredFrame = window.frame; Self.lastFrame = window.frame }
    }
    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize { geometry.constrained(frameSize) }
    public func windowDidResize(_ notification: Notification) { if let window { host.windowFrame = window.frame; if !animating && !closing { preferredFrame = window.frame; Self.lastFrame = window.frame } }; overlay.needsLayout = true }
    public func windowDidMove(_ notification: Notification) { if let window { host.windowFrame = window.frame; if !animating && !closing { preferredFrame = window.frame; Self.lastFrame = window.frame } } }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(reason: .userClosed); return false }
    public func windowWillClose(_ notification: Notification) {
        guard !closing else { return }; closing = true
        host.closePausingVideo(false); host.windowVisible = false; onClosed?(.sourceGone)
    }
    public override func close() { dismiss(reason: .userClosed) }
    public func dismiss(reason: PiPSession.Reason) {
        guard !closing, let window else { return }; closing = true
        Self.lastFrame = preferredFrame
        if reason == .backToTab { onBackToTab?(); sourceWindow?.contentView?.layoutSubtreeIfNeeded() }
        let finish: @MainActor () -> Void = { [weak self, weak window] in
            guard let self else { return }
            self.host.closePausingVideo(reason == .userClosed); self.host.windowVisible = false
            window?.orderOut(nil); window?.close(); self.onClosed?(reason)
        }
        guard presentWindows && window.isVisible else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reason == .backToTab && !self.reducesMotion ? Motion.pipBackToTab : Motion.pipFade
            window.animations[NSAnimatablePropertyKey("frame")] = CABasicAnimation(keyPath: "frame")
            if reason == .backToTab, !self.reducesMotion,
               let target = self.sourceWindow.map({ $0.convertToScreen(self.host.sourceBounds) }) ?? self.presentationRect,
               target.width > 0, target.height > 0 { window.animator().setFrame(target, display: true) }
            else if reason == .minimized && !self.reducesMotion {
                window.animator().setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: window.frame.width * PiPMetrics.minimizedScale, height: window.frame.height * PiPMetrics.minimizedScale)), display: true)
            }
            window.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }
}

/// Real NSPanel keys are scoped to this key window; no application shortcuts (PP-21).
@MainActor final class PiPPanel: NSPanel {
    var playPause: (() -> Void)?, closeRequested: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isKeyWindow && event.charactersIgnoringModifiers == " " && modifiers.isEmpty, let playPause { playPause(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command] && event.charactersIgnoringModifiers?.lowercased() == "w" { closeRequested?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class PiPVideoContentView: NSView {
    private let video: NSView, overlay: PiPOverlayView
    init(video: NSView, overlay: PiPOverlayView, frame: CGRect) {
        self.video = video; self.overlay = overlay; super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = PiPMetrics.cornerRadius; layer?.masksToBounds = true
        addSubview(video); addSubview(overlay)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); video.frame = bounds; overlay.frame = bounds }
}

/// Aspect-preserving limits, including the lead's portrait maximum-priority rule.
private struct PiPWindowGeometry {
    let natural: CGSize, screen: CGRect, minimum: CGSize, maximum: CGSize
    private let ratio: CGFloat
    init?(natural: CGSize, screen: CGRect) {
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0, screen.width > 0, screen.height > 0 else { return nil }
        self.natural = natural; self.screen = screen; ratio = natural.width / natural.height
        let maxWidth = min(screen.width * PiPMetrics.maximumScreenFraction, screen.height * PiPMetrics.maximumScreenFraction * ratio)
        maximum = CGSize(width: maxWidth, height: maxWidth / ratio)
        let standard = max(PiPMetrics.minimum.width, PiPMetrics.minimum.height * ratio)
        let relaxed = PiPMetrics.minimum.height * max(1, ratio)
        let minWidth = min(maxWidth, standard <= maxWidth ? standard : relaxed)
        minimum = CGSize(width: minWidth, height: minWidth / ratio)
    }
    func constrained(_ size: CGSize) -> CGSize {
        let width = min(maximum.width, max(minimum.width, size.width.isFinite ? size.width : minimum.width))
        return CGSize(width: width, height: width / ratio)
    }
    func initialFrame(reusing old: CGRect?) -> CGRect {
        let fit = min(screen.width * PiPMetrics.initialScreenFraction, screen.height * PiPMetrics.initialScreenFraction * ratio)
        let reusedWidth = old.map { max($0.width, $0.height) * min(1, ratio) }
        let size = constrained(CGSize(width: reusedWidth ?? min(maximum.width, max(minimum.width, fit)), height: 0))
        let inset = PiPMetrics.screenInset
        let origin = old.map { CGPoint(x: min(screen.maxX - size.width - inset, max(screen.minX + inset, $0.minX)), y: min(screen.maxY - size.height - inset, max(screen.minY + inset, $0.minY))) }
            ?? CGPoint(x: screen.maxX - size.width - inset, y: screen.minY + inset)
        return CGRect(origin: origin, size: size)
    }
}
