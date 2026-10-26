import AppKit
import OpenDesign
import OpenModel

// MARK: - Sentinel outline items

/// Non-model rows. One instance per Space page, so outline item identity is stable.
@MainActor final class SpacerItem {}
@MainActor final class DividerItem {}
@MainActor final class NewTabItem {}

// MARK: - Row view (fill, hover, selection)

/// The row container. Draws the hover and selected fills as one layer; the cell
/// on top draws the content. NSTableView selection is not used: the current row
/// follows the model's selected node.
@MainActor
final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
    private let fill = CALayer()
    weak var page: SpacePageView?
    /// Rows without a fill (spacer, divider) never highlight.
    var allowsHighlight = true { didSet { if allowsHighlight != oldValue { updateFill(animated: false) } } }
    /// Leading inset of the fill for indented rows (folder children).
    var fillIndent: CGFloat = 0 { didSet { if fillIndent != oldValue { needsLayout = true } } }
    var isCurrent = false { didSet { if isCurrent != oldValue { updateFill(animated: true); notifyCell() } } }
    var isHovered = false { didSet { if isHovered != oldValue { updateFill(animated: true); notifyCell() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { updateFill(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
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
    override var isEmphasized: Bool { get { false } set {} }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = SpaceListMetrics.self
        let rect = CGRect(x: m.rowFillInsetX + fillIndent, y: m.rowFillInsetTop,
                          width: bounds.width - 2 * m.rowFillInsetX - fillIndent, height: m.rowFillHeight)
        fill.frame = rect
        fill.cornerRadius = m.rowFillCornerRadius
        fill.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: m.rowFillCornerRadius,
                                 cornerHeight: m.rowFillCornerRadius, transform: nil)
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
            let style = page?.style
            fill.backgroundColor = (style?.selectedFill(appearance) ?? SidebarRole.rowSelected.resolved(appearance)).cgColor
            SelectionShadow.apply(to: fill, appearance: appearance)
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

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isCurrent = false
        isDropTarget = false
        fillIndent = 0
    }
}

/// Selected-row and selected-tile shadow. Measured below a selected light row:
/// 14 % darker 1 px below the fill, 5.5 % at 2 px, 2 % at 3 px, 1 % 1 px above
/// (F0014). Fitted by the comparison loop (docs/design.md). Dark content: none.
enum SelectionShadow {
    static let radius: CGFloat = 1.5
    static let offsetY: CGFloat = 1

    @MainActor static func apply(to layer: CALayer, appearance: ContentAppearance) {
        let shadow = SidebarRole.rowSelectedShadow.resolved(appearance)
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Float(shadow.alpha)
        layer.shadowRadius = radius
        // Rows are flipped views: +y is down on screen.
        layer.shadowOffset = CGSize(width: 0, height: (layer.superlayer?.contentsAreFlipped() ?? true) ? offsetY : -offsetY)
    }
}

// MARK: - Cell views

@MainActor
class SidebarCellView: NSView {
    weak var page: SpacePageView?
    var depth = 0 { didSet { if depth != oldValue { needsLayout = true } } }
    var indent: CGFloat { CGFloat(depth) * SpaceListMetrics.indentPerLevel }
    var rowView: SidebarRowView? { superview as? SidebarRowView }
    var context: SidebarContext? { page?.context }

    required override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    func rowStateChanged() {}

    func titleColor() -> NSColor {
        guard let page else { return .labelColor }
        return page.style.titleColor(page.contentAppearanceForSpace).nsColor
    }

    /// Inline title editor (double-click or "Rename…").
    private var editor: NSTextField?
    func beginEditing(text: String, frame: NSRect, font: NSFont, commit: @escaping @MainActor (String) -> Void) {
        let field = RenameField(frame: frame)
        field.stringValue = text
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = titleColor()
        field.cell?.isScrollable = true
        field.onEnd = { [weak self, weak field] value in
            field?.removeFromSuperview()
            self?.editor = nil
            self?.subviews.forEach { if $0 is TextLabel { $0.isHidden = false } }
            if let value { commit(value) }
        }
        subviews.forEach { if $0 is TextLabel { $0.isHidden = true } }
        addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
}

/// Text field that reports commit (Return, focus loss) or cancel (Escape).
@MainActor
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onEnd: (@MainActor (String?) -> Void)?
    private var ended = false

    required override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(stringValue); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(stringValue) }

    private func finish(_ value: String?) {
        guard !ended else { return }
        ended = true
        onEnd?(value)
    }
}

/// Tab row: favicon, title, audio indicator, and the close (×) or unload (−) button.
@MainActor
final class TabCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("tab")
    let favicon = FaviconView()
    let title = TextLabel()
    /// Built on first use: most rows never show them, and every extra layer-backed
    /// subview costs time when a row scrolls into view.
    private var audio: PlateButton?
    private(set) var accessory: PlateButton?
    private var slash: CALayer?
    weak var tab: Tab? { didSet { bind() } }

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Typography.tabTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        addSubview(favicon); addSubview(title)
    }

    private func bind() {
        favicon.tab = tab
        favicon.context = context
        title.text = { [weak self] in self?.tab?.displayTitle ?? "" }
        title.color = { [weak self] in self?.titleColor() ?? .labelColor }
        rowStateChanged()
        needsLayout = true
    }

    private func makeAccessory() -> PlateButton {
        if let accessory { return accessory }
        let b = PlateButton(glyph: .rowClose)
        b.plateRadius = 6
        b.glyphTint = { _ in SidebarRole.rowAccessory.nsColor }
        b.plateColor = { _ in SidebarRole.rowPressed }
        b.action = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.context?.send(self.showsUnload ? .unload(tabID: tab.id) : .close(nodeID: tab.id))
        }
        addSubview(b)
        accessory = b
        return b
    }

    private func makeAudio() -> PlateButton {
        if let audio { return audio }
        let b = PlateButton(glyph: .audioPlaying)
        b.showsHoverPlate = false
        b.glyphTint = { _ in SidebarRole.rowAccessory.nsColor }
        b.action = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.context?.send(.toggleMute(tabID: tab.id))
        }
        addSubview(b)
        audio = b
        return b
    }

    var isPinned: Bool {
        guard let tab, let context else { return false }
        return context.model.isPinned(tabID: tab.id)
    }

    /// A loaded pinned tab shows "−" (close and keep pinned), measured on a
    /// selected pinned row (F0014). Today tabs show "×".
    private var showsUnload: Bool {
        guard let tab, let context, isPinned else { return false }
        return context.isTabLoaded(tab)
    }

    private var showsAccessory: Bool { (rowView?.isHovered ?? false) || (rowView?.isCurrent ?? false) }

    override func rowStateChanged() {
        let visible = showsAccessory
        guard visible || accessory != nil else { return }
        let b = makeAccessory()
        b.glyphView.glyph = showsUnload ? .rowUnload : .rowClose
        if b.isHidden == visible {
            b.isHidden = !visible
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let x0 = indent
        // Observation-tracked reads: audio and pinned-URL state.
        let (audible, muted, leftPinned) = tracked({ (tab?.live.isAudible ?? false, tab?.isMuted ?? false, tab?.hasLeftPinnedURL ?? false) }) {
            [weak self] in self?.needsLayout = true
        }
        favicon.frame = CGRect(x: m.faviconX + x0, y: m.faviconY, width: m.faviconSize, height: m.faviconSize)
        let a = m.accessorySize
        accessory?.frame = CGRect(x: bounds.width - m.accessoryTrailingInset - a, y: m.accessoryY, width: a, height: a)
        var titleX = m.titleX + x0
        // A pinned tab away from its pinned URL shows "/" before the title (A0414). guess: 4 pt shift.
        if leftPinned || slash != nil {
            let line = slash ?? { let l = CALayer(); layer?.addSublayer(l); slash = l; return l }()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            line.isHidden = !leftPinned
            if leftPinned {
                line.frame = CGRect(x: titleX - 2, y: 13, width: 1.2, height: 15)
                line.backgroundColor = SidebarRole.pinnedSlash.cgColor(contentAppearance)
                line.setAffineTransform(CGAffineTransform(rotationAngle: 0.3))
                titleX += 4
            }
            CATransaction.commit()
        }
        var titleRight = (accessory?.isHidden ?? true) ? bounds.width - m.titleTrailingInset : accessory!.frame.minX
        let showAudio = audible || muted
        audio?.isHidden = !showAudio
        if showAudio {
            let b = makeAudio()
            b.isHidden = false
            b.glyphView.glyph = muted ? .audioMuted : .audioPlaying
            let w: CGFloat = 20
            let titleW = min(title.textWidth, titleRight - titleX - w - 2)
            b.frame = CGRect(x: titleX + max(titleW, 0) + 2, y: 10, width: w, height: 20)
            titleRight = min(titleRight, b.frame.minX)
        }
        title.frame = CGRect(x: titleX, y: 0, width: max(0, titleRight - titleX), height: m.rowHeight)
    }

    func beginRename() {
        guard let tab else { return }
        let id = tab.id
        beginEditing(text: tab.displayTitle, frame: title.frame.insetBy(dx: -2, dy: 0).offsetBy(dx: 0, dy: 0).with(y: 10, height: 20),
                     font: title.font) { [weak self] value in self?.context?.send(.rename(nodeID: id, title: value)) }
    }
}

