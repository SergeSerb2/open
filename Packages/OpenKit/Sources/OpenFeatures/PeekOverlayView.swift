import AppKit
import OpenDesign

/// The Peek dim. It sits above the web content and below the sidebar, so it darkens
/// the window background and the page while sidebar text, glyphs, and fills stay
/// as they are (F0090 vs F0101: titles keep `#D7D9F8`, a tile's white 0.10 fill
/// composites over the darkened background). A click on it dismisses the Peek.
@MainActor
public final class PeekBackdropView: NSView {
    var onDismiss: (() -> Void)?
    public override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func mouseDown(with event: NSEvent) { onDismiss?() }
}

/// The Peek panel and its three buttons. It spans the window above the sidebar but
/// takes clicks only on the panel and buttons; the sidebar stays usable (F0101:
/// selecting another tab hides the Peek), and other clicks reach the backdrop.
@MainActor
public final class PeekOverlayView: NSView {
    public let backdrop = PeekBackdropView()
    public override var isHidden: Bool { didSet { backdrop.isHidden = isHidden } }
    public let panel = NSView()
    public let pageClip = NSView()
    public private(set) var swipeIndicator: SwipeIndicatorView?
    public private(set) var sadTabView: SadTabView?
    public var style: SpaceThemeStyle = .defaultTheme(system: .light) { didSet { swipeIndicator?.style = style; sadTabView?.style = style } }
    public private(set) var buttons: [NSButton] = []
    public var contentRect = CGRect.zero { didSet { needsLayout = true } }
    /// The measured Peek base includes the window's right margin with an anchored sidebar.
    public var baseWidth: CGFloat = 0 { didSet { needsLayout = true } }
    public var onDismiss: (() -> Void)?
    public var onExpand: (() -> Void)?
    public var onSplit: (() -> Void)?
    public var scrimColor = NSColor.black.withAlphaComponent(0.55) { didSet { backdrop.layer?.backgroundColor = scrimColor.cgColor } }
    public var controlsFill = NSColor.black { didSet { buttons.forEach { ($0 as? ActionButton)?.circleFill = controlsFill } } }
    /// Event-driven counters: no display-link or per-frame observation on the shipping path.
    public private(set) var layoutCount = 0
    public private(set) var hostFrameChangeCount = 0
    public internal(set) var motionKind = ""
    public internal(set) var motionDuration: CFTimeInterval = 0
    public internal(set) var motionStartedAt: CFTimeInterval = 0
    weak var motionHostView: NSView?
    var motionSnapshotLayer: CALayer?
    var motionHostWasHidden = false
    var motionRevealPending = false
    public var hasMotionSnapshot: Bool { motionSnapshotLayer != nil }
    private weak var hostedView: NSView?
    public init() {
        super.init(frame: .zero); wantsLayer = true; backdrop.layer?.backgroundColor = scrimColor.cgColor
        backdrop.onDismiss = { [weak self] in self?.onDismiss?() }
        panel.wantsLayer = true; pageClip.wantsLayer = true; pageClip.layer?.masksToBounds = true
        pageClip.layer?.cornerRadius = PanelMetrics.cornerRadius; pageClip.layer?.backgroundColor = NSColor.black.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = PeekMetrics.shadowOpacity
        panel.layer?.shadowRadius = PeekMetrics.shadowRadius; panel.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(panel); panel.addSubview(pageClip)
        let specs = [("xmark", "Close", "confirmCloseModal"), ("arrow.up.left.and.arrow.down.right", "Enter Full Screen", "openInSpaceExpander"), ("square.split.2x1", "Open in Split View", "openInSplit")]
        for (i, spec) in specs.enumerated() {
            let button = ActionButton(symbol: spec.0, title: spec.1) { [weak self] in
                switch i { case 0: self?.onDismiss?(); case 1: self?.onExpand?(); default: self?.onSplit?() }
            }
            button.wantsLayer = true; button.circleFill = controlsFill
            button.contentTintColor = PeekMetrics.defaultGlyph.nsColor
            button.setAccessibilityIdentifier(spec.2); button.identifier = .init(spec.2)
            addSubview(button); buttons.append(button)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() {
        PeekMotionTrace.mark("overlay.layout.begin")
        defer { PeekMotionTrace.mark("overlay.layout.end") }
        super.layout(); layoutCount += 1
        let width = round(baseWidth * PeekMetrics.widthFraction)
        let frame = CGRect(x: contentRect.minX + (baseWidth - width) / 2, y: contentRect.minY + PeekMetrics.verticalInset,
                           width: width, height: max(0, contentRect.height - 2 * PeekMetrics.verticalInset))
        if panel.frame != frame { PeekMotionTrace.mark("panel.setFrame", value: frame.width); panel.frame = frame }
        layoutPanel()
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: panel.frame.maxX + PeekMetrics.buttonGap, y: panel.frame.maxY - PeekMetrics.buttonTop - CGFloat(i) * PeekMetrics.buttonPitch - PeekMetrics.buttonDiameter,
                             width: PeekMetrics.buttonHitWidth, height: PeekMetrics.buttonDiameter)
        }
    }
    func layoutPanel() {
        if pageClip.frame != panel.bounds { PeekMotionTrace.mark("clip.setFrame", value: panel.bounds.width); pageClip.frame = panel.bounds }
        for view in pageClip.subviews where view.frame != pageClip.bounds {
            if view === hostedView { hostFrameChangeCount += 1 }
            PeekMotionTrace.mark("host.setFrame", value: pageClip.bounds.width)
            view.frame = pageClip.bounds
        }
        PeekMotionTrace.region("shadowPath") {
            panel.layer?.shadowPath = CGPath(roundedRect: panel.bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
        }
    }
    func clearHost() { endHostSnapshot(reveal: false); pageClip.subviews.forEach { $0.removeFromSuperview() }; hostedView = nil; swipeIndicator = nil; sadTabView = nil }
    func showHost(_ host: any WebContentHost, close: @escaping () -> Void) {
        PeekMotionTrace.watch(host.view)
        if isHostFrozen(host.view), host.view.superview !== pageClip {
            // Opening uses the engine's initial plate. Attaching now would
            // create Chromium and make its first commits during the motion.
            if host.view.frame != pageClip.bounds {
                PeekMotionTrace.mark("host.setFrame", value: pageClip.bounds.width)
                hostFrameChangeCount += 1; host.view.frame = pageClip.bounds
            }
            return
        }
        let wasSad = sadTabView != nil
        let hadPageFocus = (window?.firstResponder as? NSView).map { $0 === pageClip || $0.isDescendant(of: pageClip) } ?? false
        if host.liveState.isCrashed {
            host.view.isHidden = true
            if sadTabView == nil {
                clearHost(); host.view.isHidden = true
                let sad = SadTabView(style: style); sadTabView = sad; pageClip.addSubview(sad)
            }
            sadTabView?.onReload = { [weak host] in host?.reload() }; sadTabView?.onClose = close
            sadTabView?.frame = pageClip.bounds
            if hadPageFocus && !wasSad { window?.makeFirstResponder(sadTabView) }
            return
        }
        if host.view.superview !== pageClip {
            clearHost()
            hostedView = host.view
            pageClip.addSubview(host.view)
            host.view.autoresizingMask = [.width, .height]
        }
        host.view.isHidden = isHostFrozen(host.view)
        if host.view.frame != pageClip.bounds { PeekMotionTrace.mark("host.setFrame", value: pageClip.bounds.width); hostFrameChangeCount += 1; host.view.frame = pageClip.bounds }
        if !isHostFrozen(host.view) { host.view.alphaValue = host.isLoading ? 0 : 1 }
        if hadPageFocus && wasSad { host.focus() }
    }
    public func showHistorySwipe(_ event: SwipeIndicatorView.Event) {
        let indicator: SwipeIndicatorView
        if let swipeIndicator { indicator = swipeIndicator } else {
            indicator = SwipeIndicatorView(frame: pageClip.bounds); indicator.style = style
            swipeIndicator = indicator; pageClip.addSubview(indicator)
        }
        indicator.update(event)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
