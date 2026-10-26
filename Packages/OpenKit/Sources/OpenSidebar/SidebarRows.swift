import AppKit
import Symbols
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
    private var animatesSelectionChange = false
    private var keyboardRing: CAShapeLayer?
    private var selectionState: SidebarRowSelectionState?
    weak var representedItem: AnyObject? {
        didSet { if representedItem !== oldValue { selectionState = nil; needsDisplay = true } }
    }
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
        fill.name = "sidebar-row-fill"
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

    override func updateLayer() {
        let animated = animatesSelectionChange
        animatesSelectionChange = false
        updateFill(animated: animated)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(animated: false)
    }

    private func notifyCell() {
        for case let cell as SidebarCellView in subviews { cell.rowStateChanged() }
    }

    func updateFill(animated: Bool) {
        let appearance = contentAppearance
        let multiselected = tracked({
            guard let id = itemID(of: representedItem), let selection = page?.context.selection else { return false }
            let state = selection.rowState(for: id)
            selectionState = state
            return state.isSelected
        }) { [weak self] in
            self?.animatesSelectionChange = true
            self?.needsDisplay = true
        }
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
        } else if allowsHighlight && multiselected {
            fill.backgroundColor = SidebarRole.rowMultiselected.cgColor(appearance)
            fill.shadowOpacity = 0
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
    override func isAccessibilitySelected() -> Bool {
        guard let id = itemID(of: representedItem) else { return false }
        return page?.context.selection.contains(id) ?? false
    }
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
        animatesSelectionChange = false
        alphaValue = 1
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
    private var audio: RowSpeakerButton?
    private var recording: RowRecordingView?
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

    private func makeAudio() -> RowSpeakerButton {
        if let audio { return audio }
        let b = RowSpeakerButton(glyph: .audioPlaying)
        b.accessibleTitle = { [weak self] in self?.tab?.isMuted == true ? "Unmute tab" : "Mute tab" }
        b.tooltip = { [weak self] in
            guard let self, let context = self.context, let space = context.focusedSpace else { return nil }
            return Tooltip(title: self.tab?.isMuted == true ? "Unmute tab" : "Mute tab", placement: .beside, style: context.style(for: space))
        }
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
        // Load the weak tab once; observation is scoped to the fields this row draws.
        let currentTab = tab
        let (audible, muted, leftPinned, capturing) = tracked({
            guard let currentTab else { return (false, false, false, false) }
            let live = currentTab.live
            return (live.isAudible, currentTab.isMuted, currentTab.hasLeftPinnedURL, live.isCapturing)
        }) { [weak self] in self?.needsLayout = true }
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
        titleRight = layoutMediaAccessories(audible: audible, muted: muted, capturing: capturing, titleX: titleX, titleRight: titleRight)
        title.frame = CGRect(x: titleX, y: 0, width: max(0, titleRight - titleX), height: m.rowHeight)
    }

    /// One placement point for the recording dot; S9 may move it to the leading side.
    /// Under pressure, reserve the speaker first and omit the recording dot (lead D9).
    private func layoutMediaAccessories(audible: Bool, muted: Bool, capturing: Bool, titleX: CGFloat, titleRight: CGFloat) -> CGFloat {
        let m = RowMediaMetrics.self, showAudio = audible || muted
        if !showAudio && !capturing && audio == nil && recording == nil { return titleRight }
        audio?.isHidden = !showAudio
        if !showAudio { audio?.update(tabID: tab?.id, muted: muted, animate: false) }
        let available = max(0, titleRight - titleX - m.gapAfterTitle)
        let audioWidth = showAudio ? m.buttonSize : 0
        let showRecording = capturing && (!showAudio || available >= audioWidth + m.recordingSlotWidth)
        recording?.isHidden = !showRecording
        let width = audioWidth + (showRecording ? m.recordingSlotWidth : 0)
        guard width > 0 else { return titleRight }
        let textWidth = min(title.textWidth, max(0, available - width))
        var x = min(titleX + textWidth + m.gapAfterTitle, titleRight - width)
        let right = min(titleRight, x)
        if showRecording {
            let view = recording ?? { let view = RowRecordingView(frame: .zero); addSubview(view); recording = view; return view }()
            view.context = context; view.isHidden = false
            view.frame = CGRect(x: x, y: m.y, width: m.recordingSlotWidth, height: m.buttonSize)
            x += m.recordingSlotWidth
        }
        if showAudio {
            let button = makeAudio(); button.isHidden = false; button.context = context
            button.update(tabID: tab?.id, muted: muted)
            button.frame = CGRect(x: x, y: m.y, width: m.buttonSize, height: m.buttonSize)
        }
        return right
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
        let open = tracked({ folder.isExpanded }) { [weak self] in self?.needsDisplay = true }
        let accent = cell?.page.map { $0.style.accentColor($0.contentAppearanceForSpace).nsColor } ?? Core.brandBlue.nsColor
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
    var showsClear = false {
        didSet {
            if showsClear != oldValue { needsLayout = true }
            if !showsClear { lastPointerLocation = nil; TooltipController.shared.cancel(for: self) }
        }
    }
    private var pointerOnClear = false { didSet { if pointerOnClear != oldValue { clearLabel.needsDisplay = true; clearArrow.needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var lastPointerLocation: NSPoint?
    var clearTitle: String { context?.isOptionHeld == true ? "Clear unselected" : "Clear" }
    var clearTooltipTitle: String { context?.isOptionHeld == true ? "Clear unselected Today tabs" : "Clear Today tabs" }

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        layer?.addSublayer(line)
        clearLabel.font = Typography.clearLabel.font
        clearLabel.text = { [weak self] in self?.clearTitle ?? "Clear" }
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
        let option = tracked({ context?.isOptionHeld ?? false }) { [weak self] in self?.needsLayout = true }
        let extra = option ? max(0, clearLabel.textWidth - 29) : 0
        clearLabel.isHidden = !showsClear
        clearArrow.isHidden = !showsClear
        clearArrow.frame = m.clearArrowFrame.offsetBy(dx: w - extra, dy: 0)
        clearLabel.frame = CGRect(x: w + m.clearLabelX - extra, y: 0, width: 29 + extra, height: bounds.height)
        let end = showsClear ? w + m.clearLineEnd - extra : w - m.dividerLineInset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = CGRect(x: m.dividerLineInset, y: m.dividerLineY, width: max(0, end - m.dividerLineInset), height: 1)
        CATransaction.commit()
        if let point = lastPointerLocation { trackPointer(at: point) }
    }

    private var clearRect: NSRect { clearArrow.frame.union(clearLabel.frame).insetBy(dx: -2, dy: 0) }

    func trackPointer(at point: NSPoint) {
        lastPointerLocation = point
        pointerOnClear = showsClear && clearRect.contains(point)
        if pointerOnClear, let page {
            TooltipController.shared.schedule(Tooltip(title: clearTooltipTitle, keys: ["⇧", "⌘", "K"], style: page.style), for: self)
        } else { TooltipController.shared.cancel(for: self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        context?.isOptionHeld = event.modifierFlags.contains(.option)
        trackPointer(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        lastPointerLocation = nil
        pointerOnClear = false
        TooltipController.shared.cancel(for: self)
    }
    override func mouseDown(with event: NSEvent) {
        guard showsClear, clearRect.contains(convert(event.locationInWindow, from: nil)), let page else { return }
        page.context.isOptionHeld = event.modifierFlags.contains(.option)
        if event.modifierFlags.contains(.option) {
            var keep = Set(page.context.selection.ids)
            if let current = page.context.selectedID(in: page.space.id) { keep.insert(current) }
            page.context.send(.clearTodayKeeping(space: page.space.id, keep: keep))
        } else { page.context.send(.clearToday(space: page.space.id)) }
    }
}


extension SidebarDiagnostics {
    public static var mediaReduceMotionOverride: Bool?
    public static var mediaReducesMotion: Bool { mediaReduceMotionOverride ?? RowMediaAccessibility.shared.reduceMotion }
}

/// One settings read per accessibility change, not per visible row layout. No timer.
@MainActor private final class RowMediaAccessibility {
    static let shared = RowMediaAccessibility()
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var observer: NSObjectProtocol?
    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            }
    }
    isolated deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

@MainActor private final class RowSpeakerImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class RowStaticSpeakerView: NSView {
    var glyph: Glyph = .audioPlaying { didSet { if glyph != oldValue { needsDisplay = true } } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay; identifier = NSUserInterfaceItemIdentifier("media.speakerGlyph") }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = glyph.image else { return }
        image.drawTinted(in: CGRect(x: RowMediaMetrics.glyphInsetX, y: (bounds.height - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height), color: SidebarRole.rowAccessory.nsColor)
    }
}

/// System slash/wave replacement, anchored at the same left edge in both states (lead D1).
@MainActor private final class RowSpeakerButton: PlateButton {
    private var symbol: RowSpeakerImageView?
    private var staticGlyph: RowStaticSpeakerView?
    private var representedID: ItemID?
    private var lastMuted: Bool?
    private var lastReduceMotion: Bool?
    override init(glyph: Glyph?) { super.init(glyph: glyph); glyphView.removeFromSuperview() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fixed = CGRect(x: RowMediaMetrics.glyphInsetX, y: 0, width: max(0, bounds.width - RowMediaMetrics.glyphInsetX), height: bounds.height)
        if symbol?.frame != fixed { symbol?.frame = fixed }
        staticGlyph?.frame = bounds
        CATransaction.commit()
    }
    func update(tabID: ItemID?, muted: Bool, animate: Bool = true) {
        let reduceMotion = SidebarDiagnostics.mediaReducesMotion
        if representedID == tabID && lastMuted == muted && lastReduceMotion == reduceMotion {
            if !animate { removeAnimations(symbol?.layer) }
            return
        }
        let glyph: Glyph = muted ? .audioMuted : .audioPlaying
        guard let image = glyph.image else { return }
        let changed = representedID == tabID && lastMuted != nil && lastMuted != muted
        let needsImage = lastMuted != muted || representedID != tabID
        if reduceMotion {
            symbol?.removeFromSuperview(); symbol = nil
            let view = staticGlyph ?? { let view = RowStaticSpeakerView(frame: bounds); addSubview(view); staticGlyph = view; return view }()
            view.glyph = glyph
        } else {
            staticGlyph?.removeFromSuperview(); staticGlyph = nil
            let view: RowSpeakerImageView
            let created: Bool
            if let symbol { view = symbol; created = false }
            else {
                view = RowSpeakerImageView(frame: bounds)
                view.wantsLayer = true; view.imageScaling = .scaleNone; view.imageAlignment = .alignLeft
                view.identifier = NSUserInterfaceItemIdentifier("media.speakerGlyph")
                addSubview(view); symbol = view; created = true
            }
            view.contentTintColor = SidebarRole.rowAccessory.nsColor
            if changed && animate && !isHiddenOrHasHiddenAncestor && (window?.isVisible == true || SidebarDiagnostics.forceAnimations) {
                view.setSymbolImage(image, contentTransition: .replace.magic(fallback: .replace))
                // Lead clarification, 2026-10-26: the unwrapped native call changes the
                // symbol but starts no effect in the real offscreen harness. Use a finite
                // cross-fade only when no native symbol-effect animation is present.
                if !hasSymbolAnimation(view.layer) {
                    let fade = CATransition(); fade.type = .fade; fade.duration = Motion.rowMediaFallback
                    fade.setValue(true, forKey: "openMediaFallback")
                    view.layer?.add(fade, forKey: "media.symbolFallback")
                }
            } else if needsImage || created {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                view.image = image
                CATransaction.commit()
            }
            if !animate { removeAnimations(view.layer) }
        }
        representedID = tabID; lastMuted = muted; lastReduceMotion = reduceMotion; needsLayout = true
    }
    private func hasSymbolAnimation(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if (layer.animationKeys() ?? []).contains(where: {
            $0 != "position" && $0 != "bounds" && layer.animation(forKey: $0)?.value(forKey: "openMediaFallback") as? Bool != true
        }) { return true }
        return (layer.sublayers ?? []).contains { hasSymbolAnimation($0) }
    }
    private func removeAnimations(_ layer: CALayer?) {
        layer?.removeAllAnimations(); layer?.sublayers?.forEach { removeAnimations($0) }
    }
    override func accessibilityHelp() -> String? { accessibleTitle?() }
}

/// Lazy, static recording indicator (PP-19). Its tooltip is an exact Arc string.
@MainActor private final class RowRecordingView: NSView {
    static let label = "This tab is using your camera or microphone"
    weak var context: SidebarContext?
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SidebarRole.recordingIndicator.nsColor.setFill()
        let size = RowMediaMetrics.recordingDot
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard let context, let space = context.focusedSpace else { return }
        TooltipController.shared.schedule(Tooltip(title: Self.label, placement: .beside, style: context.style(for: space)), for: self)
    }
    override func mouseExited(with event: NSEvent) { TooltipController.shared.cancel(for: self) }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { Self.label }
    override func accessibilityHelp() -> String? { Self.label }
}