extension NSRect {
    func with(y: CGFloat, height: CGFloat) -> NSRect { NSRect(x: origin.x, y: y, width: width, height: height) }
}

/// Folder row: folder glyph (closed or open, Space accent), 14 Semibold title.
/// Children are indented 16 pt per level (F0072, F0079).
@MainActor
final class FolderCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("folder")
    let icon = FolderIconView()
    let title = TextLabel()
    weak var folder: Folder? { didSet { bind() } }

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Typography.folderTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        addSubview(icon); addSubview(title)
    }

    private func bind() {
        icon.folder = folder
        icon.cell = self
        title.text = { [weak self] in self?.folder?.title ?? "" }
        title.color = { [weak self] in self?.titleColor() ?? .labelColor }
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        icon.frame = CGRect(x: m.faviconX + indent - 1, y: m.faviconY - 1, width: m.faviconSize + 2, height: m.faviconSize + 2)
        title.frame = CGRect(x: m.titleX + indent, y: 0, width: max(0, bounds.width - m.titleTrailingInset - m.titleX - indent), height: m.rowHeight)
    }

    func beginRename() {
        guard let folder else { return }
        let id = folder.id
        beginEditing(text: folder.title, frame: title.frame.with(y: 10, height: 20), font: title.font) { [weak self] value in
            self?.context?.send(.rename(nodeID: id, title: value))
        }
    }
}

