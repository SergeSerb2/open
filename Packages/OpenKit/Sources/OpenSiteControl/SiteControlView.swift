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
    private let panelShadow = CALayer()
    public var panelFrame: CGRect { panel.frame }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        panelShadow.shadowColor = NSColor.black.cgColor
        panelShadow.shadowOpacity = SiteControlMetrics.shadowOpacity
        panelShadow.shadowRadius = SiteControlMetrics.shadowRadius
        layer?.addSublayer(panelShadow); addSubview(panel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Selection only: dismissal is an input side effect, never hit testing.
        return panel.frame.contains(local) ? super.hitTest(point) : self
    }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panelShadow.frame = panel.frame
        panelShadow.shadowPath = SiteControlShape.path(in: panel.bounds, radius: SiteControlMetrics.cornerRadius)
        // AppKit flips the backing layer. Positive local y is down in this overlay.
        panelShadow.shadowOffset = CGSize(width: 0, height: SiteControlMetrics.shadowOffsetY)
        CATransaction.commit()
    }
    public override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if anchorFrame.contains(point) { onAnchor?(); return }
        guard !panel.frame.contains(point), let window else { return }
        onOutside?()
        // Dismiss synchronously, then let NSWindow dispatch the original click to
        // the now-uncovered real target. Anchor toggles are deliberately consumed.
        if isHidden { window.sendEvent(event) }
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
    private let favicon = SiteControlFaviconView()
    private let security = SiteControlButton(id: "security", label: "Connection", symbol: "lock.fill", pointSize: SiteControlMetrics.securityGlyph)
    private let more = SiteControlButton(id: "more", label: "More", symbol: "ellipsis", pointSize: SiteControlMetrics.moreGlyph, weight: .bold)

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = SiteControlMetrics.cornerRadius; layer?.cornerCurve = .continuous
        setAccessibilityElement(true); setAccessibilityRole(.popover); setAccessibilityTitle("Site Control Center")
        hostLabel.font = Typography.siteControlTitle.font
        hostLabel.setAccessibilityRole(.staticText); favicon.setAccessibilityElement(false); favicon.setAccessibilityHidden(true)
        hostLabel.lineBreakMode = .byTruncatingTail; hostLabel.maximumNumberOfLines = 1
        addSubview(hostLabel); addSubview(favicon)
        let actions = [("share", "Share", "square.and.arrow.up"), ("copyURL", "Copy URL", "link"),
                       ("newBoost", "New Boost", "paintbrush.pointed"), ("capture", "Capture a portion of this page", "viewfinder"),
                       ("captureFull", "Capture the full page", "doc.viewfinder"),
                       ("capturePortrait", "Capture in Portrait Mode", "rectangle.portrait")]
        for (id, label, symbol) in actions {
            let button = SiteControlButton(id: "action." + id, label: label, symbol: symbol, pointSize: SiteControlMetrics.actionGlyph)
            let keys = id == "copyURL" ? ["⇧", "⌘", "C"] : id == "capture" ? ["⇧", "⌘", "2"] : []
            button.tooltipTitle = label; button.tooltipKeys = keys
            button.invoke = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onAction?(id, button.convert(button.bounds, to: nil))
            }
            controls.append(button); addSubview(button)
        }
        security.invoke = { [weak self] in self?.onSecurity?() }
        more.invoke = { [weak self] in guard let self else { return }; self.onMore?(self.more) }
        more.setAccessibilityRole(.menuButton); more.isEnabled = false
        addSubview(security); addSubview(more)
        controls += [security, more]
        setAccessibilityChildren([hostLabel] + controls)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func apply(_ snapshot: SiteControlSnapshot) {
        self.snapshot = snapshot
        hostLabel.stringValue = snapshot.context.displayHost
        // NSAccessibilityProtocol maps accessibilityLabel to AXDescription;
        // accessibilityTitle is AXTitle. AXHelp is intentionally absent.
        setAccessibilityLabel(snapshot.context.displayHost)
        let decoded = snapshot.context.faviconPNG.flatMap(NSImage.init(data:))
        favicon.isFallback = decoded == nil
        favicon.image = decoded ?? Glyph.globe.image
        hostLabel.textColor = Core.foregroundPrimary.nsColor
        for button in controls.prefix(6) {
            button.isHidden = !snapshot.context.isWebsite && !["action.share", "action.copyURL"].contains(button.controlID)
            let commands = ["action.share": "share-page", "action.copyURL": "copy-url", "action.capture": "capture-page",
                            "action.captureFull": "capture-full-page", "action.capturePortrait": "capture-portrait"]
            let defaultEnabled = !button.controlID.hasPrefix("action.capture")
            button.isEnabled = button.controlID == "action.newBoost" ? snapshot.canCreateBoost : snapshot.commandsEnabled[commands[button.controlID] ?? ""] ?? defaultEnabled
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
                                  y: SiteControlMetrics.headerHeight + SiteControlMetrics.actionButtonInsetY, width: SiteControlMetrics.actionButton.width, height: SiteControlMetrics.actionButton.height)
        }
        let footerY = bounds.height - SiteControlMetrics.footerHeight + SiteControlMetrics.footerY
        security.frame = CGRect(x: SiteControlMetrics.footerInset, y: footerY, width: security.intrinsicContentSize.width, height: SiteControlMetrics.footerButton)
        more.frame = CGRect(x: bounds.width - SiteControlMetrics.footerInset - SiteControlMetrics.footerButton, y: footerY,
                            width: SiteControlMetrics.footerButton, height: SiteControlMetrics.footerButton)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = SiteControlShape.path(in: bounds, radius: SiteControlMetrics.cornerRadius)
        context.addPath(shape); context.setFillColor(Core.popoverBackground.nsColor.cgColor); context.fillPath()
        let px = 1 / (window?.backingScaleFactor ?? 1)
        context.saveGState(); context.addPath(shape); context.clip()
        context.addPath(shape); context.setStrokeColor(CommandBarColors.hairlineDivider.nsColor.cgColor)
        context.setLineWidth(2 * px); context.strokePath(); context.restoreGState()
        let y = bounds.height - SiteControlMetrics.footerHeight + px / 2
        context.setStrokeColor(CommandBarColors.hairlineDivider.nsColor.cgColor); context.setLineWidth(px)
        context.move(to: CGPoint(x: SiteControlMetrics.separatorInset, y: y))
        context.addLine(to: CGPoint(x: bounds.width - SiteControlMetrics.separatorInset, y: y)); context.strokePath()
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
    public var tooltipTitle: String?
    public var tooltipKeys: [String] = []
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    private var trackingPress = false
    private var hovered = false
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public init(id: String, label: String, symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) {
        self.controlID = id; self.symbol = symbol; self.pointSize = pointSize; self.weight = weight
        super.init(frame: .zero)
        title = ""; isBordered = false; focusRingType = .none
        setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label); identifier = NSUserInterfaceItemIdentifier(id)
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
    public override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true
        if isEnabled, let tooltipTitle {
            TooltipController.shared.schedule(Tooltip(title: tooltipTitle, keys: tooltipKeys,
                style: .defaultTheme(system: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)), for: self)
        }
    }
    public override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true; TooltipController.shared.cancel(for: self)
    }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        TooltipController.shared.cancel(for: self)
        trackingPress = true; isHighlighted = true; needsDisplay = true
    }
    public override func mouseUp(with event: NSEvent) {
        let activate = trackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        trackingPress = false; isHighlighted = false; needsDisplay = true
        if activate && isEnabled { sendAction(action, to: target) }
    }
    public override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            (isHighlighted ? SidebarColors.itemHoveredBackground : SidebarColors.itemBackground).nsColor.setFill()
            if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(SiteControlShape.path(in: bounds, radius: SiteControlMetrics.actionRadius)); context.fillPath()
            }
        }
        let resolved = tint.nsColor
        let color = resolved.withAlphaComponent(resolved.alphaComponent * (isEnabled || statusOnly ? 1 : SiteControlMetrics.disabledAlpha))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        if let image {
            let x = title.isEmpty ? (bounds.width - image.size.width) / 2 : SiteControlMetrics.securityPadding
            let rect = CGRect(x: x, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                context.setBlendMode(.sourceIn); context.setFillColor(color.cgColor); context.fill(rect)
                context.endTransparencyLayer(); context.restoreGState()
            }
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

/// Drawing the fallback ourselves keeps the template tint identical to the action
/// glyphs. NSImageView's template cell does not retain it in the offscreen renderer.
@MainActor
private final class SiteControlFaviconView: NSImageView {
    var isFallback = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard isFallback, let image, let context = NSGraphicsContext.current?.cgContext else { super.draw(dirtyRect); return }
        let size = image.size
        let rect = CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(Core.foregroundSecondary.nsColor.cgColor); context.fill(rect)
        context.endTransparencyLayer(); context.restoreGState()
    }
}
