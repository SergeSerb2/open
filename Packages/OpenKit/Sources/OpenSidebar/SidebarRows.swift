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
    private var fillNeedsUpdate = true
    private var laidOutFillBounds: CGRect?
    private var laidOutFillIndent: CGFloat = -1
    private var keyboardRing: CAShapeLayer?
    private var selectionState: SidebarRowSelectionState?
    weak var representedItem: AnyObject? {
        didSet { if representedItem !== oldValue { selectionState = nil; invalidateFill() } }
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
                laidOutFillBounds = nil
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
        SidebarDiagnostics.countFolderWork("row-allocations")
        wantsLayer = true
        fill.name = "sidebar-row-fill"
        fill.cornerCurve = .continuous
        fill.opacity = 0
        layer?.addSublayer(fill)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            // AppKit invalidates every available row when child rows move. This
            // container has no raster background; fill/ring geometry is managed
            // by layers. Only our content/selection observation dirties its ink.
            if newValue, !fillNeedsUpdate {
                SidebarDiagnostics.countFolderWork("clean-row-invalidations-skipped")
                SidebarDiagnostics.traceFolderView(self, "clean native invalidation skipped")
                return
            }
            if newValue { SidebarDiagnostics.traceFolderView(self, "needsDisplay") }
            super.needsDisplay = newValue
        }
    }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }

    override func layout() {
        super.layout()
        SidebarDiagnostics.countFolderWork("row-layouts")
        SidebarDiagnostics.traceFolderView(self, "layout")
        // Native row moves schedule layout on every available row. Its fill
        // geometry depends on bounds/indent, not the row's position in the list.
        guard laidOutFillBounds != bounds || laidOutFillIndent != fillIndent else { return }
        laidOutFillBounds = bounds; laidOutFillIndent = fillIndent
        SidebarDiagnostics.countFolderWork("row-layer-geometry-updates")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = SpaceListMetrics.self
        let rect = CGRect(x: m.rowFillInsetX + fillIndent, y: m.rowFillInsetTop,
                          width: bounds.width - 2 * m.rowFillInsetX - fillIndent, height: m.rowFillHeight)
        keyboardRing?.frame = bounds
        keyboardRing?.path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: m.rowFillCornerRadius,
                                  cornerHeight: m.rowFillCornerRadius, transform: nil)
        fill.frame = rect
        if !developerOutline.isEmpty { updateDeveloperOutline() }
        fill.cornerRadius = m.rowFillCornerRadius
        fill.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: m.rowFillCornerRadius,
                                 cornerHeight: m.rowFillCornerRadius, transform: nil)
        CATransaction.commit()
    }

    private func invalidateFill() { fillNeedsUpdate = true; needsDisplay = true }

    override func updateLayer() {
        SidebarDiagnostics.traceFolderView(self, "updateLayer")
        fillNeedsUpdate = false
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
            self?.invalidateFill()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || page?.context.animatesChanges == false)
        CATransaction.setAnimationDuration(isCurrent ? Motion.selectionFade : Motion.hoverFade)
        if allowsHighlight && isCurrent && isPeekSource {
            fill.backgroundColor = SidebarRole.peekSourceFill.cgColor(appearance)
            fill.shadowOpacity = 0
            fill.opacity = 1
        } else if allowsHighlight && isCurrent {
            let style = page?.style
            fill.backgroundColor = (page?.roles.activePlate ?? style?.selectedFill(appearance) ?? SidebarRole.rowSelected.resolved(appearance)).cgColor
            SelectionShadow.apply(to: fill, appearance: appearance)
            fill.opacity = 1
        } else if allowsHighlight && multiselected {
            fill.backgroundColor = SidebarRole.rowMultiselected.cgColor(appearance)
            fill.shadowOpacity = 0
            fill.opacity = 1
        } else if allowsHighlight && (isHovered || isDropTarget) {
            fill.backgroundColor = isDropTarget ? SidebarColors.itemHoveredBackground.cgColor(appearance)
                : (page?.roles.rowHover ?? SidebarRole.rowHover.resolved(appearance)).cgColor
            fill.shadowOpacity = 0
            fill.opacity = 1
        } else {
            fill.opacity = 0
            fill.shadowOpacity = 0
        }
        updateDeveloperOutline()
        CATransaction.commit()
    }

    /// Developer Mode (PB3 row 5): a yellow-black dashed outline around the current row of a Developer Mode site.
    /// Capture s3 `s7/12-devoff/d-devmode-on`: 2 pt line on the active plate, 7 pt #F8D849 dashes over a
    /// 7 pt #322B0F ground (measured at 2x).
    private var developerOutline: [CAShapeLayer] = []
    private func updateDeveloperOutline() {
        let shown = allowsHighlight && isCurrent && tracked({ [weak self] () -> Bool in
            guard let self, let tab = self.representedItem as? Tab, let context = self.page?.context else { return false }
            return SidebarDeveloperMode.key(tab.url).map { context.developerModeHosts.contains($0) } ?? false
        }) { [weak self] in self?.invalidateFill() }
        if !shown { for ring in developerOutline { ring.isHidden = true }; return }
        if developerOutline.isEmpty {
            for (color, dash) in [(NSColor(srgbRed: 0x32 / 255, green: 0x2B / 255, blue: 0x0F / 255, alpha: 1), nil as [NSNumber]?),
                                  (NSColor(srgbRed: 0xF8 / 255, green: 0xD8 / 255, blue: 0x49 / 255, alpha: 1), [7, 7] as [NSNumber]?)] {
                let ring = CAShapeLayer(); ring.name = "developer-outline"; ring.fillColor = nil; ring.lineWidth = 2
                ring.strokeColor = color.cgColor; ring.lineDashPattern = dash; ring.zPosition = 5
                layer?.addSublayer(ring); developerOutline.append(ring)
            }
        }
        let m = SpaceListMetrics.self
        let rect = CGRect(x: m.rowFillInsetX + fillIndent, y: m.rowFillInsetTop,
                          width: bounds.width - 2 * m.rowFillInsetX - fillIndent, height: m.rowFillHeight)
        let path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: m.rowFillCornerRadius - 1,
                          cornerHeight: m.rowFillCornerRadius - 1, transform: nil)
        for ring in developerOutline { ring.frame = bounds; ring.path = path; ring.isHidden = false }
    }
    var showsDeveloperOutline: Bool { developerOutline.first.map { !$0.isHidden } ?? false }

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
    // Preserve AXSelected for attribute-based accessibility clients as well as
    // the modern NSAccessibility protocol used above.
    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute == .selected { return MainActor.assumeIsolated { isAccessibilitySelected() } }
        if attribute == .value { return MainActor.assumeIsolated { accessibilityValue() as? String } }
        if attribute == .expanded { return MainActor.assumeIsolated { isAccessibilityExpanded() } }
        return super.accessibilityAttributeValue(attribute)
    }
    override func accessibilityValue() -> Any? {
        (representedItem as? Folder)?.peekedChildID != nil ? "1 tab shown" : nil
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

/// A lazy unread layer: no layer is allocated for the usual read row.
@MainActor
private final class SidebarUnreadDot {
    let layer = CALayer()
    var frame: CGRect { layer.frame }
    private var shown = false
    init(host: NSView) {
        layer.name = "sidebar-unread-dot"
        layer.opacity = 0
        host.layer?.addSublayer(layer)
    }
    func update(shown: Bool, cell: SidebarCellView) {
        let m = SpaceListMetrics.self
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: cell.bounds.width - m.unreadDotTrailingCenter - m.unreadDotSize / 2,
                             y: m.unreadDotCenterY - m.unreadDotSize / 2, width: m.unreadDotSize, height: m.unreadDotSize)
        layer.cornerRadius = m.unreadDotSize / 2
        let color = tracked({ cell.page.map { SidebarRole.unreadDot(style: $0.style, appearance: cell.contentAppearance).cgColor } }) {
            [weak cell] in cell?.needsLayout = true
        }
        layer.backgroundColor = color
        layer.opacity = shown ? 1 : 0
        CATransaction.commit()
        guard shown != self.shown else { return }
        self.shown = shown
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced { layer.removeAnimation(forKey: "unread-in"); layer.removeAnimation(forKey: "unread-out") }
        if shown && !reduced {
            let spring = Motion.unreadAppear.animation(keyPath: "transform.scale")
            spring.fromValue = 0; spring.toValue = 1
            layer.add(spring, forKey: "unread-in")
        } else if !shown && !reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = Motion.unreadClearFade
            layer.add(fade, forKey: "unread-out")
        }
    }
}

