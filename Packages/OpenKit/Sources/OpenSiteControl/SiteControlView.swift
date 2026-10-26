import AppKit
import QuartzCore
import OpenDesign

@MainActor
public final class SiteControlView: NSView {
    public let panel = SiteControlPanelView(frame: .zero)
    public var onOutside: (() -> Void)?
    public var onAnchor: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var anchorFrame: CGRect = .zero
    public var arrowTip: CGPoint?
    public var arrowPointsUp = false
    public var panelFrame: CGRect { panel.frame }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; addSubview(panel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if anchorFrame.contains(local) { onAnchor?(); return self }
        if !panel.frame.contains(local) { onOutside?(); return nil }
        return super.hitTest(point)
    }
    public override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    // The anchor-toggle hit is deliberately consumed after dismissal.
    public override func mouseDown(with event: NSEvent) {}
    public override func draw(_ dirtyRect: NSRect) {
        guard let tip = arrowTip else { return }
        let arrow = NSBezierPath(); arrow.move(to: tip)
        if arrowPointsUp {
            arrow.line(to: CGPoint(x: tip.x - SiteControlMetrics.arrowBase / 2, y: tip.y + SiteControlMetrics.arrowHeight))
            arrow.line(to: CGPoint(x: tip.x + SiteControlMetrics.arrowBase / 2, y: tip.y + SiteControlMetrics.arrowHeight))
        } else {
            arrow.line(to: CGPoint(x: tip.x + SiteControlMetrics.arrowHeight, y: tip.y - SiteControlMetrics.arrowBase / 2))
            arrow.line(to: CGPoint(x: tip.x + SiteControlMetrics.arrowHeight, y: tip.y + SiteControlMetrics.arrowBase / 2))
        }
        arrow.close(); Core.popoverBackground.nsColor.setFill(); arrow.fill()
        CommandBarColors.hairlineDivider.nsColor.setStroke(); arrow.lineWidth = 1 / (window?.backingScaleFactor ?? 1); arrow.stroke()
    }
}

@MainActor
public final class SiteControlPanelView: NSView {
    public private(set) var snapshot: SiteControlSnapshot?
    public private(set) var controls: [SiteControlButton] = []
    public var onAction: ((String, NSRect) -> Void)?
    public var onMore: ((SiteControlButton) -> Void)?
    public var onSecurity: (() -> Void)?
    public override var isFlipped: Bool { true }
    public var preferredHeight: CGFloat { SiteControlMetrics.headerHeight + SiteControlMetrics.actionRowHeight + SiteControlMetrics.footerHeight }
    private let hostLabel = NSTextField(labelWithString: "")
    private let favicon = NSImageView()
    private let security = SiteControlButton(id: "security", label: "Connection", symbol: "lock.fill", pointSize: SiteControlMetrics.securityGlyph)
    private let more = SiteControlButton(id: "more", label: "More", symbol: "ellipsis", pointSize: SiteControlMetrics.moreGlyph)

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = SiteControlMetrics.cornerRadius
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = SiteControlMetrics.shadowOpacity
        layer?.shadowRadius = SiteControlMetrics.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -SiteControlMetrics.shadowOffsetY)
        setAccessibilityElement(true); setAccessibilityRole(.popover); setAccessibilityLabel("Site Control Center")
        hostLabel.font = Typography.siteControlTitle.font
        hostLabel.setAccessibilityRole(.staticText); favicon.setAccessibilityRole(.image)
        hostLabel.lineBreakMode = .byTruncatingTail; hostLabel.maximumNumberOfLines = 1
        addSubview(hostLabel); addSubview(favicon)
        let actions = [("share", "Share", "square.and.arrow.up"), ("copyURL", "Copy URL", "link"),
                       ("newBoost", "New Boost", "paintbrush.pointed"), ("capture", "Capture a portion of this page", "camera.viewfinder"),
                       ("captureFull", "Capture the full page", "rectangle.portrait.and.arrow.forward"),
                       ("capturePortrait", "Capture in Portrait Mode", "rectangle.portrait")]
        for (id, label, symbol) in actions {
            let button = SiteControlButton(id: "action." + id, label: label, symbol: symbol, pointSize: SiteControlMetrics.actionGlyph)
            button.invoke = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onAction?(id, button.convert(button.bounds, to: nil))
            }
            controls.append(button); addSubview(button)
        }
        security.invoke = { [weak self] in self?.onSecurity?() }
        more.invoke = { [weak self] in guard let self else { return }; self.onMore?(self.more) }
        more.setAccessibilityRole(.menuButton)
        addSubview(security); addSubview(more)
        controls += [security, more]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func apply(_ snapshot: SiteControlSnapshot) {
        self.snapshot = snapshot
        hostLabel.stringValue = snapshot.context.displayHost
        setAccessibilityHelp(snapshot.context.displayHost)
        favicon.image = snapshot.context.faviconPNG.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        for button in controls.prefix(6) {
            button.isHidden = !snapshot.context.isWebsite && !["action.share", "action.copyURL"].contains(button.controlID)
            let commands = ["action.share": "share-page", "action.copyURL": "copy-url", "action.capture": "capture-page",
                            "action.captureFull": "capture-full-page", "action.capturePortrait": "capture-portrait"]
            button.isEnabled = button.controlID == "action.newBoost" ? snapshot.canCreateBoost : snapshot.commandsEnabled[commands[button.controlID] ?? ""] ?? true
        }
        let secure = snapshot.context.security == .secure || (snapshot.context.security == .unknown && snapshot.context.url.scheme == "https")
        security.title = secure ? "Secure" : "Insecure"
        security.symbol = secure ? "lock.fill" : "lock.open.fill"
        security.tint = secure ? CommandBarColors.lockSecure : CommandBarColors.lockInsecure
        security.setAccessibilityLabel("Connection: " + security.title)
        let actionable = snapshot.capabilities.contains(.certificateViewer)
        security.isEnabled = actionable; security.statusOnly = !actionable
        security.setAccessibilityRole(actionable ? .button : .staticText)
        needsLayout = true; needsDisplay = true
    }
    public override func layout() {
        super.layout()
        favicon.frame = SiteControlMetrics.faviconFrame
        hostLabel.frame = CGRect(x: SiteControlMetrics.titleX, y: SiteControlMetrics.titleBaseline - hostLabel.font!.ascender,
                                 width: bounds.width - SiteControlMetrics.titleX - SiteControlMetrics.inset, height: hostLabel.intrinsicContentSize.height)
        let buttons = controls.prefix(6).filter { !$0.isHidden }
        let total = CGFloat(buttons.count) * SiteControlMetrics.actionButton.width + CGFloat(max(0, buttons.count - 1)) * SiteControlMetrics.actionGap
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(index) * (SiteControlMetrics.actionButton.width + SiteControlMetrics.actionGap),
                                  y: SiteControlMetrics.headerHeight, width: SiteControlMetrics.actionButton.width, height: SiteControlMetrics.actionButton.height)
        }
        let footerY = bounds.height - SiteControlMetrics.footerHeight + SiteControlMetrics.footerY
        security.frame = CGRect(x: SiteControlMetrics.footerInset, y: footerY, width: security.intrinsicContentSize.width, height: SiteControlMetrics.footerButton)
        more.frame = CGRect(x: bounds.width - SiteControlMetrics.footerInset - SiteControlMetrics.footerButton, y: footerY,
                            width: SiteControlMetrics.footerButton, height: SiteControlMetrics.footerButton)
    }
    public override func draw(_ dirtyRect: NSRect) {
        Core.popoverBackground.nsColor.setFill()
        let shape = NSBezierPath(roundedRect: bounds, xRadius: SiteControlMetrics.cornerRadius, yRadius: SiteControlMetrics.cornerRadius)
        shape.fill()
        let px = 1 / (window?.backingScaleFactor ?? 1)
        CommandBarColors.hairlineDivider.nsColor.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: px / 2, dy: px / 2), xRadius: SiteControlMetrics.cornerRadius, yRadius: SiteControlMetrics.cornerRadius)
        edge.lineWidth = px; edge.stroke()
        let line = NSBezierPath(); line.lineWidth = px
        line.move(to: CGPoint(x: SiteControlMetrics.separatorInset, y: bounds.height - SiteControlMetrics.footerHeight))
        line.line(to: CGPoint(x: bounds.width - SiteControlMetrics.separatorInset, y: bounds.height - SiteControlMetrics.footerHeight)); line.stroke()
        hostLabel.textColor = Core.foregroundPrimary.nsColor
    }
}

