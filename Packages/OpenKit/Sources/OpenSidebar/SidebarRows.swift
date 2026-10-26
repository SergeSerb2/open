import AppKit
import OpenDesign
import OpenModel

// MARK: - Sentinel outline items

/// Non-model rows. One instance per Space page, so outline item identity is stable.
@MainActor final class SpacerItem {}
@MainActor final class DividerItem {}
@MainActor final class NewTabItem {}

// MARK: - Row view (fill, hover, selection)

/// The row container. Draws the hover and selected fills as layers; the cell
/// view on top draws the content. NSTableView selection is not used: the
/// "current" row follows the model's selected node.
@MainActor
final class SidebarRowView: NSTableRowView {
    private let fill = CALayer()
    private var tracking: NSTrackingArea?
    var onHoverChange: ((Bool) -> Void)?

    /// The row shows the selected (current) fill.
    var isCurrent = false { didSet { if isCurrent != oldValue { updateFill(animated: true); notifyCell() } } }
    var isHovered = false { didSet { if isHovered != oldValue { updateFill(animated: true); notifyCell(); onHoverChange?(isHovered) } } }
    /// Rows without a fill (spacer, divider) never highlight.
    var allowsHighlight = true
    /// Drop target highlight while dragging into a folder.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { updateFill(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.cornerCurve = .continuous
        fill.opacity = 0
        layer?.addSublayer(fill)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = SpaceListMetrics.self
        fill.frame = CGRect(x: m.rowFillInsetX, y: m.rowFillInsetTop, width: bounds.width - 2 * m.rowFillInsetX, height: m.rowFillHeight)
        fill.cornerRadius = m.rowFillCornerRadius
        fill.shadowPath = CGPath(roundedRect: fill.bounds, cornerWidth: m.rowFillCornerRadius, cornerHeight: m.rowFillCornerRadius, transform: nil)
        CATransaction.commit()
    }

    override func updateLayer() { updateFill(animated: false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(animated: false)
    }

    private func notifyCell() {
        for case let cell as SidebarCellView in subviews { cell.rowStateChanged() }
    }

    func updateFill(animated: Bool) {
        let appearance = contentAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(isCurrent ? Motion.selectionFade : Motion.hoverFade)
        if allowsHighlight && isCurrent {
            fill.backgroundColor = SidebarRole.rowSelected.cgColor(appearance)
            let shadow = SidebarRole.rowSelectedShadow.resolved(appearance)
            fill.shadowColor = CGColor(gray: 0, alpha: 1)
            fill.shadowOpacity = Float(shadow.alpha)
            fill.shadowRadius = SelectionShadow.radius
            fill.shadowOffset = CGSize(width: 0, height: SelectionShadow.offsetY)
            fill.opacity = 1
        } else if allowsHighlight && (isHovered || isDropTarget) {
            fill.backgroundColor = (isDropTarget ? SidebarColors.itemHoveredBackground : SidebarRole.rowHover).cgColor(appearance)
            fill.shadowOpacity = 0
            fill.opacity = 1
        } else {
            fill.opacity = 0
            fill.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isCurrent = false
        isDropTarget = false
    }
}

/// Selected-row shadow. Measured: the fill's diff box reaches 1 pt above and
/// 3 pt below the 36 pt fill. Tuned by the comparison loop (docs/design.md).
enum SelectionShadow {
    static let radius: CGFloat = 1.5
    static let offsetY: CGFloat = 1
}

// MARK: - Cell views

@MainActor
class SidebarCellView: NSView {
    weak var context: SidebarContext?
    var depth = 0 { didSet { if depth != oldValue { needsLayout = true } } }
    var indent: CGFloat { CGFloat(depth) * SpaceListMetrics.indentPerLevel }
    var rowView: SidebarRowView? { superview as? SidebarRowView }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    func rowStateChanged() {}
}

/// Tab row: favicon, title, audio indicator, and the close (×) or unload (−) button.
@MainActor
final class TabCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("tab")
    let favicon = FaviconView()
    let title = TextLabel()
    let audio = GlyphView()
    let accessory = PlateButton(glyph: .rowClose)
    weak var tab: Tab? { didSet { bind() } }
    var isPinned = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Typography.tabTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        accessory.plateRadius = 6
        accessory.isHidden = true
        audio.isHidden = true
        accessory.glyphView.tint = { SidebarRole.rowAccessory.nsColor }
        addSubview(favicon); addSubview(title); addSubview(audio); addSubview(accessory)
    }

    private func bind() {
        favicon.tab = tab
        favicon.context = context
        title.text = { [weak self] in self?.tab?.displayTitle ?? "" }
        title.color = { [weak self] in self?.titleColor() ?? .labelColor }
        accessory.action = { [weak self] in
            guard let self, let tab = self.tab else { return }
            if self.showsUnload { self.context?.send(.unload(tabID: tab.id)) } else { self.context?.send(.close(nodeID: tab.id)) }
        }
        needsLayout = true
    }

    private func titleColor() -> NSColor {
        guard let context, let page = enclosingPage else { return .labelColor }
        return context.style(for: page.space).titleColor(page.contentAppearanceForSpace).nsColor
    }

    private var enclosingPage: SpacePageView? {
        var v = superview
        while let s = v { if let p = s as? SpacePageView { return p }; v = s.superview }
        return nil
    }

    private var showsUnload: Bool {
        guard isPinned, let tab, let context else { return false }
        return context.isTabLoaded(tab)
    }

    override func rowStateChanged() {
        let row = rowView
        let visible = (row?.isHovered ?? false)
        accessory.glyphView.glyph = showsUnload ? .rowUnload : .rowClose
        accessory.isHidden = !visible
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let x0 = indent
        favicon.frame = CGRect(x: m.faviconX + x0, y: m.faviconOffsetY, width: m.faviconSize, height: m.faviconSize)
        let trailing = bounds.width - m.titleTrailingInset
        let accessoryW = m.accessorySize
        accessory.frame = CGRect(x: bounds.width - m.rowFillInsetX - 6 - accessoryW, y: 20 - accessoryW / 2, width: accessoryW, height: accessoryW)
        // Observation-tracked reads: audio state comes from the live tab.
        let audible = tab?.live.isAudible ?? false
        let muted = tab?.isMuted ?? false
        let showAudio = audible || muted
        audio.isHidden = !showAudio
        audio.glyph = muted ? .audioMuted : .audioPlaying
        audio.tint = { SidebarRole.rowAccessory.nsColor }
        var titleRight = accessory.isHidden ? trailing : accessory.frame.minX - 4
        if showAudio {
            let w: CGFloat = 18
            let titleW = min(title.textWidth, titleRight - (m.titleX + x0) - w - 4)
            audio.frame = CGRect(x: m.titleX + x0 + max(titleW, 0) + 4, y: 11, width: w, height: 18)
            titleRight = min(titleRight, audio.frame.minX - 2)
        }
        title.frame = CGRect(x: m.titleX + x0, y: 0, width: max(0, titleRight - m.titleX - x0), height: m.rowHeight)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let tab, let page = enclosingPage, let menu = page.menu(forTab: tab, pinned: isPinned) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Folder row: folder icon (closed or open), title. Children are indented rows.
@MainActor
final class FolderCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("folder")
    let icon = FolderIconView()
    let title = TextLabel()
    weak var folder: Folder? { didSet { bind() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Typography.folderTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        addSubview(icon); addSubview(title)
    }

    private func bind() {
        icon.folder = folder
        icon.context = context
        title.text = { [weak self] in self?.folder?.title ?? "" }
        title.color = { [weak self] in self?.titleColor() ?? .labelColor }
    }

    private func titleColor() -> NSColor {
        var v = superview
        while let s = v { if let p = s as? SpacePageView, let c = context { return c.style(for: p.space).titleColor(p.contentAppearanceForSpace).nsColor }; v = s.superview }
        return .labelColor
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        icon.frame = CGRect(x: m.faviconX + indent - 1, y: m.faviconOffsetY - 1, width: m.faviconSize + 2, height: m.faviconSize + 2)
        title.frame = CGRect(x: m.titleX + indent, y: 0, width: max(0, bounds.width - m.titleTrailingInset - m.titleX - indent), height: m.rowHeight)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let folder, let page = enclosingPage(), let menu = page.menu(forFolder: folder) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func enclosingPage() -> SpacePageView? {
        var v = superview
        while let s = v { if let p = s as? SpacePageView { return p }; v = s.superview }
        return nil
    }
}

/// Our own folder art: a closed folder (filled) or an open folder (back panel
/// plus a skewed front). Tinted with the Space accent. Drawn in code.
@MainActor
final class FolderIconView: NSView {
    weak var folder: Folder? { didSet { needsDisplay = true } }
    weak var context: SidebarContext?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let folder else { return }
        let open = folder.isExpanded // observation-tracked
        let accent = accentColor()
        let r = bounds.insetBy(dx: 2, dy: 3)
        let back = NSBezierPath()
        let tabW = r.width * 0.38
        back.move(to: NSPoint(x: r.minX + 1.5, y: r.minY))
        back.line(to: NSPoint(x: r.minX + tabW - 1, y: r.minY))
        back.line(to: NSPoint(x: r.minX + tabW + 1.5, y: r.minY + 2.2))
        back.line(to: NSPoint(x: r.maxX - 1.5, y: r.minY + 2.2))
        back.curve(to: NSPoint(x: r.maxX, y: r.minY + 3.7), controlPoint1: NSPoint(x: r.maxX - 0.6, y: r.minY + 2.2), controlPoint2: NSPoint(x: r.maxX, y: r.minY + 2.8))
        back.line(to: NSPoint(x: r.maxX, y: r.maxY - 1.5))
        back.curve(to: NSPoint(x: r.maxX - 1.5, y: r.maxY), controlPoint1: NSPoint(x: r.maxX, y: r.maxY - 0.6), controlPoint2: NSPoint(x: r.maxX - 0.6, y: r.maxY))
        back.line(to: NSPoint(x: r.minX + 1.5, y: r.maxY))
        back.curve(to: NSPoint(x: r.minX, y: r.maxY - 1.5), controlPoint1: NSPoint(x: r.minX + 0.6, y: r.maxY), controlPoint2: NSPoint(x: r.minX, y: r.maxY - 0.6))
        back.line(to: NSPoint(x: r.minX, y: r.minY + 1.5))
        back.curve(to: NSPoint(x: r.minX + 1.5, y: r.minY), controlPoint1: NSPoint(x: r.minX, y: r.minY + 0.6), controlPoint2: NSPoint(x: r.minX + 0.6, y: r.minY))
        back.close()
        if open {
            accent.withAlphaComponent(0.55).setFill()
            back.fill()
            let front = NSBezierPath()
            let top = r.minY + r.height * 0.36
            front.move(to: NSPoint(x: r.minX + 2.5, y: top))
            front.line(to: NSPoint(x: r.maxX + 1, y: top))
            front.line(to: NSPoint(x: r.maxX - 2, y: r.maxY))
            front.line(to: NSPoint(x: r.minX, y: r.maxY))
            front.close()
            accent.setFill()
            front.fill()
        } else {
            accent.setFill()
            back.fill()
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSRect(x: r.minX, y: r.minY + 3.6, width: r.width, height: 0.8).fill()
        }
    }

    private func accentColor() -> NSColor {
        var v = superview
        while let s = v {
            if let p = s as? SpacePageView, let c = context, let palette = c.style(for: p.space).palette(for: p.contentAppearanceForSpace) {
                return palette.foregroundSecondary.nsColor
            }
            v = s.superview
        }
        return Core.brandBlue.nsColor
    }
}

/// Split row: favicons and titles of every pane in one row, separated by a slash.
@MainActor
final class SplitCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("split")
    weak var split: Split? { didSet { rebuild() } }
    private var favicons: [FaviconView] = []
    private var titles: [TextLabel] = []
    private var slashes: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    private func rebuild() {
        favicons.forEach { $0.removeFromSuperview() }; titles.forEach { $0.removeFromSuperview() }; slashes.forEach { $0.removeFromSuperlayer() }
        favicons = []; titles = []; slashes = []
        guard let split else { return }
        for (i, pane) in split.panes.enumerated() {
            let f = FaviconView(); f.tab = pane; f.context = context
            let t = TextLabel(); t.font = Typography.tabTitle.font; t.baseline = SpaceListMetrics.titleBaselineOffset
            t.text = { [weak pane] in pane?.displayTitle ?? "" }
            t.color = { [weak self] in self?.titleColor() ?? .labelColor }
            addSubview(f); addSubview(t)
            favicons.append(f); titles.append(t)
            if i > 0 {
                let s = CALayer(); layer?.addSublayer(s); slashes.append(s)
            }
        }
        needsLayout = true
    }

    private func titleColor() -> NSColor {
        var v = superview
        while let s = v { if let p = s as? SpacePageView, let c = context { return c.style(for: p.space).titleColor(p.contentAppearanceForSpace).nsColor }; v = s.superview }
        return .labelColor
    }

    override func layout() {
        super.layout()
        guard !favicons.isEmpty else { return }
        let m = SpaceListMetrics.self
        let left = m.faviconX + indent, right = bounds.width - m.titleTrailingInset
        let gap: CGFloat = 14
        let each = (right - left - gap * CGFloat(favicons.count - 1)) / CGFloat(favicons.count)
        let slashColor = SidebarColors.tabSlash.cgColor(contentAppearance)
        for i in favicons.indices {
            let x = left + CGFloat(i) * (each + gap)
            favicons[i].frame = CGRect(x: x, y: m.faviconOffsetY, width: m.faviconSize, height: m.faviconSize)
            titles[i].frame = CGRect(x: x + m.faviconSize + 8, y: 0, width: max(0, each - m.faviconSize - 8), height: m.rowHeight)
            if i > 0 {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                slashes[i - 1].frame = CGRect(x: x - gap / 2 - 0.5, y: 12, width: 1, height: 16)
                slashes[i - 1].backgroundColor = slashColor
                slashes[i - 1].setAffineTransform(CGAffineTransform(rotationAngle: 0.26))
                CATransaction.commit()
            }
        }
    }
}