@MainActor
private enum SidebarResetImages {
    private static let reset = make("arrow.uturn.backward")
    private static let separate = make("arrow.up.forward")
    static func image(separate: Bool) -> NSImage? { separate ? self.separate : reset }
    private static func make(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }
}

@MainActor
private final class SidebarResetButton: PlateButton {
    override func mouseDown(with event: NSEvent) {
        context?.isOptionHeld = event.modifierFlags.contains(.option)
        super.mouseDown(with: event)
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
        let color = page.roles.title.nsColor
        return page.context.titleColorTransform?(color) ?? color
    }

    /// Inline title editor (double-click or "Rename…").
    private var editor: NSTextField?
    func beginEditing(text: String, frame: NSRect, font: NSFont, commit: @escaping @MainActor (String) -> Void) {
        page?.context.suppressPreviews(.rename, true)
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
            self?.page?.context.suppressPreviews(.rename, false)
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
    private var unread: SidebarUnreadDot?
    private(set) var resetButton: PlateButton?
    /// Developer Mode (PB3 row 5): "host:port" under the title; the title moves up 7 pt (capture s3: title at
    /// y + 3.5 instead of y + 10.5, a 16 pt subtitle line; baselines measured 13.5 pt apart at 2x).
    private(set) var hostSubtitle: TextLabel?
    private var faviconHovered = false
    private var resetShown = false
    private var resetSeparate = false
    weak var tab: Tab? { didSet { if tab !== oldValue { faviconHovered = false }; bind() } }

    required init(frame: NSRect) {
        super.init(frame: frame)
        // Keep title/favicon backing contexts independent: flattening changes
        // Core Text edge pixels in the frozen schema-1 window fixtures.
        identifier = Self.identifier
        title.font = Typography.tabTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        title.trailingInset = SpaceListMetrics.textTrailingInset
        addSubview(favicon); addSubview(title)
    }

    override func prepareForReuse() {
        super.prepareForReuse(); faviconHovered = false; tab = nil
    }

    private func bind() {
        favicon.tab = tab
        favicon.context = context
        if let font = context?.titleFontOverride { title.font = font }
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
            // Arc's exact tooltip keys (TabCellState lazy globals, small-string immediates at
            // 0x1002b4f24 / 0x1002b4fd8, shown as is: the bundle has no Localizable table;
            // docs/re/features-advanced.md §8 PP-23). The AX label stays "Mute tab"/"Unmute tab".
            return Tooltip(title: self.tab?.isMuted == true ? "Unmute this tab" : "Mute this tab", placement: .beside, style: context.style(for: space))
        }
        b.setAccessibilityIdentifier("sidebarTabCellMuteButton")  // Arc's AX id (S2 12/0022)
        // guess: the hover plate copies the close button (plate = button frame, radius 6,
        // the row's pressed tone); the synthetic pointer showed no hover in S2 12.
        b.plateRadius = 6
        b.plateColor = { _ in SidebarRole.rowPressed }
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

    @discardableResult
    func trackFavicon(at point: NSPoint) -> Bool {
        let over = SpaceListMetrics.resetGlyphPlate(indent: indent).contains(point)
        if faviconHovered != over { faviconHovered = over; needsLayout = true }
        let eligible = over && tab?.hasLeftPinnedURL == true && isPinned
        if eligible { scheduleResetTooltip() }
        return eligible
    }

    private func scheduleResetTooltip() {
        guard let page else { return }
        TooltipController.shared.schedule(Tooltip(title: context?.isOptionHeld == true ? "Separate From Pinned Tab" : "Back to Pinned URL",
                                                 placement: .beside, style: page.style), for: self)
    }

    private func layoutReset(leftPinned: Bool) {
        let hovered = rowView?.isHovered ?? false
        let show = tracked({
            leftPinned && isPinned && hovered && (faviconHovered || context?.forcedFaviconHoverID == tab?.id)
        }) { [weak self] in self?.needsLayout = true }
        if show, resetButton == nil {
            let button = SidebarResetButton(glyph: nil)
            button.context = context
            button.plateRadius = 6
            button.plateColor = { _ in SidebarRole.rowPressed }
            button.glyphTint = { _ in SidebarRole.rowAccessory.nsColor }
            button.accessibleTitle = { [weak self] in self?.context?.isOptionHeld == true ? "Separate From Pinned Tab" : "Back to Pinned URL" }
            button.glyphView.image = { [weak self] in
                SidebarResetImages.image(separate: self?.context?.isOptionHeld == true)
            }
            button.action = { [weak self] in
                guard let self, let tab = self.tab else { return }
                self.context?.send(self.context?.isOptionHeld == true ? .separateFromPinned(tabID: tab.id) : .resetToPinnedURL(tabID: tab.id))
            }
            addSubview(button)
            resetButton = button
        }
        resetButton?.frame = SpaceListMetrics.resetGlyphPlate(indent: indent)
        let separate = context?.isOptionHeld ?? false
        if show != resetShown || (show && separate != resetSeparate) {
            let fade = CATransition(); fade.type = .fade; fade.duration = Motion.hoverFade
            (show != resetShown ? layer : resetButton?.glyphView.layer)?.add(fade, forKey: "reset-swap")
        }
        if resetShown && !show { TooltipController.shared.cancel(for: self) }
        resetShown = show; resetSeparate = separate
        resetButton?.hoverKey = tab.map { .row($0.id) }
        resetButton?.isHidden = !show
        favicon.isHidden = show
        if show {
            _ = tracked({ context?.isOptionHeld }) { [weak self] in self?.needsLayout = true }
            if faviconHovered { scheduleResetTooltip() }
        }
    }

    override func rowStateChanged() {
        if rowView?.isHovered != true, faviconHovered { faviconHovered = false; needsLayout = true }
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
        SidebarDiagnostics.traceFolderView(self, "layout")
        rowStateChanged()
        let m = SpaceListMetrics.self
        let x0 = indent
        // Load the weak tab once; observation is scoped to the fields this row draws.
        let currentTab = tab
        let (audible, muted, leftPinned, capturing, isUnread) = tracked({
            guard let currentTab else { return (false, false, false, false, false) }
            let live = currentTab.live
            return (live.isAudible, currentTab.isMuted, currentTab.hasLeftPinnedURL, live.isCapturing, currentTab.isUnread)
        }) { [weak self] in self?.needsLayout = true }
        favicon.frame = CGRect(x: (context?.manager?.libraryLayout == true ? 15 : m.faviconX) + x0, y: m.faviconY, width: m.faviconSize, height: m.faviconSize)
        layoutReset(leftPinned: leftPinned)
        let a = m.accessorySize
        accessory?.frame = CGRect(x: bounds.width - m.accessoryTrailingInset - a, y: m.accessoryY, width: a, height: a)
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
        let showsUnread = isUnread && !(rowView?.isHovered ?? false) && !badgeShown
        if showsUnread || unread != nil {
            let dot = unread ?? SidebarUnreadDot(host: self)
            unread = dot
            dot.update(shown: showsUnread, cell: self)
            if showsUnread { titleRight = min(titleRight, dot.frame.minX - 6) }
        }
        // Leading media slots come first; the "/" of a left pinned URL stays just before the title (guess).
        var titleX = layoutMediaAccessories(audible: audible, muted: muted, capturing: capturing, x0: x0,
                                            titleX: m.titleX + x0, titleRight: titleRight)
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
        title.frame = CGRect(x: titleX, y: 0, width: max(0, titleRight - titleX), height: m.rowHeight)
        let subtitle = tracked({ [weak self] () -> String? in
            guard let self, let currentTab, let context = self.context,
                  let key = SidebarDeveloperMode.key(currentTab.url), key != "file", context.developerModeHosts.contains(key) else { return nil }
            return SidebarDeveloperMode.hostAndPort(currentTab.url)
        }) { [weak self] in self?.needsLayout = true }
        if let subtitle {
            let label = hostSubtitle ?? {
                let label = TextLabel(); label.font = .systemFont(ofSize: 11)
                label.inset = SpaceListMetrics.textInset; label.trailingInset = SpaceListMetrics.textTrailingInset
                addSubview(label); hostSubtitle = label; return label
            }()
            title.baseline = SpaceListMetrics.titleBaselineOffset - 7
            label.isHidden = false
            label.baseline = title.baseline + 13.5
            label.text = { subtitle }
            label.color = { [weak self] in self?.page?.roles.subtitle.nsColor ?? .secondaryLabelColor }
            label.frame = title.frame
        } else if let label = hostSubtitle, !label.isHidden {
            label.isHidden = true
            title.baseline = SpaceListMetrics.titleBaselineOffset
        }
    }

    /// The one placement function for the leading media slots (media plan §4.1, Step 2b):
    /// favicon, then the recording dot, then the 26 pt speaker; the title moves right by
    /// both, and its right end stays. The speaker frame and the 26 pt title shift are facts
    /// (S2 12/0022, 0027). The leading dot is a guess (no capture; Arc names
    /// `hasLeadingRecordingIndicator`). Under pressure the dot goes before the speaker (lead D9).
    /// Returns the title's left edge.
    private func layoutMediaAccessories(audible: Bool, muted: Bool, capturing: Bool, x0: CGFloat,
                                        titleX: CGFloat, titleRight: CGFloat) -> CGFloat {
        let m = RowMediaMetrics.self, showAudio = audible || muted
        if !showAudio && !capturing && audio == nil && recording == nil { return titleX }
        audio?.isHidden = !showAudio
        if !showAudio { audio?.update(tabID: tab?.id, muted: muted, animate: false) }
        let audioShift = showAudio ? m.titleShift : 0
        let showRecording = capturing && (!showAudio || titleRight - titleX >= audioShift + m.recordingSlotWidth)
        recording?.isHidden = !showRecording
        var x = m.buttonX + x0
        if showRecording {
            let view = recording ?? { let view = RowRecordingView(frame: .zero); addSubview(view); recording = view; return view }()
            view.context = context; view.isHidden = false
            view.frame = CGRect(x: x, y: m.buttonY + (m.buttonSize - m.recordingSlotHeight) / 2,
                                width: m.recordingSlotWidth, height: m.recordingSlotHeight)
            x += m.recordingSlotWidth
        }
        if showAudio {
            let button = makeAudio(); button.isHidden = false; button.context = context
            button.update(tabID: tab?.id, muted: muted)
            button.frame = CGRect(x: x, y: m.buttonY, width: m.buttonSize, height: m.buttonSize)
        }
        return titleX + (showRecording ? m.recordingSlotWidth : 0) + audioShift
    }

    func beginRename() {
        guard let tab else { return }
        let id = tab.id
        beginEditing(text: tab.customTitle ?? tab.title, frame: title.frame.insetBy(dx: -2, dy: 0).offsetBy(dx: 0, dy: 0).with(y: 10, height: 20),
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
    private var unread: SidebarUnreadDot?
    private var unload: FolderUnloadButton?
    /// Live Folder failure state (live-data §2.2 header states): warning glyph, Arc's text as
    /// tooltip and accessibility label; a click opens sign-in or the pulls page. Placement and
    /// form: GUESS — capture pending (F2 capture item 4; Arc shows the text in a folder header).
    private(set) var liveState: LiveFolderStateButton?
    weak var folder: Folder? { didSet { bind() } }

    required init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = context?.manager?.libraryLayout == true ? .systemFont(ofSize:15,weight:.semibold) : Typography.folderTitle.font
        title.baseline = SpaceListMetrics.titleBaselineOffset
        title.inset = SpaceListMetrics.textInset
        title.trailingInset = SpaceListMetrics.textTrailingInset
        addSubview(icon); addSubview(title)
    }

    private func bind() {
        title.font = context?.manager?.libraryLayout == true ? .systemFont(ofSize:15,weight:.semibold) : Typography.folderTitle.font
        icon.folder = folder
        icon.cell = self
        title.text = { [weak self] in self?.folder?.title ?? "" }
        title.color = { [weak self] in self?.titleColor() ?? .labelColor }
        needsLayout = true
    }

    override func rowStateChanged() { needsLayout = true }

    private func hasUnread(_ nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .tab(let tab): tab.isUnread
            case .folder(let folder): hasUnread(folder.children)
            case .split(let split): split.panes.contains { $0.isUnread }
            }
        }
    }

