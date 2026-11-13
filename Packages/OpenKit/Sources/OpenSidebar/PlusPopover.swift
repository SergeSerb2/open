import AppKit
import OpenDesign

/// The bottom-bar "+" popover: Arc draws a custom window, not an NSMenu (capture session 8 item 7).
/// Rows come from `SidebarMenus.plus()`, so the menu stays the one list of items, titles, keys
/// and enabled rules. Opens with the last row ("New Tab") highlighted; ↓ and ↑ move and wrap,
/// Return runs the row, Esc or a click outside closes.
@MainActor
final class PlusPopoverView: NSView {
    struct Row { var item: NSMenuItem; var frame: CGRect; var symbol: String }
    private(set) var rows: [Row] = []
    /// Owns the items: an `NSMenuItem` only points weakly at its menu.
    let sourceMenu: NSMenu
    private var separators: [CGRect] = []
    var colors: PlusPopoverColors { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onRun: ((NSMenuItem) -> Void)?
    /// Arrow tip x in this view's coordinates.
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    /// Open's own symbols for the six rows (SF Symbols; no Arc art).
    static let symbols: [String: String] = [
        "New Space": "plus.square.on.square", "New Folder": "folder", "New Easel": "scribble",
        "New Boost": "paintbrush", "New Split": "rectangle.split.2x1", "New Tab": "plus.app",
    ]

    init(menu: NSMenu, colors: PlusPopoverColors) {
        self.colors = colors
        self.sourceMenu = menu
        super.init(frame: .zero)
        let m = PlusPopoverMetrics.self
        var y = m.margin + m.rowInset, firstInGroup = true
        for item in menu.items where !item.isAlternate && !item.isHidden {
            if item.isSeparatorItem {
                if !rows.isEmpty { separators.append(CGRect(x: m.margin + m.separatorInset, y: y + m.separatorOffset, width: m.bodyWidth - 2 * m.separatorInset, height: 1)) ; y += m.groupGap }
                firstInGroup = true
                continue
            }
            rows.append(Row(item: item, frame: CGRect(x: m.margin + m.rowInset, y: y, width: m.rowSize.width, height: m.rowSize.height),
                            symbol: Self.symbols[item.title] ?? "plus"))
            y += m.rowSize.height; firstInGroup = false
        }
        _ = firstInGroup
        let body = m.bodyHeight(rows: rows.count, groups: separators.count + 1)
        frame = CGRect(x: 0, y: 0, width: m.bodyWidth + 2 * m.margin, height: body + 2 * m.margin + m.arrowSize.height)
        highlighted = rows.lastIndex { $0.item.isEnabled }
        setAccessibilityRole(.popover); setAccessibilityLabel("New")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    var bodyRect: CGRect {
        let m = PlusPopoverMetrics.self
        return CGRect(x: m.margin, y: m.margin, width: m.bodyWidth, height: bounds.height - 2 * m.margin - m.arrowSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = PlusPopoverMetrics.self, body = bodyRect
        let shape = NSBezierPath(roundedRect: body, xRadius: m.bodyRadius, yRadius: m.bodyRadius)
        let tipX = min(max(arrowX, body.minX + m.bodyRadius + m.arrowSize.width / 2), body.maxX - m.bodyRadius - m.arrowSize.width / 2)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: tipX - m.arrowSize.width / 2, y: body.maxY - 0.5))
        arrow.line(to: CGPoint(x: tipX, y: body.maxY + m.arrowSize.height))
        arrow.line(to: CGPoint(x: tipX + m.arrowSize.width / 2, y: body.maxY - 0.5))
        arrow.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 5; shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set(); colors.fill.nsColor.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        colors.fill.nsColor.setFill(); shape.fill(); arrow.fill()
        colors.separator.nsColor.setFill()
        for line in separators { line.fill() }
        for (index, row) in rows.enumerated() {
            let enabled = row.item.isEnabled
            if index == highlighted, enabled {
                colors.highlight.nsColor.setFill()
                NSBezierPath(roundedRect: row.frame, xRadius: m.rowRadius, yRadius: m.rowRadius).fill()
            }
            let ink = (enabled ? colors.label : colors.disabled).nsColor
            if let image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
                let size = image.size
                image.drawTinted(in: CGRect(x: row.frame.minX + m.iconCenterX - size.width / 2, y: row.frame.midY - size.height / 2, width: size.width, height: size.height), color: ink)
            }
            let label = NSAttributedString(string: row.item.title, attributes: [.font: m.labelFont, .foregroundColor: ink])
            label.draw(at: CGPoint(x: row.frame.minX + m.labelX, y: row.frame.midY - label.size().height / 2))
            let keys = Self.shortcut(row.item)
            if !keys.isEmpty {
                let text = NSAttributedString(string: keys, attributes: [.font: m.shortcutFont, .kern: 2,
                    .foregroundColor: (enabled ? colors.shortcut : colors.disabled).nsColor])
                text.draw(at: CGPoint(x: row.frame.maxX - m.shortcutTrailing - text.size().width + 2, y: row.frame.midY - text.size().height / 2))
            }
        }
    }