/// "+ New Tab" row.
@MainActor
final class NewTabCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("newTab")
    let plus = GlyphView()
    let title = TextLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        plus.glyph = .newTabPlus
        plus.tint = { SidebarRole.secondaryText.nsColor }
        title.font = Typography.newTab.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.text = { "New Tab" }
        title.color = { SidebarRole.secondaryText.nsColor }
        addSubview(plus); addSubview(title)
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        plus.frame = CGRect(x: m.faviconX, y: m.faviconOffsetY, width: m.faviconSize, height: m.faviconSize)
        title.frame = CGRect(x: m.titleX, y: 0, width: bounds.width - m.titleX - m.titleTrailingInset, height: m.rowHeight)
    }
}

/// Pinned/Today divider: a hairline and the "Clear" control.
@MainActor
final class DividerCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("divider")
    private let line = CALayer()
    let clear = TextLabel()
    var onClear: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hoverClear = false { didSet { needsDisplay = true; clear.needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        layer?.addSublayer(line)
        clear.font = Typography.dividerLabel.font
        clear.text = { "Clear" }
        clear.alignment = .right
        clear.color = { [weak self] in
            (self?.hoverClear == true ? SidebarColors.foregroundDarker : SidebarRole.dividerLabel).nsColor
        }
        addSubview(clear)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        line.backgroundColor = SidebarRole.divider.cgColor(contentAppearance)
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let labelW = clear.textWidth
        let labelRight = bounds.width - m.dividerLabelTrailingInset
        clear.frame = CGRect(x: labelRight - labelW - 2, y: 0, width: labelW + 2, height: bounds.height)
        clear.baseline = DividerMetrics.labelBaseline
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = CGRect(x: m.dividerLineX, y: DividerMetrics.lineY, width: max(0, clear.frame.minX - DividerMetrics.lineToLabelGap - m.dividerLineX), height: 1)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        hoverClear = clear.frame.insetBy(dx: -4, dy: 0).contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { hoverClear = false }
    override func mouseDown(with event: NSEvent) {
        if clear.frame.insetBy(dx: -4, dy: 0).contains(convert(event.locationInWindow, from: nil)) { onClear?() }
    }
}

/// Divider geometry inside its row. Measured from the Today capture; refined by the loop.
enum DividerMetrics {
    static let lineY: CGFloat = 15
    static let labelBaseline: CGFloat = 20
    static let lineToLabelGap: CGFloat = 10
}