    override func layout() {
        super.layout()
        SidebarDiagnostics.folderRowLayouts += 1
        SidebarDiagnostics.traceFolderView(self, "layout")
        let m = SpaceListMetrics.self
        let shown = tracked({
            guard let folder, !folder.isExpanded else { return false }
            return hasUnread(folder.children) && !(rowView?.isHovered ?? false)
        }) { [weak self] in self?.needsLayout = true }
        icon.frame = CGRect(x: m.faviconX + indent - 1, y: m.faviconY - 1, width: m.faviconSize + 2, height: m.faviconSize + 2)
        if shown || unread != nil {
            let dot = unread ?? SidebarUnreadDot(host: self)
            unread = dot
            dot.update(shown: shown, cell: self)
        }
        let actionShown = (rowView?.isHovered ?? false) && folder.map { context?.isPinnedFolder($0.id) == true } == true
        if actionShown || unload != nil {
            let button = unload ?? FolderUnloadButton(glyph: nil)
            if unload == nil { addSubview(button); unload = button }
            button.context = context
            button.glyphTint = { [weak self] _ in SidebarRole.rowAccessory.resolved(self?.contentAppearance ?? .light).nsColor }
            button.plateColor = { _ in SidebarRole.rowPressed }
            button.action = { [weak self] in
                guard let self, let folder = self.folder else { return }
                self.context?.send(.unloadFolder(folderID: folder.id))
            }
            button.frame = CGRect(x: bounds.width - m.accessoryTrailingInset - m.accessorySize, y: m.accessoryY, width: m.accessorySize, height: m.accessorySize)
            button.isHidden = !actionShown
        }
        let message = tracked({ [weak self] in self?.folder?.live?.stateMessage }) { [weak self] in self?.needsLayout = true }
        if message != nil || liveState != nil {
            let button = liveState ?? LiveFolderStateButton()
            if liveState == nil { addSubview(button); liveState = button }
            button.isHidden = message == nil || actionShown
            button.toolTip = message; button.setAccessibilityLabel(message)
            button.ink = SidebarRole.rowAccessory.resolved(contentAppearance).nsColor
            button.onPress = { [weak self] in
                guard let self, let folder = self.folder else { return }
                self.context?.send(.openLiveFolderState(folder.id))
            }
            let x = bounds.width - m.accessoryTrailingInset - m.accessorySize - (actionShown ? m.accessorySize + 4 : 0)
            button.frame = CGRect(x: x, y: m.accessoryY, width: m.accessorySize, height: m.accessorySize)
        }
        let stateShown = message != nil && !actionShown
        let right = actionShown ? bounds.width - m.accessoryTrailingInset - m.accessorySize : stateShown ? bounds.width - m.accessoryTrailingInset - m.accessorySize - 4 : shown ? bounds.width - m.unreadDotTrailingCenter - m.unreadDotSize / 2 - 6 : bounds.width - m.titleTrailingInset
        title.frame = CGRect(x: m.titleX + indent, y: 0, width: max(0, right - m.titleX - indent), height: m.rowHeight)
    }

