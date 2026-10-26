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
    private var keyboardRing: CAShapeLayer?
    weak var representedItem: AnyObject?
    var isKeyboardFocused = false {
        didSet {
            guard isKeyboardFocused != oldValue else { return }
            if isKeyboardFocused, keyboardRing == nil {
                let ring = CAShapeLayer()
                ring.fillColor = nil
                ring.strokeColor = NSColor.keyboardFocusIndicatorColor.cgColor
                ring.lineWidth = 2
                layer?.addSublayer(ring)
                keyboardRing = ring
                needsLayout = true
            }
            keyboardRing?.isHidden = !isKeyboardFocused
        }
    }
    weak var page: SpacePageView?
    /// Rows without a fill (spacer, divider) never highlight.
    var allowsHighlight = true { didSet { if allowsHighlight != oldValue { updateFill(animated: false) } } }
    /// Leading inset of the fill for indented rows (folder children).
    var fillIndent: CGFloat = 0 { didSet { if fillIndent != oldValue { needsLayout = true } } }
    var isCurrent = false { didSet { if isCurrent != oldValue { updateFill(animated: true); notifyCell() } } }
    var isHovered = false { didSet { if isHovered != oldValue { updateFill(animated: true); notifyCell() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { updateFill(animated: true) } } }
    /// The row's Peek is on screen: the selected fill gives way to a lighter one (F0090).
    var isPeekSource = false { didSet { if isPeekSource != oldValue { updateFill(animated: true) } } }

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
        keyboardRing?.frame = bounds
        keyboardRing?.path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: m.rowFillCornerRadius,
                                  cornerHeight: m.rowFillCornerRadius, transform: nil)
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
        if allowsHighlight && isCurrent && isPeekSource {
            fill.backgroundColor = SidebarRole.peekSourceFill.cgColor(appearance)
            fill.shadowOpacity = 0
            fill.opacity = 1
        } else if allowsHighlight && isCurrent {
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

    override func isAccessibilityElement() -> Bool { itemID(of: representedItem) != nil || representedItem is NewTabItem }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        switch representedItem {
        case let tab as Tab: tab.displayTitle
        case let folder as Folder: folder.title
        case let split as Split: "Split View: " + split.panes.map(\.displayTitle).joined(separator: ", ")
        case is NewTabItem: "New Tab"
        default: nil
        }
    }
    override func isAccessibilityFocused() -> Bool { isKeyboardFocused }
    override func isAccessibilityExpanded() -> Bool { (representedItem as? Folder)?.isExpanded ?? false }
    override func accessibilityPerformPress() -> Bool {
        guard let representedItem else { return false }
        return page?.activate(item: representedItem) ?? false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedItem = nil
        isKeyboardFocused = false
        isHovered = false
        isCurrent = false
        isDropTarget = false
        isPeekSource = false
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
    private(set) var peekBadge: PeekBadgeView?
    private var slash: CALayer?
    weak var tab: Tab? { didSet { bind() } }

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Typography.tabTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        title.trailingInset = SpaceListMetrics.textTrailingInset
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
        b.accessibleTitle = { [weak self] in self?.showsUnload == true ? "Unload tab" : "Archive tab" }
        b.plateRadius = 6
        b.glyphTint = { _ in SidebarRole.rowAccessory.nsColor }
        b.plateColor = { _ in SidebarRole.rowPressed }
        b.action = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.context?.send(self.showsUnload ? .unloadTab(tab.id) : .close(nodeID: tab.id))
        }
        addSubview(b)
        accessory = b
        // A new button starts visible; place it now (and move a Peek badge out of its slot).
        needsLayout = true
        return b
    }

    private func makeAudio() -> PlateButton {
        if let audio { return audio }
        let b = PlateButton(glyph: .audioPlaying)
        b.accessibleTitle = { [weak self] in self?.tab?.isMuted == true ? "Unmute tab" : "Mute tab" }
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
        guard let tab, isPinned else { return false }
        return tab.live.hasWebContent
    }

    /// The close or unload button follows the pointer, not the selection: a
    /// selected Today row made by Cmd+T shows none (F0066); hovered rows do (F0013).
    private var showsAccessory: Bool { rowView?.isHovered ?? false }

    override func rowStateChanged() {
        let unload = tracked({ showsUnload }) { [weak self] in self?.needsLayout = true }
        let visible = showsAccessory
        guard visible || accessory != nil else { return }
        let b = makeAccessory()
        b.glyphView.glyph = unload ? .rowUnload : .rowClose
        if b.isHidden == visible {
            b.isHidden = !visible
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        SidebarDiagnostics.tabRowLayouts += 1
        rowStateChanged()
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
        // A pinned tab away from its pinned URL shows "/" before the title (A0414; measured F0090, F0101).
        if leftPinned || slash != nil {
            let line = slash ?? { let l = CALayer(); layer?.addSublayer(l); slash = l; return l }()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            line.isHidden = !leftPinned
            if leftPinned {
                line.bounds = CGRect(origin: .zero, size: m.pinnedSlashSize)
                line.position = CGPoint(x: titleX + m.pinnedSlashCenterX, y: m.pinnedSlashCenterY)
                line.backgroundColor = SidebarRole.pinnedSlash.cgColor(contentAppearance)
                line.setAffineTransform(CGAffineTransform(rotationAngle: m.pinnedSlashAngle))
                titleX += m.pinnedSlashTitleShift
            }
            CATransaction.commit()
        }
        var titleRight = (accessory?.isHidden ?? true) ? bounds.width - m.titleTrailingInset : accessory!.frame.minX
        // An open Peek marks its source row, also while another row is selected (F0090, F0101).
        // guess: the close button replaces the badge while the row is hovered.
        let badgeState = tab.flatMap { context?.peekBadgeState(for: $0.id) }
        let badgeShown = tracked({ badgeState?.isShown ?? false }) { [weak self] in self?.needsLayout = true }
        if let badgeState, badgeShown, accessory?.isHidden ?? true {
            let v = peekBadge ?? { let v = PeekBadgeView(); addSubview(v); peekBadge = v; return v }()
            v.isHidden = false
            v.state = badgeState
            v.frame = CGRect(x: bounds.width - m.peekBadgeTrailingInset, y: m.peekBadgeY, width: m.peekBadgeSize, height: m.peekBadgeSize)
            titleRight = v.frame.minX - 1
        } else {
            peekBadge?.isHidden = true
        }
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

/// Peek badge (F0090, F0101): the Peek page's favicon on a 24 pt plate at the
/// source row's right end. The plate is `TabCellChildBackground`, corner ≈ 6.
@MainActor
final class PeekBadgeView: NSView {
    /// Observed while drawing: a new Peek URL or favicon redraws only this view.
    weak var state: SidebarPeekBadgeState? { didSet { if state !== oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let badge = tracked({ state?.badge }, invalidate: { [weak self] in self?.needsDisplay = true }) else { return }
        SidebarDiagnostics.peekBadgeDraws += 1
        let r = SpaceListMetrics.peekBadgeCornerRadius
        SidebarRole.peekBadgePlate.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let inkSize = SpaceListMetrics.faviconInk
        let ink = backingAlignedRect(NSRect(x: (bounds.width - inkSize) / 2, y: (bounds.height - inkSize) / 2, width: inkSize, height: inkSize),
                                     options: .alignAllEdgesNearest)
        if let image = FaviconCache.image(for: badge.faviconPNG) {
            image.draw(in: ink, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let tint = SidebarRole.secondaryText.nsColor
        CustomIcon.letterFavicon(URL.displayHost(badge.url).first.map(String.init) ?? "·", size: inkSize,
                                 fill: tint.withAlphaComponent(0.25), text: tint)
            .draw(in: ink, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
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
        title.trailingInset = SpaceListMetrics.textTrailingInset
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
        let (open, override, legacy) = tracked({ (folder.isExpanded, folder.iconOverride, folder.customIcon) }) { [weak self] in self?.needsDisplay = true }
        let accent = cell?.page.map { $0.style.accentColor($0.contentAppearanceForSpace).nsColor } ?? Core.brandBlue.nsColor
        if let icon = override ?? NodeIconRenderer.legacy(legacy) {
            let size = SpaceListMetrics.faviconInk
            let ink = backingAlignedRect(CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                                               width: size, height: size), options: .alignAllEdgesNearest)
            NodeIconRenderer.draw(icon, in: ink, tint: accent)
            return
        }
        CustomIcon.folder(open: open, in: bounds.insetBy(dx: 1.5, dy: 2.5), color: accent)
    }
}

/// Split row: every pane's favicon and title in one row, with a thin vertical
/// divider between cells (F0079: icons x 33 / 129, titles x 61 / 157, 56 pt wide).
/// Selected, the row's fill is a card and each pane gets its own cell in it,
/// with no divider (F0081). Both cells look the same: Arc does not mark the
/// focused pane in the sidebar (F0081, focus on pane 2).
@MainActor
final class SplitCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("split")
    weak var split: Split? { didSet { paneIDs = []; needsLayout = true } }
    private var paneIDs: [ItemID] = []
    private var favicons: [FaviconView] = []
    private var titles: [TextLabel] = []
    private var dividers: [CALayer] = []
    private var cells: [CALayer] = []

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    override func rowStateChanged() { needsLayout = true }

    private func rebuild(_ panes: [Tab]) {
        favicons.forEach { $0.removeFromSuperview() }; titles.forEach { $0.removeFromSuperview() }
        (dividers + cells).forEach { $0.removeFromSuperlayer() }
        favicons = []; titles = []; dividers = []; cells = []
        for (i, pane) in panes.enumerated() {
            let c = CALayer(); c.cornerRadius = SpaceListMetrics.splitCellCornerRadius
            layer?.insertSublayer(c, at: 0); cells.append(c)
            let f = FaviconView(); f.tab = pane; f.context = context
            let t = TextLabel(); t.font = Typography.tabTitle.font; t.baseline = SpaceListMetrics.titleBaselineOffset; t.inset = SpaceListMetrics.textInset
            t.trailingInset = SpaceListMetrics.textTrailingInset
            t.text = { [weak pane] in pane?.displayTitle ?? "" }
            t.color = { [weak self] in
                guard let page = self?.page else { return .labelColor }
                return page.style.splitTitleColor(page.contentAppearanceForSpace).nsColor
            }
            addSubview(f); addSubview(t)
            favicons.append(f); titles.append(t)
            if i > 0 { let d = CALayer(); layer?.addSublayer(d); dividers.append(d) }
        }
        applyColors()
    }

    var visibleCellFrames: [CGRect] { cells.filter { !$0.isHidden }.map(\.frame) }
    var dividersVisible: Bool { dividers.contains { !$0.isHidden } }

    private func applyColors() {
        let appearance = contentAppearance
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dividers.forEach { $0.backgroundColor = SidebarRole.pinnedSlash.cgColor(appearance) }
        cells.forEach { $0.backgroundColor = SidebarRole.splitCellFill.cgColor(appearance) }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard let split else { return }
        let panes = tracked({ split.panes }) { [weak self] in self?.needsLayout = true }
        if panes.map(\.id) != paneIDs { paneIDs = panes.map(\.id); rebuild(panes) }
        guard !favicons.isEmpty else { return }
        let m = SpaceListMetrics.self
        let n = CGFloat(favicons.count)
        // Cell pitch = cell width + gap: (W − 16 − indent − 4) / n.
        let pitch = (bounds.width - 2 * m.rowFillInsetX - indent - m.splitCellGap) / n
        let x0 = m.faviconX + indent
        let cellX0 = m.rowFillInsetX + indent + m.splitCellInset
        let selected = rowView?.isCurrent ?? false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in favicons.indices {
            let x = x0 + CGFloat(i) * pitch
            favicons[i].frame = CGRect(x: x, y: m.faviconY, width: m.faviconSize, height: m.faviconSize)
            titles[i].frame = CGRect(x: x + 28, y: 0, width: max(0, pitch - 40), height: m.rowHeight)
            let left = (cellX0 + CGFloat(i) * pitch).rounded(), right = (cellX0 + CGFloat(i) * pitch + pitch - m.splitCellGap).rounded()
            cells[i].frame = CGRect(x: left, y: m.splitCellTop, width: right - left, height: m.splitCellHeight)
            cells[i].isHidden = !selected
            if i > 0 {
                dividers[i - 1].frame = CGRect(x: x - 10, y: 12, width: m.splitDividerWidth, height: 17)
                dividers[i - 1].isHidden = selected
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
        title.trailingInset = SpaceListMetrics.textTrailingInset
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
