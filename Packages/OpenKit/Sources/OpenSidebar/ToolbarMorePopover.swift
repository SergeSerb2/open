import AppKit
import OpenDesign

/// The compact toolbar's "More options" popover: a card with an arrow under the button and one row per action
/// (icon, title, shortcut). Measured on Arc capture session 9, `46-pb5-a6-compact-more/c-2-more-window` (2x, light):
/// card 200 × 95 pt centred under the button, top 17 pt below it, arrow tip 6 pt above the card; 8 pt padding;
/// rows 39 pt with a 1 pt gap, row radius 8; icon centre 27.5 pt from the card's left; title at 50 pt;
/// shortcut right inset 21 pt. Colors (sRGB): card #FDFDFF, hovered row #D3D4FD, title black, disabled #B2B2B2.
/// GUESS — not captured: the dark look, card radius 12, shadow, fonts (13 pt medium / 12 pt), and whether the
/// hover tint follows the Space theme.
///
/// Developer Mode's Extensions Menu uses the same card (`Layout.extensions`, C-report-s10 PB3-a2), measured on
/// `v10/d1-devbar-hover-menus/m-ext.png` (2x, light): card 250 × 96 pt plus the arrow, arrow tip under the button's
/// center 10.5 pt below its bottom edge, two 40 pt rows with no gap and 8 pt padding, titles 19 pt from the card's
/// left, no icons and no shortcuts; same card #FDFDFF and hovered row #D3D4FD.
@MainActor
public final class ToolbarMorePopover: NSView {
    /// Row icons, drawn here to Arc's shapes (measured on the capture, 2 pt strokes): `sidebar` is a 20 × 15 pt
    /// rounded rectangle with one divider at a third and no lines in the left pane; `reload` is an open circle
    /// with a corner arrow at the top right (about 14.5 × 13 pt). `stop` (Open's Stop Loading row) is a cross.
    public enum Icon: Sendable { case reload, stop, sidebar }
    public struct Row {
        var icon: Icon?
        var title: String
        var shortcut: String
        var isEnabled: Bool
        var action: @MainActor () -> Void
        public init(icon: Icon? = nil, title: String, shortcut: String = "", isEnabled: Bool = true, action: @escaping @MainActor () -> Void) {
            self.icon = icon; self.title = title; self.shortcut = shortcut; self.isEnabled = isEnabled; self.action = action
        }
    }
    /// The sizes that differ between the cards that use this view.
    public struct Layout: Sendable {
        var width: CGFloat, rowHeight: CGFloat, rowGap: CGFloat, titleX: CGFloat, anchorGap: CGFloat, label: String
        /// The compact toolbar's More options card (capture session 9).
        public static let more = Layout(width: Metrics.width, rowHeight: Metrics.rowHeight, rowGap: Metrics.rowGap,
                                        titleX: Metrics.titleX, anchorGap: Metrics.anchorGap, label: "More options")
        /// Developer Mode's Extensions Menu card (capture session 10, `m-ext.png`).
        public static let extensions = Layout(width: 250, rowHeight: 40, rowGap: 0, titleX: 19, anchorGap: 10.5, label: "Extensions")
    }
    enum Metrics {
        static let width: CGFloat = 200
        static let padding: CGFloat = 8
        static let rowHeight: CGFloat = 39
        static let rowGap: CGFloat = 1
        static let rowRadius: CGFloat = 8
        static let cardRadius: CGFloat = 12
        static let arrowHeight: CGFloat = 6
        static let arrowWidth: CGFloat = 14
        /// The arrow tip sits this far below the button's bottom edge (measured: button bottom 37, tip 49).
        static let anchorGap: CGFloat = 12
        static let iconCenterX: CGFloat = 27.5
        static let iconSize: CGFloat = 18
        static let titleX: CGFloat = 50
        static let shortcutInset: CGFloat = 21
    }

    let rows: [Row]
    let cardLayout: Layout
    public var dark = false { didSet { needsDisplay = true; rowViews.forEach { $0.dark = dark } } }
    /// Arrow tip x in this view's coordinates.
    var arrowX: CGFloat = Metrics.width / 2 { didSet { needsDisplay = true } }
    public var onDismiss: (@MainActor () -> Void)?
    /// Row titles (verification).
    public var rowTitles: [String] { rows.map(\.title) }
    /// Arrow tip x in this view's coordinates (verification).
    public var arrowTipX: CGFloat { arrowX }
    private(set) var rowViews: [ToolbarMoreRowView] = []
    private var monitors: [Any] = []