/// Native control with our own template glyph and hover plate. AppKit supplies
/// target/action, keyboard activation and the accessibility press action.
@MainActor
public final class SiteControlButton: NSButton {
    public let controlID: String
    public var symbol: String { didSet { needsDisplay = true } }
    public var tint = Core.foregroundSecondary
    public var invoke: (() -> Void)?
    public var statusOnly = false
    private let pointSize: CGFloat
    private var hovered = false
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public init(id: String, label: String, symbol: String, pointSize: CGFloat) {
        self.controlID = id; self.symbol = symbol; self.pointSize = pointSize
        super.init(frame: .zero)
        title = ""; isBordered = false; focusRingType = .none
        setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
        setAccessibilityRole(.button); setAccessibilityLabel(label); identifier = NSUserInterfaceItemIdentifier(id); toolTip = label
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
    public override var intrinsicContentSize: NSSize {
        CGSize(width: pointSize + (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: SiteControlMetrics.securityGlyph, weight: .medium)]).width + SiteControlMetrics.securityPadding * 3,
               height: SiteControlMetrics.footerButton)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    public override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            (isHighlighted ? SidebarColors.itemHoveredBackground : SidebarColors.itemBackground).nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: SiteControlMetrics.actionRadius, yRadius: SiteControlMetrics.actionRadius).fill()
        }
        let color = tint.nsColor.withAlphaComponent(isEnabled || statusOnly ? 1 : SiteControlMetrics.disabledAlpha)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        if let image {
            let x = title.isEmpty ? (bounds.width - image.size.width) / 2 : SiteControlMetrics.securityPadding
            let rect = CGRect(x: x, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            image.draw(in: rect)
            if !title.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: SiteControlMetrics.securityGlyph, weight: .medium), .foregroundColor: color]
                let size = (title as NSString).size(withAttributes: attrs)
                (title as NSString).draw(at: CGPoint(x: rect.maxX + SiteControlMetrics.securityPadding, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            }
        }
        if window?.firstResponder === self {
            Core.focusRing.nsColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: SiteControlMetrics.focusWidth / 2, dy: SiteControlMetrics.focusWidth / 2), xRadius: SiteControlMetrics.actionRadius, yRadius: SiteControlMetrics.actionRadius)
            ring.lineWidth = SiteControlMetrics.focusWidth; ring.stroke()
        }
    }
}