    /// "⌃⇧E" from the item's key equivalent.
    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
            + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
    }

    func move(_ delta: Int) {
        let enabled = rows.indices.filter { rows[$0].item.isEnabled }
        guard !enabled.isEmpty else { return }
        let position = highlighted.flatMap { enabled.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        highlighted = enabled[((position + delta) % enabled.count + enabled.count) % enabled.count]
    }
    func runHighlighted() { if let index = highlighted, rows[index].item.isEnabled { onRun?(rows[index].item) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return rows.firstIndex { $0.frame.contains(point) && $0.item.isEnabled }
    }
    override func mouseMoved(with event: NSEvent) { if let index = row(at: event) { highlighted = index } }
    override func mouseUp(with event: NSEvent) { if let index = row(at: event) { highlighted = index; runHighlighted() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PlusPopover {
    private var panel: NSPanel?
    private(set) var view: PlusPopoverView?
    private var monitor: Any?
    var onVisibilityChange: ((Bool) -> Void)?
    var isShown: Bool { panel != nil }

    /// Shows the popover with its arrow at `button`'s top centre.
    func show(menu: NSMenu, colors: PlusPopoverColors, from button: NSView, sidebar: NSView) {
        close()
        guard let window = button.window else { return }
        let view = PlusPopoverView(menu: menu, colors: colors)
        view.onRun = { [weak self, unowned view] item in
            // Keep the menu alive until its action ran; closing drops the view.
            let menu = view.sourceMenu
            self?.close()
            let index = menu.index(of: item)
            if index >= 0 { menu.performActionForItem(at: index) }
        }
        let m = PlusPopoverMetrics.self
        let anchor = button.convert(button.bounds, to: nil), edge = sidebar.convert(sidebar.bounds, to: nil)
        // Body right edge 8 pt inside the sidebar; arrow tip just above the button.
        let x = edge.maxX - m.trailingInset - m.bodyWidth - m.margin
        let y = anchor.maxY + 2 - m.margin
        view.arrowX = anchor.midX - x
        let origin = window.convertPoint(toScreen: CGPoint(x: x, y: y))
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: view.frame.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.contentView = view
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel; self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            // keyCode throws for non-key events (crash when a click picks New Easel).
            let type = event.type, code = type == .keyDown ? event.keyCode : 0, number = event.windowNumber
            nonisolated(unsafe) let location = event
            let consumed = MainActor.assumeIsolated { self?.consumes(type: type, keyCode: code, windowNumber: number, event: location) ?? false }
            return consumed ? nil : event
        }
        onVisibilityChange?(true)
    }

    /// Keyboard and outside clicks while the popover shows. True for consumed events.
    private func consumes(type: NSEvent.EventType, keyCode: UInt16, windowNumber: Int, event: NSEvent) -> Bool {
        guard let panel else { return false }
        if type == .keyDown { return key(keyCode) }
        if windowNumber == panel.windowNumber { return false }
        // A click on the "+" itself only closes (the button would reopen it at once).
        let onButton = closesOnly?(event) == true
        close()
        return onButton
    }
    /// True when a mouse-down should only close the popover (the "+" button).
    var closesOnly: ((NSEvent) -> Bool)?

    /// ↓ 125, ↑ 126, Return 36 / 76, Esc 53. Other keys pass through.
    @discardableResult func key(_ code: UInt16) -> Bool {
        guard let view else { return false }
        switch code {
        case 125: view.move(1)
        case 126: view.move(-1)
        case 36, 76: view.runHighlighted()
        case 53: close()
        default: return false
        }
        return true
    }

    func close() {
        guard let panel else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        self.panel = nil; view = nil
        onVisibilityChange?(false)
    }
}
