import AppKit
import OpenDesign
import OpenMedia
import OpenWeb

/// PP-1/8: the engine's Document PiP child view plus Open's 28 pt draggable header.
@MainActor public final class DocumentPiPWindowController: NSWindowController, NSWindowDelegate {
    public let contentView: NSView
    public let topBar: NSView
    public let menuBuilder: PiPMenuBuilder
    private let host: any WebPictureInPictureHost
    private var closing = false
    public var onClosed: (() -> Void)?
    public var presentWindows = true
    public init?(host: any WebPictureInPictureHost, sourceURL: URL?, requestedSize: CGSize, settings: MediaSettings,
                 privateSession: MediaSettings.PrivateHosts? = nil, topBarTitle: String? = nil, screenVisibleFrame: CGRect? = nil) {
        let screen = screenVisibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard screen.width > 0, screen.height > 0, requestedSize.width.isFinite, requestedSize.height.isFinite else { return nil }
        self.host = host
        menuBuilder = PiPMenuBuilder(host: host, sourceURL: sourceURL, settings: settings, privateSession: privateSession)
        let maximum = CGSize(width: screen.width * PiPMetrics.maximumScreenFraction, height: screen.height * PiPMetrics.maximumScreenFraction)
        let size = CGSize(width: min(maximum.width, max(PiPMetrics.minimum.width, requestedSize.width)),
                          height: min(maximum.height, max(PiPMetrics.minimum.height, requestedSize.height + PiPMetrics.documentTopBar)))
        let frame = CGRect(x: screen.maxX - size.width - PiPMetrics.screenInset, y: screen.minY + PiPMetrics.screenInset, width: size.width, height: size.height)
        let panel = PiPPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        let header = DocumentPiPTopBar(host: host, title: topBarTitle ?? sourceURL?.host ?? host.sourceTitle, menu: menuBuilder)
        topBar = header
        let content = DocumentPiPContentView(child: host.videoView, header: header, size: size); contentView = content
        super.init(window: panel)
        panel.title = "Picture in Picture"; panel.contentView = content; panel.delegate = self
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.hasShadow = true; panel.isMovableByWindowBackground = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.animationBehavior = .none
        panel.level = settings.keepOnTop ? .floating : .normal
        panel.contentMinSize = CGSize(width: min(PiPMetrics.minimum.width, maximum.width), height: min(PiPMetrics.minimum.height, maximum.height)); panel.contentMaxSize = maximum
        menuBuilder.onTopChanged = { [weak panel] on in panel?.level = on ? .floating : .normal }
        header.close = { [weak self] in self?.close() }; panel.closeRequested = { [weak self] in self?.close() }
        host.windowFrame = frame; host.windowVisible = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        window?.delegate = nil
        if !closing { host.closePausingVideo(false) }
        window?.orderOut(nil); window?.close()
    }
    public override func showWindow(_ sender: Any?) { guard presentWindows else { return }; window?.orderFront(nil); host.windowVisible = true }
    public override func close() {
        guard !closing else { return }; closing = true
        host.closePausingVideo(false); host.windowVisible = false
        window?.orderOut(nil); window?.close(); onClosed?()
    }
    public func makeMenu() -> NSMenu { menuBuilder.build(document: true) }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    public func windowWillClose(_ notification: Notification) { if !closing { closing = true; host.closePausingVideo(false); host.windowVisible = false; onClosed?() } }
    public func windowDidResize(_ notification: Notification) { if let window { host.windowFrame = window.frame } }
    public func windowDidMove(_ notification: Notification) { if let window { host.windowFrame = window.frame } }
}

@MainActor private final class DocumentPiPContentView: NSView {
    private let child: NSView, header: DocumentPiPTopBar
    init(child: NSView, header: DocumentPiPTopBar, size: CGSize) {
        self.child = child; self.header = header; super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.cornerRadius = PiPMetrics.cornerRadius; layer?.masksToBounds = true
        addSubview(child); addSubview(header)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PiPMetrics.documentTopBar)
        child.frame = CGRect(x: 0, y: PiPMetrics.documentTopBar, width: bounds.width, height: max(0, bounds.height - PiPMetrics.documentTopBar))
    }
}

@MainActor private final class DocumentPiPTopBar: NSView {
    private let favicon = DocumentPiPFavicon(), title = DocumentPiPLabel(labelWithString: "")
    private let settings = PiPControlButton(glyph: .pipSettings, title: "Settings")
    private let closeButton = PiPControlButton(glyph: .pipClose, title: "Close")
    private let menuBuilder: PiPMenuBuilder
    private let hairline = CALayer()
    var close: (() -> Void)?
    init(host: any WebPictureInPictureHost, title text: String, menu: PiPMenuBuilder) {
        menuBuilder = menu; super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = PiPRole.documentTopBar.cgColor(.dark); layer?.addSublayer(hairline)
        hairline.backgroundColor = PiPRole.documentHairline.cgColor(.dark)
        favicon.image = host.favicon; favicon.imageScaling = .scaleProportionallyDown
        title.stringValue = text; title.font = Typography.documentPiPHost.font; title.textColor = PiPRole.secondaryText.nsColor
        title.lineBreakMode = .byTruncatingTail
        for view in [favicon, title, settings, closeButton] as [NSView] { addSubview(view) }
        settings.showsPlate = false; settings.growsOnHover = false; closeButton.showsPlate = false; closeButton.growsOnHover = false
        settings.setAccessibilityIdentifier("pip.document.settings"); closeButton.setAccessibilityIdentifier("pip.document.close")
        settings.action = { [weak self] in guard let self else { return }; self.menuBuilder.build(document: true).popUp(positioning: nil, at: CGPoint(x: 0, y: self.settings.bounds.maxY), in: self.settings) }
        closeButton.action = { [weak self] in self?.close?() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func layout() {
        super.layout()
        let m = PiPMetrics.self, y = (m.documentTopBar - m.documentButton) / 2
        favicon.frame = CGRect(x: m.documentLeading, y: (m.documentTopBar - m.documentFavicon) / 2, width: m.documentFavicon, height: m.documentFavicon)
        closeButton.frame = CGRect(x: bounds.width - m.documentTrailing - m.documentButton, y: y, width: m.documentButton, height: m.documentButton)
        settings.frame = CGRect(x: closeButton.frame.minX - m.documentButtonGap - m.documentButton, y: y, width: m.documentButton, height: m.documentButton)
        let x = favicon.frame.maxX + m.documentTitleGap, height = title.intrinsicContentSize.height
        title.frame = CGRect(x: x, y: (m.documentTopBar - height) / 2, width: max(0, settings.frame.minX - m.documentButtonGap - x), height: height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        hairline.frame = CGRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel)
        CATransaction.commit()
    }
}
@MainActor private final class DocumentPiPFavicon: NSImageView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
@MainActor private final class DocumentPiPLabel: NSTextField { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