    func beginRename() {
        guard let folder else { return }
        let id = folder.id
        beginEditing(text: folder.title, frame: title.frame.with(y: 10, height: 20), font: title.font) { [weak self] value in
            self?.context?.send(.rename(nodeID: id, title: value))
        }
    }
}

/// The Live Folder state glyph (SF Symbol `exclamationmark.triangle`, named in Arc's own
/// header-state code: live-data §2.2).
@MainActor
final class LiveFolderStateButton: NSView {
    var onPress: (@MainActor () -> Void)?
    var ink: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) else { return }
        let size = symbol.size
        symbol.drawTinted(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), color: ink)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() } }
}

/// Q18 visual accessory. A non-AX element, matching the captured folder row.
@MainActor
final class FolderUnloadButton: PlateButton {
    private let ink = CALayer()
    override init(glyph: Glyph?) {
        super.init(glyph: nil)
        layer?.addSublayer(ink)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func isAccessibilityElement() -> Bool { false }
    override func layout() {
        super.layout()
        let size = SpaceListMetrics.folderUnloadInk
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ink.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        CATransaction.commit()
    }
    override func updateLayer() { super.updateLayer(); ink.backgroundColor = glyphTint(true).cgColor }
}

/// Our own folder art, drawn in code: a closed folder (filled) or an open folder
/// (back panel plus a skewed front), tinted with the Space accent.
@MainActor
final class FolderIconView: NSView {
    private(set) var lastDrawnGlyph: String?
    weak var folder: Folder? { didSet { needsDisplay = true } }
    weak var cell: SidebarCellView?
    weak var context: SidebarContext?