/// Our own folder art, drawn in code: a closed folder (filled) or an open folder
/// (back panel plus a skewed front), tinted with the Space accent.
@MainActor
final class FolderIconView: NSView {
    weak var folder: Folder? { didSet { needsDisplay = true } }
    weak var cell: SidebarCellView?

    required override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let folder else { return }
        let open = tracked({ folder.isExpanded }) { [weak self] in self?.needsDisplay = true }
        let accent = cell?.page.map { $0.style.accentColor($0.contentAppearanceForSpace).nsColor } ?? Core.brandBlue.nsColor
        CustomIcon.folder(open: open, in: bounds.insetBy(dx: 1.5, dy: 2.5), color: accent)
    }
}

/// Split row: every pane's favicon and title in one row, with a thin vertical
/// divider between cells (F0079: icons x 33 / 129, titles x 61 / 157, 56 pt wide).
@MainActor
final class SplitCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("split")
    weak var split: Split? { didSet { paneIDs = []; needsLayout = true } }
    private var paneIDs: [ItemID] = []
    private var favicons: [FaviconView] = []
    private var titles: [TextLabel] = []
    private var dividers: [CALayer] = []

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    private func rebuild(_ panes: [Tab]) {
        favicons.forEach { $0.removeFromSuperview() }; titles.forEach { $0.removeFromSuperview() }; dividers.forEach { $0.removeFromSuperlayer() }
        favicons = []; titles = []; dividers = []
        for (i, pane) in panes.enumerated() {
            let f = FaviconView(); f.tab = pane; f.context = context
            let t = TextLabel(); t.font = Typography.tabTitle.font; t.baseline = SpaceListMetrics.titleBaselineOffset; t.inset = SpaceListMetrics.textInset
            t.text = { [weak pane] in pane?.displayTitle ?? "" }
            t.color = { [weak self] in
                guard let page = self?.page else { return .labelColor }
                return page.style.splitTitleColor(page.contentAppearanceForSpace).nsColor
            }
            addSubview(f); addSubview(t)
            favicons.append(f); titles.append(t)
            if i > 0 { let d = CALayer(); layer?.addSublayer(d); dividers.append(d) }
        }
    }

    override func layout() {
        super.layout()
        guard let split else { return }
        let panes = tracked({ split.panes }) { [weak self] in self?.needsLayout = true }
        if panes.map(\.id) != paneIDs { paneIDs = panes.map(\.id); rebuild(panes) }
        guard !favicons.isEmpty else { return }
        let m = SpaceListMetrics.self
        let n = CGFloat(favicons.count)
        let pitch = (bounds.width - 2 * m.rowFillInsetX - indent - 4) / n
        let x0 = m.faviconX + indent
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in favicons.indices {
            let x = x0 + CGFloat(i) * pitch
            favicons[i].frame = CGRect(x: x, y: m.faviconY, width: m.faviconSize, height: m.faviconSize)
            titles[i].frame = CGRect(x: x + 28, y: 0, width: max(0, pitch - 40), height: m.rowHeight)
            if i > 0 {
                dividers[i - 1].frame = CGRect(x: x - 10, y: 12, width: m.splitDividerWidth, height: 17)
                dividers[i - 1].backgroundColor = SidebarRole.pinnedSlash.cgColor(contentAppearance)
            }
        }
        CATransaction.commit()
    }
}