    public init(rows: [Row], layout: Layout = .more) {
        self.rows = rows; self.cardLayout = layout
        super.init(frame: CGRect(origin: .zero, size: Self.size(rowCount: rows.count, layout: layout)))
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -4)
        for (index, row) in rows.enumerated() {
            let view = ToolbarMoreRowView(row: row, titleX: cardLayout.titleX)
            view.onPress = { [weak self] in self?.choose(index) }
            rowViews.append(view); addSubview(view)
        }
        setAccessibilityRole(.menu)
        setAccessibilityLabel(cardLayout.label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { monitors.forEach(NSEvent.removeMonitor) }
    public override var isFlipped: Bool { true }

    static func size(rowCount: Int, layout: Layout = .more) -> CGSize {
        let n = CGFloat(max(1, rowCount))
        return CGSize(width: layout.width,
                      height: Metrics.arrowHeight + 2 * Metrics.padding + n * layout.rowHeight + (n - 1) * layout.rowGap)
    }

    public override func layout() {
        super.layout()
        var y = Metrics.arrowHeight + Metrics.padding
        for view in rowViews {
            view.frame = CGRect(x: Metrics.padding, y: y, width: bounds.width - 2 * Metrics.padding, height: cardLayout.rowHeight)
            y += cardLayout.rowHeight + cardLayout.rowGap
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let card = CGRect(x: 0, y: Metrics.arrowHeight, width: bounds.width, height: bounds.height - Metrics.arrowHeight)
        let path = NSBezierPath(roundedRect: card, xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
        let x = min(max(arrowX, Metrics.cardRadius + Metrics.arrowWidth / 2), bounds.width - Metrics.cardRadius - Metrics.arrowWidth / 2)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: x - Metrics.arrowWidth / 2, y: Metrics.arrowHeight + 0.5))
        arrow.line(to: CGPoint(x: x, y: 0))
        arrow.line(to: CGPoint(x: x + Metrics.arrowWidth / 2, y: Metrics.arrowHeight + 0.5))
        arrow.close()
        path.append(arrow)
        (dark ? NSColor(srgbRed: 0.165, green: 0.165, blue: 0.18, alpha: 1) : NSColor(srgbRed: 0.992, green: 0.992, blue: 1, alpha: 1)).setFill()
        path.fill()
    }

    /// Runs row `index` through its press path, then dismisses (clicks, Return and automation use it).
    public func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        let action = rows[index].action
        dismiss()
        action()
    }

    public func dismiss() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard superview != nil else { return }
        removeFromSuperview()
        onDismiss?()
    }

    /// Shows the card in `host` (the window's content view), centred under `anchor`, kept inside the host.
    public func present(in host: NSView, under anchor: NSView) {
        let a = host.convert(anchor.bounds, from: anchor)
        let size = Self.size(rowCount: rows.count, layout: cardLayout)
        let centre = a.midX
        let x = min(max(8, centre - size.width / 2), max(8, host.bounds.width - size.width - 8))
        // The card hangs below the button: lower y in an unflipped host, higher y in a flipped one.
        let top = cardLayout.anchorGap
        let y = host.isFlipped ? a.maxY + top : a.minY - top - size.height
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        arrowX = centre - x
        host.addSubview(self, positioned: .above, relativeTo: nil)
        // An unflipped host draws this flipped view upright by itself; nothing else to do.
        installMonitors()
    }

    private func installMonitors() {
        guard monitors.isEmpty, window != nil else { return }
        // The handlers return "consume the event" as a Bool: NSEvent itself cannot cross the isolation check.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let window = event.window, location = event.locationInWindow
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.superview != nil else { return false }
                guard window === self.window else { self.dismiss(); return false }
                if self.bounds.contains(self.convert(location, from: nil)) { return false }
                // A click on the button that opened the card only closes it.
                let onAnchor = self.swallowsClick?(location) == true
                self.dismiss()
                return onAnchor
            }
            return consumed ? nil : event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let escape = event.keyCode == 53
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.superview != nil else { return false }
                self.dismiss()
                return escape
            }
            return consumed ? nil : event
        }) { monitors.append(monitor) }
    }
    /// True for a mouse-down at this window location that only closes the card (on the anchor button).
    public var swallowsClick: (@MainActor (NSPoint) -> Bool)?
}

