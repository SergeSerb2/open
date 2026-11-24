import AppKit
import OpenDesign

/// Plain presentation state. The App maps `SyncEngine.snapshot.status` to it and owns the actions
/// (open Settings ▸ Account & Sync) and the dismissal policy.
public enum SyncBannerState: Equatable, Sendable {
    case error(String)
    case needsReauth(String)
    case awaitingInitialChoice
}

/// The sidebar's Open Sync banner. Same slot, geometry, Space-theme colours, and hover dismiss
/// button as `UpdateBannerView`.
@MainActor
public final class SyncBannerView: NSView {
    public var state: SyncBannerState { didSet { if state != oldValue { refresh() } } }
    public let actionButton = NSButton(title: "", target: nil, action: nil)
    public let dismissButton = NSButton(title: "", target: nil, action: nil)
    private let symbol = NSImageView()
    public let titleLabel = NSTextField(labelWithString: "")
    public let subtitleLabel = NSTextField(labelWithString: "")
    public var onAction: (() -> Void)?
    public var onDismiss: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let context: SidebarContext
    private var observation: ObservationLoop?
    private var symbolName = ""
    public init(state: SyncBannerState, context: SidebarContext) {
        self.state = state; self.context = context
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = BannerMetrics.radius; layer?.cornerCurve = .continuous
        titleLabel.font = .systemFont(ofSize: BannerMetrics.titleSize, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: BannerMetrics.messageSize)
        for label in [titleLabel, subtitleLabel] { label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 2 }
        symbol.imageScaling = .scaleProportionallyDown
        symbol.setAccessibilityElement(false)
        actionButton.isBordered = false; actionButton.title = ""
        actionButton.target = self; actionButton.action = #selector(activate)
        actionButton.setAccessibilityIdentifier("sidebar-sync-banner")
        dismissButton.isBordered = false; dismissButton.imagePosition = .imageOnly
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        dismissButton.setAccessibilityLabel("Dismiss sync banner")
        dismissButton.target = self; dismissButton.action = #selector(dismissBanner)
        dismissButton.isHidden = true
        for view in [symbol, titleLabel, subtitleLabel, actionButton, dismissButton] as [NSView] { addSubview(view) }
        observation = ObservationLoop(read: { [weak self] in
            _ = self?.context.focusedSpace?.theme; _ = self?.context.systemAppearance
        }) { [weak self] in self?.refresh() }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observation?.cancel() }
    public override var isFlipped: Bool { true }
    private func titleHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - BannerMetrics.padding - 21 - 16)
        let measured = titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 18
        return measured > 18 ? 34 : 18
    }
    public func height(for width: CGFloat) -> CGFloat {
        // The update banner's one- and two-line geometry, based on the actual title.
        titleHeight(for: width) > 18 ? 86 : 68
    }
    /// The engine's message for an error or a sign-in request (tooltip and VoiceOver detail).
    private var detail: String? {
        switch state {
        case .error(let message), .needsReauth(let message): message.isEmpty ? nil : message
        case .awaitingInitialChoice: nil
        }
    }
    private func refresh() {
        let narrow = context.sidebarWidth < 200
        switch state {
        case .error: titleLabel.stringValue = "Sync paused"
        case .needsReauth: titleLabel.stringValue = "Sign in to sync"
        case .awaitingInitialChoice: titleLabel.stringValue = narrow ? "Finish Sync setup" : "Finish Open Sync setup"
        }
        subtitleLabel.stringValue = "Open Account & Sync"
        let name = state == .awaitingInitialChoice ? "icloud.and.arrow.down" : "exclamationmark.icloud"
        if name != symbolName {
            symbolName = name
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        let label = titleLabel.stringValue + "\n" + subtitleLabel.stringValue
        actionButton.setAccessibilityLabel(detail.map { label + "\n" + $0 } ?? label)
        toolTip = detail
        if let space = context.focusedSpace {
            let style = context.style(for: space), appearance = context.appearance(for: space)
            self.appearance = appearance.nsAppearance
            let base: RGBA
            switch style.fill { case .corners(let colors): base = colors.first ?? RGBA(hex: 0x252538)
            case .blended(let colors, _): base = colors.first ?? RGBA(hex: 0xEDEDF1) }
            let fill = style.selectedFill(appearance)
            layer?.backgroundColor = RGBA(fill.red * fill.alpha + base.red * (1-fill.alpha), fill.green * fill.alpha + base.green * (1-fill.alpha), fill.blue * fill.alpha + base.blue * (1-fill.alpha)).cgColor
            SelectionShadow.apply(to: layer!, appearance: appearance)
            titleLabel.textColor = style.titleColor(appearance).nsColor
            subtitleLabel.textColor = (appearance == .light ? RGBA.black(0.55) : RGBA.white(0.70)).nsColor
            symbol.contentTintColor = titleLabel.textColor; dismissButton.contentTintColor = titleLabel.textColor
        }
        needsLayout = true
    }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refresh() }
    public override func layout() {
        super.layout()
        let x = BannerMetrics.padding + 21
        let width = max(1, bounds.width - x - 16)
        symbol.frame = NSRect(x: BannerMetrics.padding - 1, y: 14, width: 16, height: 16)
        titleLabel.frame = NSRect(x: x, y: 12, width: width, height: titleHeight(for: bounds.width))
        subtitleLabel.frame = NSRect(x: x, y: titleLabel.frame.maxY + 4, width: width, height: 20)
        actionButton.frame = bounds
        dismissButton.frame = NSRect(x: bounds.width - 22, y: 2, width: 20, height: 20)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { dismissButton.isHidden = false }
    public override func mouseExited(with event: NSEvent) { dismissButton.isHidden = true }
    public func performDismiss() {
        let hidden = dismissButton.isHidden; dismissButton.isHidden = false
        dismissButton.performClick(nil); dismissButton.isHidden = hidden
    }
    @objc private func activate() { let action = onAction; DispatchQueue.main.async { action?() } }
    @objc private func dismissBanner() { let action = onDismiss; DispatchQueue.main.async { action?() } }
}
