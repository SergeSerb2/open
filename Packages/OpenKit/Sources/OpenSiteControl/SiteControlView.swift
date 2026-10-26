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
    public var isActive = false
    private let panelShadow = CALayer()
    public var panelFrame: CGRect { panel.frame }
    public var presentationLayers: [CALayer] { [panel.layer, panelShadow].compactMap { $0 } }
    func clearStructureAnimations() {
        for state in captureStructure() {
            for key in state.layer.animationKeys() ?? [] where key.hasPrefix("rows.") { state.layer.removeAnimation(forKey: key) }
        }
    }
    func captureStructure() -> [SiteControlLayerState] {
        var states = panel.captureStructure()
        states.append(SiteControlLayerState(panelShadow, keys: ["bounds", "position", "shadowPath"]))
        return states
    }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}
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
        guard !isHidden && isActive else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Selection only: dismissal is an input side effect, never hit testing.
        return panel.frame.contains(local) ? super.hitTest(point) : self
    }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let surface = panel.layer { surface.anchorPoint = .zero; surface.position = panel.frame.origin }
        panelShadow.anchorPoint = .zero
        panelShadow.frame = panel.frame
        panelShadow.shadowPath = SiteControlShape.path(in: panel.bounds, radius: SiteControlMetrics.cornerRadius)
        // AppKit flips the backing layer. Positive local y is down in this overlay.
        panelShadow.shadowOffset = CGSize(width: 0, height: SiteControlMetrics.shadowOffsetY)
        CATransaction.commit()
    }
    public override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { _ = onKey?(event); return false }
        return super.performKeyEquivalent(with: event)
    }
    public override func mouseDown(with event: NSEvent) { forwardOutside(event) }
    public override func rightMouseDown(with event: NSEvent) { forwardOutside(event) }
    public override func otherMouseDown(with event: NSEvent) { forwardOutside(event) }
    private func forwardOutside(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if anchorFrame.contains(point) { onAnchor?(); return }
        guard !panel.frame.contains(point), let window else { return }
        onOutside?()
        // Dismiss synchronously, then let NSWindow dispatch the original click to
        // the now-uncovered real target. Anchor toggles are deliberately consumed.
        if !isActive { window.sendEvent(event) }
    }
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
    let more = SiteControlButton(id: "more", label: "More", symbol: "ellipsis", pointSize: SiteControlMetrics.moreGlyph, weight: .bold)
    private let hostLabel = NSTextField(labelWithString: "")
    private let favicon = SiteControlFaviconView()
    private let security = SiteControlButton(id: "security", label: "Connection", symbol: "lock.fill", pointSize: SiteControlMetrics.securityGlyph)
    private let scroll = NSScrollView()
    private let body = SiteControlBodyView(frame: .zero)
    private let separatorLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let edgeClip = CAShapeLayer()
    private let surfaceClip = CAShapeLayer()
    private var actions: [SiteControlButton] = []
    private var renderedReload = false
    private var lastFaviconPNG: Data?
    private var faviconConfigured = false
    private var bodyHeight: CGFloat = 0
    private var headerButtons: [String: SiteControlSectionButton] = [:]
    private var tileButtons: [String: SiteControlTileButton] = [:]
    private var boostRows: [SiteControlBoostRow] = []

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = false; layer?.cornerCurve = .continuous
        surfaceClip.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.mask = surfaceClip
        fillLayer.actions = ["path": NSNull(), "fillColor": NSNull()]
        edgeLayer.actions = ["path": NSNull(), "strokeColor": NSNull()]; edgeLayer.fillColor = nil; edgeLayer.mask = edgeClip
        edgeClip.actions = ["path": NSNull()]
        layer?.addSublayer(fillLayer); layer?.addSublayer(edgeLayer)
        separatorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
        separatorLayer.fillColor = nil; layer?.addSublayer(separatorLayer)
        setAccessibilityElement(true); setAccessibilityRole(.popover); setAccessibilityTitle("Site Control Center")
        hostLabel.font = Typography.siteControlTitle.font
        hostLabel.textColor = Core.foregroundPrimary.nsColor
        hostLabel.lineBreakMode = .byTruncatingTail; hostLabel.maximumNumberOfLines = 1
        hostLabel.setAccessibilityElement(false); hostLabel.setAccessibilityHidden(true); favicon.setAccessibilityElement(false); favicon.setAccessibilityHidden(true)
        addSubview(hostLabel); addSubview(favicon)
        let specs = [("share", "Share", "square.and.arrow.up"), ("copyURL", "Copy URL", "link"),
                     ("newBoost", "New Boost", "paintbrush.pointed"), ("capture", "Capture a portion of this page", "viewfinder"),
                     ("captureFull", "Capture the full page", "doc.viewfinder"), ("capturePortrait", "Capture in Portrait Mode", "rectangle.portrait")]
        for (id, label, symbol) in specs {
            let button = SiteControlButton(id: "action." + id, label: label, symbol: symbol, pointSize: SiteControlMetrics.actionGlyph)
            button.invoke = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onAction?(id, button.convert(button.bounds, to: nil))
            }
            if id == "copyURL" { button.toolTip = label; button.tooltipKeys = ["⇧", "⌘", "C"] }
            if id == "capture" { button.toolTip = label; button.tooltipKeys = ["⇧", "⌘", "2"] }
            actions.append(button); addSubview(button)
        }
        scroll.setAccessibilityLabel("Site settings and Boosts")
        scroll.wantsLayer = true; scroll.layer?.masksToBounds = true
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
        favicon.needsDisplay = true
        controls.forEach { $0.needsDisplay = true }; needsDisplay = true
    }

    public func apply(_ snapshot: SiteControlSnapshot) {
        guard self.snapshot != snapshot || renderedReload != showsReload else { return }
        let hadSnapshot = self.snapshot != nil
        renderedReload = showsReload
        self.snapshot = snapshot
        hostLabel.stringValue = snapshot.context.displayHost; setAccessibilityLabel(snapshot.context.displayHost)
        if !faviconConfigured || lastFaviconPNG != snapshot.context.faviconPNG {
            faviconConfigured = true; lastFaviconPNG = snapshot.context.faviconPNG
            let decoded = snapshot.context.faviconPNG.flatMap(NSImage.init(data:))
            favicon.isFallback = decoded == nil; favicon.image = decoded ?? Glyph.globe.image
        }
        let commands = ["action.share": "share-page", "action.copyURL": "copy-url", "action.capture": "capture-page", "action.captureFull": "capture-full-page", "action.capturePortrait": "capture-portrait"]
        for button in actions {
            button.isHidden = !snapshot.context.isWebsite && !["action.share", "action.copyURL"].contains(button.controlID)
            button.isEnabled = button.controlID == "action.newBoost" ? snapshot.canCreateBoost : snapshot.commandsEnabled[commands[button.controlID] ?? ""] ?? !button.controlID.hasPrefix("action.capture")
        }
        let scheme = snapshot.context.url.scheme?.lowercased()
        security.isHidden = scheme != "https" && scheme != "http"
        let secure = scheme == "https"
        security.title = secure ? "Secure" : "Insecure"; security.symbol = secure ? "lock.fill" : "lock.open.fill"
        security.tint = secure ? CommandBarColors.lockSecure : CommandBarColors.lockInsecure
        security.setAccessibilityLabel("Connection: " + security.title)
        let actionable = snapshot.capabilities.contains(.certificateViewer)
        security.isEnabled = actionable; security.statusOnly = !actionable; security.setAccessibilityRole(actionable ? .button : .staticText); security.toolTip = nil
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
                let label = textLabel("Reload to apply changes.", font: NSFont.systemFont(ofSize: SiteControlMetrics.bodySize, weight: .regular))
                label.frame = CGRect(x: SiteControlMetrics.inset, y: y, width: SiteControlMetrics.width - 2 * SiteControlMetrics.inset, height: SiteControlMetrics.reloadRowHeight)
                body.addSubview(label)
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
                    row.alphaValue = snapshot.boostsGloballyEnabled ? 1 : SiteControlMetrics.globalOffAlpha
                    row.toggle.alphaValue = snapshot.context.isIncognito ? 0.5 : 1
                    row.edit.disabledOpacity = snapshot.context.isIncognito ? 0.5 : 1
                    if snapshot.context.isIncognito {
                        row.toggle.toolTip = "Boosts can't be edited in a private window."; row.edit.toolTip = row.toggle.toolTip
                        row.toggle.setAccessibilityHelp(row.toggle.toolTip); row.edit.setAccessibilityHelp(row.toggle.toolTip)
                    } else {
                        row.toggle.toolTip = nil; row.edit.toolTip = "Edit " + boost.name
                        row.toggle.setAccessibilityHelp(nil); row.edit.setAccessibilityHelp(nil)
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
        tileButtons = nextTiles; bodyHeight = y; body.frame = CGRect(x: 0, y: 0, width: SiteControlMetrics.width, height: y); body.needsDisplay = true
        controls += [security, more].filter { !$0.isHidden }
        setAccessibilityChildren(actions.filter { !$0.isHidden } + [scroll] + [security, more].filter { !$0.isHidden })
        scroll.contentView.scroll(to: scrollPosition); scroll.reflectScrolledClipView(scroll.contentView)
        needsLayout = true; needsDisplay = true
    }
    private func appendHeader(_ id: String, caption: String, accessory: String, y: inout CGFloat) {
        let header = headerButtons[id] ?? SiteControlSectionButton(id: "section." + id, caption: caption, accessory: accessory)
        headerButtons[id] = header
        header.frame = CGRect(x: 0, y: y, width: SiteControlMetrics.width, height: SiteControlMetrics.sectionHeaderHeight)
        header.invoke = { [weak self] in self?.onSection?(id) }; body.addSubview(header); controls.append(header)
        y += SiteControlMetrics.sectionHeaderHeight + SiteControlMetrics.sectionBodyGap
    }
    private func textLabel(_ text: String, font: NSFont) -> SiteControlBaselineLabel {
        let label = SiteControlBaselineLabel(text: text,font: font)
        label.setAccessibilityElement(true); label.setAccessibilityRole(.staticText); label.setAccessibilityLabel(text); return label
    }
    var focusableControls: [SiteControlButton] { controls.filter { $0.isEnabled && !$0.isHidden } }
    public var focusOrder: [String] { focusableControls.map(\.controlID) }
    public func control(id: String) -> SiteControlButton? { controls.first { $0.controlID == id } }
    func configureKeys(_ handler: @escaping (NSEvent) -> Bool) {
        controls.forEach { $0.onKey = handler }; boostRows.forEach { $0.onKey = handler }
    }
    func focus(_ control: SiteControlButton, keyboard: Bool = true) {
        control.showsKeyboardFocus = keyboard
        if let row = control.superview as? SiteControlBoostRow { row.isHidden = false; row.edit.alphaValue = 1 }
        control.scrollToVisible(control.bounds); window?.makeFirstResponder(control); control.needsDisplay = true
    }
    @objc private func updateRowVisibility() {
        let visible = scroll.documentVisibleRect
        // Keep the controls and their frames for keyboard navigation, but avoid
        // AppKit creating drawing contexts for rows outside the scroll viewport.
        for row in boostRows {
            let focused = (window?.firstResponder as? NSView).map { $0 === row || $0.isDescendant(of: row) } ?? false
            row.isHidden = !focused && !row.frame.intersects(visible)
        }
    }
    func editFocusedBoost() -> Bool {
        guard let focused = window?.firstResponder as? NSView else { return false }
        let row = (focused as? SiteControlBoostRow) ?? (focused.superview as? SiteControlBoostRow)
        guard let row, row.edit.isEnabled else { return false }; row.onEdit?(); return true
    }
    func captureStructure() -> [SiteControlLayerState] {
        var states = [fillLayer, edgeLayer, edgeClip, surfaceClip, separatorLayer].map {
            SiteControlLayerState($0, keys: ["bounds", "position", "path"])
        }
        for layer in [layer, scroll.layer, security.layer, more.layer].compactMap({ $0 }) {
            states.append(SiteControlLayerState(layer, keys: ["bounds", "position"]))
        }
        for child in body.subviews { if let layer = child.layer { states.append(SiteControlLayerState(layer,keys: ["bounds","position"])) } }
        states.append(SiteControlLayerState(body.separatorLayer,keys: ["bounds","position","path"]))
        return states
    }
    public override func layout() {
        super.layout(); let m = SiteControlMetrics.self
        CATransaction.begin(); CATransaction.setDisableActions(true)
        favicon.frame = m.faviconFrame
        hostLabel.frame = CGRect(x: m.titleX, y: m.titleBaseline - hostLabel.font!.ascender, width: bounds.width - m.titleX - m.inset, height: hostLabel.intrinsicContentSize.height)
        let buttons = actions.filter { !$0.isHidden }
        let total = CGFloat(buttons.count) * m.actionButton.width + CGFloat(max(0, buttons.count - 1)) * m.actionGap
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(index) * (m.actionButton.width + m.actionGap), y: m.headerHeight + m.actionButtonInsetY, width: m.actionButton.width, height: m.actionButton.height)
        }
        scroll.frame = CGRect(x: 0, y: m.headerHeight + m.actionRowHeight, width: bounds.width, height: max(0, bounds.height - fixedHeight))
        scroll.isHidden = bodyHeight == 0
        let footerY = bounds.height - m.footerHeight + m.footerY
        security.frame = CGRect(x: m.footerInset, y: footerY, width: security.intrinsicContentSize.width, height: m.footerButton)
        more.frame = CGRect(x: bounds.width - m.footerInset - m.footerButton, y: footerY, width: m.footerButton, height: m.footerButton)
        updateRowVisibility(); updateSurfaceLayers(); CATransaction.commit()
    }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { updateSurfaceLayers() }
    private func updateSurfaceLayers() {
        let px = 1 / (window?.backingScaleFactor ?? 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shape = SiteControlShape.path(in: bounds, radius: SiteControlMetrics.cornerRadius)
        fillLayer.frame = bounds; edgeLayer.frame = bounds; edgeClip.frame = bounds
        surfaceClip.frame = bounds; surfaceClip.path = shape
        fillLayer.path = shape; fillLayer.fillColor = Core.popoverBackground.cgColor(contentAppearance)
        edgeClip.path = shape; edgeLayer.path = shape; edgeLayer.lineWidth = 2 * px; edgeLayer.strokeColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance)
        layer?.cornerRadius = 0
        let lines = CGMutablePath()
        for y in [SiteControlMetrics.headerHeight + SiteControlMetrics.actionRowHeight, bounds.height - SiteControlMetrics.footerHeight] {
            lines.move(to: CGPoint(x: SiteControlMetrics.separatorInset, y: y + px/2))
            lines.addLine(to: CGPoint(x: bounds.width - SiteControlMetrics.separatorInset, y: y + px/2))
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
    let separatorLayer = CAShapeLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; separatorLayer.fillColor = nil; layer?.addSublayer(separatorLayer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let path = CGMutablePath(), px = 1/(window?.backingScaleFactor ?? 1)
        for y in separators { path.move(to: CGPoint(x: SiteControlMetrics.separatorInset,y: y+px/2)); path.addLine(to: CGPoint(x: bounds.width-SiteControlMetrics.separatorInset,y: y+px/2)) }
        CATransaction.begin(); CATransaction.setDisableActions(true); separatorLayer.frame = bounds; separatorLayer.path = path; separatorLayer.lineWidth = px; separatorLayer.strokeColor = CommandBarColors.hairlineDivider.cgColor(contentAppearance); CATransaction.commit()
    }

}

@MainActor
private final class SiteControlBaselineLabel: NSView {
    let text: String; let font: NSFont
    override var isFlipped: Bool { true }
    init(text: String,font: NSFont) { self.text = text; self.font = font; super.init(frame: .zero); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { SiteControlDrawing.text(text,x: 0,baseline: 20,width: bounds.width,font: font,color: Core.foregroundSecondary.resolved(contentAppearance).nsColor) }
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

/// Capture the displayed geometry so successive live updates animate from what
/// is on screen, including a transition that is already in progress.
@MainActor
struct SiteControlLayerState {
    let layer: CALayer
    let values: [String: Any]
    init(_ layer: CALayer, keys: [String]) {
        self.layer = layer
        let displayed = layer.presentation() ?? layer
        values = keys.reduce(into: [:]) { result, key in result[key] = displayed.value(forKeyPath: key) }
    }
    func animate() {
        for (key, previous) in values {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = previous; animation.toValue = layer.value(forKeyPath: key)
            animation.duration = Motion.rowStructure; animation.timingFunction = Motion.easeInOut
            layer.add(animation, forKey: "rows." + key)
        }
    }
}
