import AppKit
import OpenDesign

/// The result list: at most 5 rows visible, up to 12 held (the engine's cap), scrolled
/// by whole rows from the keyboard and smoothly by the wheel. Row views are reused by
/// position and only reconfigured, so a keystroke never allocates views.
@MainActor
final class ResultsView: NSView {
    private(set) var rows: [CommandBarRow] = []
    private(set) var selectedIndex: Int?
    private var rowViews: [ResultRowView] = []
    private let selectionLayer = CALayer()
    private(set) var scrollOffset: CGFloat = 0
    weak var favicons: CommandBarFaviconSource? {
        didSet { for v in rowViews { v.favicons = favicons } }
    }
    var theme = CommandBarTheme.default {
        didSet {
            for v in rowViews { v.theme = theme }
            updateSelectionLayer()
        }
    }
    /// Pointer moved onto row `i` (a real mouse move, not rows sliding under a still pointer).
    var onHover: ((Int) -> Void)?
    /// Click on row `i`.
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        selectionLayer.cornerRadius = CommandBarMetrics.selectionRadius
        selectionLayer.cornerCurve = .continuous
        selectionLayer.isHidden = true
        selectionLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(selectionLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Suggestions" }
    override func accessibilityChildren() -> [Any]? { rowViews.filter { $0.row != nil } }
    override func accessibilitySelectedChildren() -> [Any]? {
        guard let i = selectedIndex, rowViews.indices.contains(i) else { return [] }
        return [rowViews[i]]
    }
    private var announcedSelection: CommandBarRow?

    private func announceSelection() {
        let row = selectedIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        guard row != announcedSelection else { return }
        announcedSelection = row
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if let row, let window {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: row.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    /// The bottom part of the list that the privacy footer covers (CC-42). Rows there are not
    /// visible, cannot be hovered or clicked, and the list scrolls so every row can leave it.
    var occludedBottom: CGFloat = 0 {
        didSet { if occludedBottom != oldValue { needsLayout = true } }
    }
    var visibleHeight: CGFloat { max(0, bounds.height - occludedBottom) }
    var contentHeight: CGFloat { CGFloat(rows.count) * CommandBarMetrics.rowHeight }
    var maxScroll: CGFloat { max(0, contentHeight - visibleHeight) }

    /// Replaces the rows. Views whose row did not change are not redrawn.
    func setRows(_ newRows: [CommandBarRow], selected: Int?) {
        rows = newRows
        while rowViews.count < rows.count {
            let v = ResultRowView(frame: .zero)
            v.favicons = favicons
            v.theme = theme
            let index = rowViews.count
            v.onPress = { [weak self] in self?.onClick?(index, []) }
            addSubview(v)
            rowViews.append(v)
        }
        for (i, v) in rowViews.enumerated() {
            if i < rows.count {
                v.row = rows[i]
            } else {
                v.row = nil
                v.isHidden = true
            }
        }
        selectedIndex = selected.flatMap { rows.indices.contains($0) ? $0 : nil }
        scrollOffset = min(scrollOffset, maxScroll)
        layoutRows()
        announceSelection()
    }

    func select(_ index: Int?) {
        selectedIndex = index.flatMap { rows.indices.contains($0) ? $0 : nil }
        if let i = selectedIndex { scrollToVisible(i) }
        layoutRows()
        announceSelection()
    }

    func resetScroll() { scrollOffset = 0 }

    /// Keeps row `i` inside the visible window (keyboard navigation).
    func scrollToVisible(_ i: Int) {
        let h = CommandBarMetrics.rowHeight
        let top = CGFloat(i) * h, bottom = top + h
        // Whole rows: a footer that leaves 199 of 200 pt shows 4 rows, not 3 plus a 1 pt scroll.
        let viewport = max(h, (visibleHeight / h).rounded() * h)
        if top < scrollOffset { scrollOffset = top } else if bottom > scrollOffset + viewport { scrollOffset = bottom - viewport }
        scrollOffset = min(max(0, scrollOffset), maxScroll)
    }

    override func layout() {
        super.layout()
        scrollOffset = min(scrollOffset, maxScroll)
        layoutRows()
    }

    private func layoutRows() {
        let m = CommandBarMetrics.self
        let w = bounds.width - 2 * m.rowInsetX
        let visible = CGRect(x: 0, y: 0, width: bounds.width, height: visibleHeight).insetBy(dx: 0, dy: -1)
        for (i, v) in rowViews.enumerated() where i < rows.count {
            let f = CGRect(x: m.rowInsetX, y: CGFloat(i) * m.rowHeight - scrollOffset, width: w, height: m.rowHeight)
            // Rows outside the clip are hidden so AppKit does not draw them.
            let shown = f.intersects(visible)
            if v.isHidden == shown { v.isHidden = !shown }
            if v.frame != f { v.frame = f }
            v.isSelected = i == selectedIndex
        }
        updateSelectionLayer()
    }

    private func updateSelectionLayer() {
        let m = CommandBarMetrics.self
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let i = selectedIndex {
            let inset = m.selectionInset
            selectionLayer.frame = CGRect(x: m.rowInsetX + inset, y: CGFloat(i) * m.rowHeight - scrollOffset + inset,
                                          width: bounds.width - 2 * (m.rowInsetX + inset), height: m.rowHeight - 2 * inset)
            selectionLayer.backgroundColor = theme.focus.cgColor
            selectionLayer.isHidden = false
        } else {
            selectionLayer.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    func rowIndex(at point: NSPoint) -> Int? {
        let y = point.y + scrollOffset
        guard point.x >= CommandBarMetrics.rowInsetX, point.x <= bounds.width - CommandBarMetrics.rowInsetX, y >= 0,
              point.y < visibleHeight else { return nil }
        let i = Int(y / CommandBarMetrics.rowHeight)
        return rows.indices.contains(i) ? i : nil
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = rowIndex(at: convert(event.locationInWindow, from: nil)) { onHover?(i) }
    }

    private var pressedRow: Int?

    override func mouseDown(with event: NSEvent) {
        pressedRow = rowIndex(at: convert(event.locationInWindow, from: nil))
        if let i = pressedRow { onHover?(i) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedRow = nil }
        guard let p = pressedRow, rowIndex(at: convert(event.locationInWindow, from: nil)) == p else { return }
        onClick?(p, event.modifierFlags)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * CommandBarMetrics.rowHeight
        let next = min(max(0, scrollOffset - dy), maxScroll)
        guard next != scrollOffset else { return }
        scrollOffset = next
        layoutRows()
    }

    // MARK: Diagnostics

    var rowDrawCount: Int { rowViews.reduce(0) { $0 + $1.drawCount } }
    var visibleRowCount: Int { rowViews.filter { !$0.isHidden && $0.row != nil }.count }
}
