import AppKit
import QuartzCore
import OpenDesign
import OpenBoosts

@MainActor
public final class SiteControlView: NSView {
    public let panel = SiteControlPanelView(frame: .zero)
    public var onOutside: (() -> Void)?
    public var onAnchor: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var anchorFrame: CGRect = .zero
    public var arrowTip: CGPoint?
    public var arrowPointsUp = false
    public var isActive = false
    public var panelFrame: CGRect { panel.frame }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; addSubview(panel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        if anchorFrame.contains(local) { onAnchor?(); return self }
        if !panel.frame.contains(local) { onOutside?(); return nil }
        return super.hitTest(point)
    }
    public override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { _ = onKey?(event); return false }
        return super.performKeyEquivalent(with: event)
    }
    // The anchor-toggle hit is deliberately consumed after dismissal.
    public override func mouseDown(with event: NSEvent) {}
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}

}

@MainActor
public final class SiteControlPanelView: NSView {
    public private(set) var snapshot: SiteControlSnapshot?
    public private(set) var controls: [SiteControlButton] = []
    public var onAction: ((String, NSRect) -> Void)?
    public var onMore: ((SiteControlButton) -> Void)?
    public var onSecurity: (() -> Void)?
    public var onToggle: ((SiteSettingTile) -> Void)?
    public var onBoostEnabled: ((OpenBoosts.BoostID, Bool) -> Void)?
    public var onEdit: ((OpenBoosts.BoostID) -> Void)?
    public var onSection: ((String) -> Void)?
    public var onReload: (() -> Void)?
    public internal(set) var showsReload = false
    public override var isFlipped: Bool { true }
    public var preferredHeight: CGFloat { fixedHeight + bodyHeight }
    var fixedHeight: CGFloat { SiteControlMetrics.headerHeight + SiteControlMetrics.actionRowHeight + SiteControlMetrics.footerHeight }
    public var boostsSectionVisible: Bool { snapshot?.context.isWebsite == true && snapshot?.boosts.isEmpty == false }
    // OpenExtensionsUI owns the body. Do not draw a substitute grid while absent.
    public var extensionsSectionVisible: Bool { false }
    let more = SiteControlButton(id: "more", label: "More", symbol: "ellipsis", pointSize: SiteControlMetrics.moreGlyph)
    private let hostLabel = NSTextField(labelWithString: "")
    private let favicon = NSImageView()
    private let security = SiteControlButton(id: "security", label: "Connection", symbol: "lock.fill", pointSize: SiteControlMetrics.securityGlyph)
    private let scroll = NSScrollView()
    private let body = SiteControlBodyView(frame: .zero)
    private let separatorLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    private var actions: [SiteControlButton] = []
    private var bodyHeight: CGFloat = 0
    private var tileButtons: [String: SiteControlTileButton] = [:]
    private var boostRows: [SiteControlBoostRow] = []

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor; shadowLayer.shadowOpacity = SiteControlMetrics.shadowOpacity
        shadowLayer.shadowRadius = SiteControlMetrics.shadowRadius
        shadowLayer.actions = ["position": NSNull(), "bounds": NSNull(), "shadowPath": NSNull()]
        shadowMask.fillRule = .evenOdd; shadowMask.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        shadowLayer.mask = shadowMask
        layer?.insertSublayer(shadowLayer, at: 0)
        arrowLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        layer?.addSublayer(arrowLayer)
        separatorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
        separatorLayer.fillColor = nil; layer?.addSublayer(separatorLayer)
        setAccessibilityElement(true); setAccessibilityRole(.popover); setAccessibilityLabel("Site Control Center")
        hostLabel.font = Typography.siteControlTitle.font
        hostLabel.textColor = Core.foregroundPrimary.nsColor
        hostLabel.lineBreakMode = .byTruncatingTail; hostLabel.maximumNumberOfLines = 1
        hostLabel.setAccessibilityRole(.staticText); favicon.setAccessibilityRole(.image)
        addSubview(hostLabel); addSubview(favicon)
        let specs = [("share", "Share", "square.and.arrow.up"), ("copyURL", "Copy URL", "link"),
                     ("newBoost", "New Boost", "paintbrush.pointed"), ("capture", "Capture a portion of this page", "camera.viewfinder"),
                     ("captureFull", "Capture the full page", "rectangle.portrait.and.arrow.forward"), ("capturePortrait", "Capture in Portrait Mode", "rectangle.portrait")]
        for (id, label, symbol) in specs {
            let button = SiteControlButton(id: "action." + id, label: label, symbol: symbol, pointSize: SiteControlMetrics.actionGlyph)
            button.invoke = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onAction?(id, button.convert(button.bounds, to: nil))
            }
            if id == "copyURL" { button.toolTip = label + " (⇧⌘C)" }
            if id == "capture" { button.toolTip = label + " (⇧⌘2)" }
            actions.append(button); addSubview(button)
        }
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateRowVisibility), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.documentView = body; addSubview(scroll)
        security.invoke = { [weak self] in self?.onSecurity?() }
        more.invoke = { [weak self] in guard let self else { return }; self.onMore?(self.more) }
        more.setAccessibilityRole(.menuButton)
        addSubview(security); addSubview(more)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for button in tileButtons.values { button.appearance = effectiveAppearance; button.apply(button.tile, animated: false) }
        if snapshot?.context.faviconPNG == nil { favicon.image = SiteControlDrawing.symbol("globe", size: SiteControlMetrics.faviconFrame.width, color: Core.foregroundPrimary.resolved(contentAppearance).nsColor) }
        arrowLayer.fillColor = Core.popoverBackground.cgColor(contentAppearance)
        arrowLayer.strokeColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance)
        controls.forEach { $0.needsDisplay = true }; needsDisplay = true
    }

    public func apply(_ snapshot: SiteControlSnapshot) {
        let hadSnapshot = self.snapshot != nil
        self.snapshot = snapshot
        hostLabel.stringValue = snapshot.context.displayHost; setAccessibilityHelp(snapshot.context.displayHost)
        favicon.image = snapshot.context.faviconPNG.flatMap(NSImage.init(data:)) ?? SiteControlDrawing.symbol("globe", size: SiteControlMetrics.faviconFrame.width, color: Core.foregroundPrimary.resolved(contentAppearance).nsColor)
        let commands = ["action.share": "share-page", "action.copyURL": "copy-url", "action.capture": "capture-page", "action.captureFull": "capture-full-page", "action.capturePortrait": "capture-portrait"]
        for button in actions {
            button.isHidden = !snapshot.context.isWebsite && !["action.share", "action.copyURL"].contains(button.controlID)
            button.isEnabled = button.controlID == "action.newBoost" ? snapshot.canCreateBoost : snapshot.commandsEnabled[commands[button.controlID] ?? ""] ?? true
        }
        let secure = snapshot.context.security == .secure || (snapshot.context.security == .unknown && snapshot.context.url.scheme == "https")
        security.title = secure ? "Secure" : "Insecure"; security.symbol = secure ? "lock.fill" : "lock.open.fill"
        security.tint = secure ? CommandBarColors.lockSecure : CommandBarColors.lockInsecure
        security.setAccessibilityLabel("Connection: " + security.title)
        let actionable = snapshot.capabilities.contains(.certificateViewer)
        security.isEnabled = actionable; security.statusOnly = !actionable; security.setAccessibilityRole(actionable ? .button : .staticText)
        controls = actions.filter { !$0.isHidden }
        let scrollPosition = scroll.contentView.bounds.origin
        let previousRows = Dictionary(uniqueKeysWithValues: boostRows.map { ($0.boost.id, $0) })
        body.subviews.forEach { $0.removeFromSuperview() }; body.separators = []
        boostRows = []
        var y: CGFloat = 0
        var nextTiles: [String: SiteControlTileButton] = [:]
        if snapshot.context.isWebsite {
            appendHeader("settings", caption: "Settings", accessory: "More", y: &y)
            for (index, tile) in snapshot.tiles.enumerated() {
                let button = tileButtons[tile.id] ?? SiteControlTileButton(tile)
                button.appearance = effectiveAppearance
                button.apply(tile, animated: hadSnapshot)
                button.frame = CGRect(x: SiteControlMetrics.inset + CGFloat(index % 2) * (SiteControlMetrics.tile.width + SiteControlMetrics.tileGap),
                                      y: y + CGFloat(index / 2) * (SiteControlMetrics.tile.height + SiteControlMetrics.tileGap), width: SiteControlMetrics.tile.width, height: SiteControlMetrics.tile.height)
                button.invoke = { [weak self, weak button] in guard let button else { return }; self?.onToggle?(button.tile) }
                body.addSubview(button); controls.append(button); nextTiles[tile.id] = button
            }
            let rows = (snapshot.tiles.count + 1) / 2
            y += CGFloat(rows) * SiteControlMetrics.tile.height + CGFloat(max(0, rows - 1)) * SiteControlMetrics.tileGap
            if showsReload {
                let label = textLabel("Reload to apply changes.", font: Typography.tileTitle.font)
                label.frame = CGRect(x: SiteControlMetrics.inset, y: y, width: SiteControlMetrics.width - 2 * SiteControlMetrics.inset, height: SiteControlMetrics.reloadRowHeight)
                label.alignment = .left; body.addSubview(label)
                let reload = SiteControlButton(id: "reload", label: "Reload", symbol: "", pointSize: SiteControlMetrics.bodySize)
                reload.title = "Reload"; reload.tint = Core.brandBlue
                reload.frame = CGRect(x: SiteControlMetrics.width - SiteControlMetrics.inset - reload.intrinsicContentSize.width, y: y, width: reload.intrinsicContentSize.width, height: SiteControlMetrics.reloadRowHeight)
                reload.invoke = { [weak self] in self?.onReload?() }; body.addSubview(reload); controls.append(reload)
                y += SiteControlMetrics.reloadRowHeight
            }
            y += SiteControlMetrics.sectionBottomPadding
            if !snapshot.boosts.isEmpty {
                body.separators.append(y)
                appendHeader("boosts", caption: "Boosts", accessory: "Manage", y: &y)
                if !snapshot.boostsGloballyEnabled {
                    let note = textLabel("Boosts are off. Turn them on in Settings.", font: Typography.tileSubtitle.font)
                    note.frame = CGRect(x: SiteControlMetrics.inset, y: y, width: SiteControlMetrics.width - 2 * SiteControlMetrics.inset, height: SiteControlMetrics.globalOffHeight)
                    body.addSubview(note); y += SiteControlMetrics.globalOffHeight
                }
                for boost in snapshot.boosts {
                    let row = previousRows[boost.id] ?? SiteControlBoostRow(boost, enabled: snapshot.boostsGloballyEnabled && !snapshot.context.isIncognito)
                    row.frame = CGRect(x: 0, y: y, width: SiteControlMetrics.width, height: SiteControlMetrics.boostRowHeight)
                    if !snapshot.boostsGloballyEnabled { row.alphaValue = SiteControlMetrics.globalOffAlpha }
                    if snapshot.context.isIncognito {
                        row.toggle.toolTip = "Boosts can't be edited in a private window."; row.edit.toolTip = row.toggle.toolTip
                        row.toggle.setAccessibilityHelp(row.toggle.toolTip); row.edit.setAccessibilityHelp(row.toggle.toolTip)
                    }
                    row.toggle.invoke = { [weak self] in self?.onBoostEnabled?(boost.id, !boost.isEnabled) }
                    row.onEdit = { [weak self] in self?.onEdit?(boost.id) }
                    body.addSubview(row)
                    if previousRows[boost.id] != nil { row.apply(boost, enabled: snapshot.boostsGloballyEnabled && !snapshot.context.isIncognito) }
                    boostRows.append(row); controls += [row.toggle, row.edit]
                    y += SiteControlMetrics.boostRowHeight
                }
                y += SiteControlMetrics.sectionBottomPadding
            }
        }
        tileButtons = nextTiles; bodyHeight = y; body.frame = CGRect(x: 0, y: 0, width: SiteControlMetrics.width, height: y)
        controls += [security, more]
        scroll.contentView.scroll(to: scrollPosition); scroll.reflectScrolledClipView(scroll.contentView)
        needsLayout = true; needsDisplay = true
    }
    private func appendHeader(_ id: String, caption: String, accessory: String, y: inout CGFloat) {
        let header = SiteControlSectionButton(id: "section." + id, caption: caption, accessory: accessory)
        header.frame = CGRect(x: 0, y: y, width: SiteControlMetrics.width, height: SiteControlMetrics.sectionHeaderHeight)
        header.invoke = { [weak self] in self?.onSection?(id) }; body.addSubview(header); controls.append(header)
        y += SiteControlMetrics.sectionHeaderHeight + SiteControlMetrics.sectionBodyGap
    }
    private func textLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = font; label.textColor = Core.foregroundSecondary.nsColor
        label.setAccessibilityElement(true); label.setAccessibilityRole(.staticText); label.setAccessibilityLabel(text); return label
    }
    var focusableControls: [SiteControlButton] { controls.filter { $0.isEnabled && !$0.isHidden } }
    public var focusOrder: [String] { focusableControls.map(\.controlID) }
    public func control(id: String) -> SiteControlButton? { controls.first { $0.controlID == id } }
    func configureKeys(_ handler: @escaping (NSEvent) -> Bool) {
        controls.forEach { $0.onKey = handler }; boostRows.forEach { $0.onKey = handler }
    }
    func focus(_ control: SiteControlButton) {
        if let row = control.superview as? SiteControlBoostRow { row.isHidden = false; row.edit.alphaValue = 1 }
        control.scrollToVisible(control.bounds); window?.makeFirstResponder(control); control.needsDisplay = true
    }
    @objc private func updateRowVisibility() {
        let visible = scroll.documentVisibleRect
        // Keep the controls and their frames for keyboard navigation, but avoid
        // AppKit creating drawing contexts for rows outside the scroll viewport.
        for row in boostRows { row.isHidden = !row.frame.intersects(visible) }
    }
    func editFocusedBoost() -> Bool {
        guard let focused = window?.firstResponder as? NSView else { return false }
        let row = (focused as? SiteControlBoostRow) ?? (focused.superview as? SiteControlBoostRow)
        guard let row, row.edit.isEnabled else { return false }; row.onEdit?(); return true
    }
    public override func layout() {
        super.layout(); let m = SiteControlMetrics.self
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds; shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius, transform: nil)
        shadowLayer.shadowOffset = CGSize(width: 0, height: -m.shadowOffsetY)
        let maskPath = CGMutablePath(); maskPath.addRect(bounds.insetBy(dx: -m.shadowRadius * 4, dy: -m.shadowRadius * 4))
        maskPath.addRoundedRect(in: bounds, cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius)
        shadowMask.frame = bounds; shadowMask.path = maskPath
        CATransaction.commit()
        favicon.frame = m.faviconFrame
        hostLabel.frame = CGRect(x: m.titleX, y: m.titleBaseline - hostLabel.font!.ascender, width: bounds.width - m.titleX - m.inset, height: hostLabel.intrinsicContentSize.height)
        let buttons = actions.filter { !$0.isHidden }
        let total = CGFloat(buttons.count) * m.actionButton.width + CGFloat(max(0, buttons.count - 1)) * m.actionGap
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(index) * (m.actionButton.width + m.actionGap), y: m.headerHeight, width: m.actionButton.width, height: m.actionButton.height)
        }
        scroll.frame = CGRect(x: 0, y: m.headerHeight + m.actionRowHeight, width: bounds.width, height: max(0, bounds.height - fixedHeight))
        scroll.isHidden = bodyHeight == 0
        let footerY = bounds.height - m.footerHeight + m.footerY
        security.frame = CGRect(x: m.footerInset, y: footerY, width: security.intrinsicContentSize.width, height: m.footerButton)
        more.frame = CGRect(x: bounds.width - m.footerInset - m.footerButton, y: footerY, width: m.footerButton, height: m.footerButton)
        updateRowVisibility()
    }
    func updateArrow(tip: CGPoint?, pointsUp: Bool) {
        guard let tip else { arrowLayer.path = nil; return }
        let local = CGPoint(x: tip.x - frame.minX, y: tip.y - frame.minY)
        let path = CGMutablePath(); path.move(to: local)
        if pointsUp {
            path.addLine(to: CGPoint(x: local.x - SiteControlMetrics.arrowBase / 2, y: local.y + SiteControlMetrics.arrowHeight))
            path.addLine(to: CGPoint(x: local.x + SiteControlMetrics.arrowBase / 2, y: local.y + SiteControlMetrics.arrowHeight))
        } else {
            path.addLine(to: CGPoint(x: local.x + SiteControlMetrics.arrowHeight, y: local.y - SiteControlMetrics.arrowBase / 2))
            path.addLine(to: CGPoint(x: local.x + SiteControlMetrics.arrowHeight, y: local.y + SiteControlMetrics.arrowBase / 2))
        }
        path.closeSubpath()
        arrowLayer.frame = bounds; arrowLayer.path = path
        arrowLayer.fillColor = Core.popoverBackground.cgColor(contentAppearance)
        arrowLayer.strokeColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance)
        arrowLayer.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
    }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        let px = 1 / (window?.backingScaleFactor ?? 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = Core.popoverBackground.cgColor(contentAppearance)
        layer?.cornerRadius = SiteControlMetrics.cornerRadius
        layer?.borderWidth = px; layer?.borderColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance)
        let lines = CGMutablePath()
        for y in [SiteControlMetrics.headerHeight + SiteControlMetrics.actionRowHeight, bounds.height - SiteControlMetrics.footerHeight] {
            lines.move(to: CGPoint(x: SiteControlMetrics.separatorInset, y: y))
            lines.addLine(to: CGPoint(x: bounds.width - SiteControlMetrics.separatorInset, y: y))
        }
        separatorLayer.frame = bounds; separatorLayer.path = lines; separatorLayer.lineWidth = px
        separatorLayer.strokeColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance)
        CATransaction.commit()
    }

}

@MainActor
private final class SiteControlBodyView: NSView {
    var separators: [CGFloat] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        CommandBarColors.hairlineDivider.nsColor.setStroke()
        let line = NSBezierPath(); line.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
        for y in separators { line.move(to: CGPoint(x: SiteControlMetrics.separatorInset, y: y)); line.line(to: CGPoint(x: bounds.width - SiteControlMetrics.separatorInset, y: y)) }
        line.stroke()
    }
}