    required override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // AppKit's backing context preserves the legacy folder's edge pixels.
    // A manually rasterized CGImage changes them, even at the same scale.
    override func draw(_ dirtyRect: NSRect) {
        SidebarDiagnostics.traceFolderView(self, "draw", rect: dirtyRect)
        guard let folder else { return }
        let context = context ?? cell?.context
        let (expansion, icon, override, accent, usesDefaultAccent) = tracked({
            let space = cell?.page?.space ?? context?.focusedSpace
            let appearance = space.flatMap { context?.appearance(for: $0) } ?? contentAppearance
            let style = space.flatMap { context?.style(for: $0) }
            let accent = style?.accentColor(appearance).nsColor ?? Core.brandBlue.resolved(appearance).nsColor
            return (folder.expansion, context?.folderIconOverrideProvider?(folder) ?? folder.customIcon, folder.iconOverride, accent,
                    style?.accent == nil)
        }) { [weak self] in self?.needsDisplay = true }
        // Main's typed override takes precedence; keep the shared row/header
        // renderer and its existing legacy/custom-icon appearance.
        if let override {
            switch override {
            case .emoji(let value), .symbol(let value), .named(let value): lastDrawnGlyph = value
            }
            let size = SpaceListMetrics.faviconInk
            let ink = backingAlignedRect(CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                                               width: size, height: size), options: .alignAllEdgesNearest)
            NodeIconRenderer.draw(override, in: ink, tint: accent)
            return
        }
        let ink = bounds.insetBy(dx: 1.5, dy: 2.5)
        lastDrawnGlyph = icon ?? (expansion == .expanded ? "folder.open" : folder.peekedChildID != nil ? "folder.peek" : "folder.closed")
        if let icon {
            if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
                symbol.drawTinted(in: ink, color: accent)
            } else { EmojiRenderer.draw(icon, in: bounds) }
        } else if folder.peekedChildID != nil {
            CustomIcon.folderPeek(in: bounds.insetBy(dx: 1, dy: 1), color: usesDefaultAccent ? SidebarRole.folderPeekDefaultAccent.light.nsColor : accent,
                                  dotsColor: SidebarRole.folderPeekDots.light.nsColor)
        } else { CustomIcon.folder(open: expansion == .expanded, in: ink, color: accent) }
        // Live Folder (capture s5 b3: a folder glyph with a service badge). Our badge is Open's own
        // pull-request glyph in the folder body, never GitHub's mark. Size and placement:
        // GUESS — capture pending (only one 2x frame of Arc's glyph exists).
        if folder.live != nil, icon == nil, folder.peekedChildID == nil {
            lastDrawnGlyph = "folder.live"
            let body = CGRect(x: ink.minX, y: ink.minY + ink.height * 0.30, width: ink.width, height: ink.height * 0.70)
            let side = min(body.width, body.height) * 0.78
            PullRequestGlyph.draw(in: CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side), color: .white)
        }
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
        title.color = { [weak self] in current ? (self?.titleColor() ?? .labelColor) : (self?.page?.roles.newTabLabel.nsColor ?? SidebarRole.secondaryText.nsColor) }
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
    var clearTitle: String { "Clear" }
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
        line.backgroundColor = page?.roles.separator.cgColor ?? SidebarRole.divider.cgColor(contentAppearance)
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let w = bounds.width
        _ = tracked({ context?.isOptionHeld ?? false }) { [weak self] in self?.needsLayout = true }
        clearLabel.isHidden = !showsClear
        clearArrow.isHidden = !showsClear
        clearArrow.frame = m.clearArrowFrame.offsetBy(dx: w, dy: 0)
        clearLabel.frame = CGRect(x: w + m.clearLabelX, y: 0, width: 29, height: bounds.height)
        let end = showsClear ? w + m.clearLineEnd : w - m.dividerLineInset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = CGRect(x: m.dividerLineInset, y: m.dividerLineY, width: max(0, end - m.dividerLineInset), height: 1)
        CATransaction.commit()
        if let point = lastPointerLocation { trackPointer(at: point) }
    }

    private var clearRect: NSRect { clearArrow.frame.union(clearLabel.frame).insetBy(dx: -2, dy: 0) }
    var clearHitRect: NSRect { clearRect }

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
    public static var mediaReducesMotion: Bool { mediaReduceMotionOverride ?? Motion.reduceMotionOverride ?? RowMediaAccessibility.shared.reduceMotion }
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
        // Centered like the image view's .alignCenter (S2 12/0022, 0027: both glyphs centered).
        let size = image.size
        let rect = backingAlignedRect(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                             width: size.width, height: size.height), options: .alignAllEdgesNearest)
        image.drawTinted(in: rect, color: SidebarRole.rowAccessory.nsColor)
    }
}