/// One row of the card: icon, title, shortcut; a rounded tint while hovered.
@MainActor
final class ToolbarMoreRowView: NSView {
    let row: ToolbarMorePopover.Row
    let titleX: CGFloat
    var dark = false { didSet { needsDisplay = true } }
    var onPress: (@MainActor () -> Void)?
    /// Render scenes set this to draw the hovered state.
    var forcedHover = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(row: ToolbarMorePopover.Row, titleX: CGFloat = ToolbarMorePopover.Metrics.titleX) {
        self.row = row; self.titleX = titleX
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.menuItem); setAccessibilityLabel(row.title)
        setAccessibilityEnabled(row.isEnabled)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { guard row.isEnabled else { return false }; onPress?(); return true }

    private var ink: NSColor {
        if !row.isEnabled { return dark ? NSColor(white: 1, alpha: 0.30) : NSColor(srgbRed: 0.698, green: 0.698, blue: 0.698, alpha: 1) }
        return dark ? NSColor(white: 1, alpha: 0.92) : .black
    }
    /// Grey at rest; on the hovered row Arc tints the shortcut lavender (#A6AAFB on the #D3D4FD fill, measured).
    private var shortcutInk: NSColor {
        if dark { return NSColor(white: 1, alpha: 0.35) }
        return isHighlighted ? NSColor(srgbRed: 0.651, green: 0.667, blue: 0.984, alpha: 1)
            : NSColor(srgbRed: 0.698, green: 0.698, blue: 0.698, alpha: 1)
    }
    private var isHighlighted: Bool { (hovered || forcedHover) && row.isEnabled }

    private func drawIcon() {
        let m = ToolbarMorePopover.Metrics.self
        // Row x starts at the card padding. Flipped coordinates (y down).
        let cx = m.iconCenterX - m.padding, cy = bounds.midY
        ink.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
        guard let icon = row.icon else { return }
        switch icon {
        case .sidebar:
            // Stroke centre lines of a 20 × 15 pt outer box.
            let box = CGRect(x: cx - 9, y: cy - 6.5, width: 18, height: 13)
            path.appendRoundedRect(box, xRadius: 2.5, yRadius: 2.5)
            path.move(to: CGPoint(x: box.minX + 6.25, y: box.minY)); path.line(to: CGPoint(x: box.minX + 6.25, y: box.maxY))
        case .reload:
            // Open circle, gap at the lower right; corner arrow at the upper right.
            let c = CGPoint(x: cx - 0.75, y: cy + 0.25), r: CGFloat = 5.5
            // In flipped coordinates angles grow clockwise on screen: from the upper right, through top, left and
            // bottom, to the lower right.
            path.appendArc(withCenter: c, radius: r, startAngle: -18, endAngle: 52, clockwise: true)
            let corner = CGPoint(x: c.x + 7, y: c.y - 1.25)
            path.move(to: CGPoint(x: corner.x, y: corner.y - 4.75)); path.line(to: corner); path.line(to: CGPoint(x: corner.x - 4.75, y: corner.y))
        case .stop:
            path.move(to: CGPoint(x: cx - 5, y: cy - 5)); path.line(to: CGPoint(x: cx + 5, y: cy + 5))
            path.move(to: CGPoint(x: cx + 5, y: cy - 5)); path.line(to: CGPoint(x: cx - 5, y: cy + 5))
        }
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = ToolbarMorePopover.Metrics.self
        if isHighlighted {
            (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(srgbRed: 0.827, green: 0.831, blue: 0.992, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: m.rowRadius, yRadius: m.rowRadius).fill()
        }
        drawIcon()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]
        let titleSize = (row.title as NSString).size(withAttributes: title)
        (row.title as NSString).draw(at: CGPoint(x: titleX - m.padding, y: (bounds.height - titleSize.height) / 2), withAttributes: title)
        let keys: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: shortcutInk, .kern: 1.5]
        let keySize = (row.shortcut as NSString).size(withAttributes: keys)
        (row.shortcut as NSString).draw(at: CGPoint(x: bounds.width - (m.shortcutInset - m.padding) - keySize.width, y: (bounds.height - keySize.height) / 2),
                                        withAttributes: keys)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if row.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