/// "+ New Tab" row.
@MainActor
final class NewTabCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("newTab")
    let plus = GlyphView()
    let title = TextLabel()

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        plus.glyph = .newTabPlus
        title.font = Typography.newTab.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        title.text = { "New Tab" }
        rowStateChanged()
        addSubview(plus); addSubview(title)
    }

    /// While the Cmd+T command bar is open the row is current and its label and
    /// plus take the title color (F0063); otherwise they are secondary.
    override func rowStateChanged() {
        let current = rowView?.isCurrent ?? false
        plus.tint = { [weak self] in current ? (self?.titleColor() ?? .labelColor) : SidebarRole.newTabGlyph.nsColor }
        title.color = { [weak self] in current ? (self?.titleColor() ?? .labelColor) : SidebarRole.secondaryText.nsColor }
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        plus.frame = CGRect(x: m.faviconX, y: m.faviconY, width: m.faviconSize, height: m.faviconSize)
        title.frame = CGRect(x: m.titleX, y: 0, width: bounds.width - m.titleX - m.titleTrailingInset, height: m.rowHeight)
    }
}

/// Pinned/Today divider: a hairline, and "↓ Clear" while the pointer is near (F0041, F0066).
@MainActor
final class DividerCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("divider")
    private let line = CALayer()
    let clearLabel = TextLabel()
    let clearArrow = GlyphView()
    var showsClear = false { didSet { if showsClear != oldValue { needsLayout = true } } }
    private var pointerOnClear = false { didSet { if pointerOnClear != oldValue { clearLabel.needsDisplay = true; clearArrow.needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        layer?.addSublayer(line)
        clearLabel.font = Typography.clearLabel.font
        clearLabel.text = { "Clear" }
        clearLabel.baseline = SpaceListMetrics.clearLabelBaseline
        let color: @MainActor () -> NSColor = { [weak self] in
            ((self?.pointerOnClear ?? false) ? SidebarRole.dividerLabelHover : SidebarRole.dividerLabel).nsColor
        }
        clearLabel.color = color
        clearArrow.glyph = .clearArrow
        clearArrow.tint = color
        addSubview(clearLabel); addSubview(clearArrow)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        line.backgroundColor = SidebarRole.divider.cgColor(contentAppearance)
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let w = bounds.width
        clearLabel.isHidden = !showsClear
        clearArrow.isHidden = !showsClear
        clearArrow.frame = m.clearArrowFrame.offsetBy(dx: w, dy: 0)
        clearLabel.frame = CGRect(x: w + m.clearLabelX, y: 0, width: 29, height: bounds.height)
        let end = showsClear ? w + m.clearLineEnd : w - m.dividerLineInset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = CGRect(x: m.dividerLineInset, y: m.dividerLineY, width: max(0, end - m.dividerLineInset), height: 1)
        CATransaction.commit()
    }

    private var clearRect: NSRect { NSRect(x: bounds.width + SpaceListMetrics.clearArrowFrame.minX - 2, y: 0, width: 50, height: bounds.height) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { pointerOnClear = showsClear && clearRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerOnClear = false }
    override func mouseDown(with event: NSEvent) {
        guard showsClear, clearRect.contains(convert(event.locationInWindow, from: nil)), let page else { return }
        page.context.send(.clearToday(space: page.space.id))
    }
}