/// System slash/wave replacement in one fixed image-view frame equal to the button,
/// centered in both states (media plan §4.1, lead review r1 F8).
@MainActor private final class RowSpeakerButton: PlateButton {
    private var symbol: RowSpeakerImageView?
    private var staticGlyph: RowStaticSpeakerView?
    private var representedID: ItemID?
    private var lastMuted: Bool?
    private var lastReduceMotion: Bool?
    /// The running spring overlay (SpeakerSpring); the image view hides under it.
    private(set) var springLayer: CALayer?
    override init(glyph: Glyph?) { super.init(glyph: glyph); glyphView.removeFromSuperview() }
    private func stopSpring() {
        springLayer?.removeFromSuperlayer(); springLayer = nil
        symbol?.alphaValue = 1
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if symbol?.frame != bounds { symbol?.frame = bounds }
        staticGlyph?.frame = bounds
        CATransaction.commit()
    }
    func update(tabID: ItemID?, muted: Bool, animate: Bool = true) {
        let reduceMotion = SidebarDiagnostics.mediaReducesMotion
        if representedID == tabID && lastMuted == muted && lastReduceMotion == reduceMotion {
            if !animate { removeAnimations(symbol?.layer); stopSpring() }
            return
        }
        let glyph: Glyph = muted ? .audioMuted : .audioPlaying
        guard let image = glyph.image else { return }
        stopSpring()
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
                view.wantsLayer = true; view.imageScaling = .scaleNone; view.imageAlignment = .alignCenter
                view.identifier = NSUserInterfaceItemIdentifier("media.speakerGlyph")
                addSubview(view); symbol = view; created = true
            }
            view.contentTintColor = SidebarRole.rowAccessory.nsColor
            let springing = changed && animate && !isHiddenOrHasHiddenAncestor && (window?.isVisible == true || SidebarDiagnostics.forceAnimations)
            if springing, let host = layer, let audible = Glyph.audioPlaying.image, let mutedImage = Glyph.audioMuted.image,
               let overlay = SpeakerSpring.run(in: host, bounds: bounds, scale: window?.backingScaleFactor ?? 2, audible: audible, muted: mutedImage,
                                               tint: SidebarRole.rowAccessory.nsColor, toMuted: muted, completion: { [weak self] in
                                                   self?.springLayer = nil; self?.symbol?.alphaValue = 1 }) {
                // Arc's spring choreography (PP-23); the image view holds the final glyph underneath.
                CATransaction.begin(); CATransaction.setDisableActions(true)
                view.image = image; view.alphaValue = 0
                CATransaction.commit()
                springLayer = overlay
            } else if springing {
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
            if !animate { removeAnimations(view.layer); stopSpring() }
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
    override func accessibilityHelp() -> String? { tooltip?()?.title ?? accessibleTitle?() }
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

/// The Developer Mode site key of a URL (as App `DeveloperMode.host(for:)` and `SidebarContext.fieldText`).
enum SidebarDeveloperMode {
    static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return "file" }
        guard scheme == "http" || scheme == "https", let host = url.host()?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        return host
    }
    static func hostAndPort(_ url: URL) -> String {
        (url.host() ?? "") + (url.port.map { ":\($0)" } ?? "")
    }
}
