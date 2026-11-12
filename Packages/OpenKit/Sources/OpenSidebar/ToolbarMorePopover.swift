import AppKit
import OpenDesign

/// The compact toolbar's "More options" popover: a card with an arrow under the button and one row per action
/// (icon, title, shortcut). Measured on Arc capture session 9, `46-pb5-a6-compact-more/c-2-more-window` (2x, light):
/// card 200 × 95 pt centred under the button, top 17 pt below it, arrow tip 6 pt above the card; 8 pt padding;
/// rows 39 pt with a 1 pt gap, row radius 8; icon centre 27.5 pt from the card's left; title at 50 pt;
/// shortcut right inset 21 pt. Colors (sRGB): card #FDFDFF, hovered row #D3D4FD, title black, disabled #B2B2B2.
/// GUESS — not captured: the dark look, card radius 12, shadow, fonts (13 pt medium / 12 pt), and whether the
/// hover tint follows the Space theme.
@MainActor
final class ToolbarMorePopover: NSView {
    struct Row {
        var glyph: Glyph
        var title: String
        var shortcut: String
        var isEnabled: Bool
        var action: @MainActor () -> Void
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
    var dark = false { didSet { needsDisplay = true; rowViews.forEach { $0.dark = dark } } }
    /// Arrow tip x in this view's coordinates.
    var arrowX: CGFloat = Metrics.width / 2 { didSet { needsDisplay = true } }
    var onDismiss: (@MainActor () -> Void)?
    private(set) var rowViews: [ToolbarMoreRowView] = []
    private var monitors: [Any] = []

    init(rows: [Row]) {
        self.rows = rows
        super.init(frame: CGRect(origin: .zero, size: Self.size(rowCount: rows.count)))
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -4)
        for (index, row) in rows.enumerated() {
            let view = ToolbarMoreRowView(row: row)
            view.onPress = { [weak self] in self?.choose(index) }
            rowViews.append(view); addSubview(view)
        }
        setAccessibilityRole(.menu)
        setAccessibilityLabel("More options")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { monitors.forEach(NSEvent.removeMonitor) }
    override var isFlipped: Bool { true }

    static func size(rowCount: Int) -> CGSize {
        let n = CGFloat(max(1, rowCount))
        return CGSize(width: Metrics.width,
                      height: Metrics.arrowHeight + 2 * Metrics.padding + n * Metrics.rowHeight + (n - 1) * Metrics.rowGap)
    }

    override func layout() {
        super.layout()
        var y = Metrics.arrowHeight + Metrics.padding
        for view in rowViews {
            view.frame = CGRect(x: Metrics.padding, y: y, width: bounds.width - 2 * Metrics.padding, height: Metrics.rowHeight)
            y += Metrics.rowHeight + Metrics.rowGap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
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
    func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        let action = rows[index].action
        dismiss()
        action()
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard superview != nil else { return }
        removeFromSuperview()
        onDismiss?()
    }

    /// Shows the card in `host` (the window's content view), centred under `anchor`, kept inside the host.
    func present(in host: NSView, under anchor: NSView) {
        let a = host.convert(anchor.bounds, from: anchor)
        let size = Self.size(rowCount: rows.count)
        let centre = a.midX
        let x = min(max(8, centre - size.width / 2), max(8, host.bounds.width - size.width - 8))
        // The card hangs below the button: lower y in an unflipped host, higher y in a flipped one.
        let top = Metrics.anchorGap
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
    var swallowsClick: (@MainActor (NSPoint) -> Bool)?
}

/// One row of the card: icon, title, shortcut; a rounded tint while hovered.
@MainActor
final class ToolbarMoreRowView: NSView {
    let row: ToolbarMorePopover.Row
    var dark = false { didSet { needsDisplay = true } }
    var onPress: (@MainActor () -> Void)?
    /// Render scenes set this to draw the hovered state.
    var forcedHover = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let icon = GlyphView()

    init(row: ToolbarMorePopover.Row) {
        self.row = row
        super.init(frame: .zero)
        icon.glyph = row.glyph
        icon.tint = { [weak self] in self?.ink }
        addSubview(icon)
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
    private var shortcutInk: NSColor { dark ? NSColor(white: 1, alpha: 0.35) : NSColor(srgbRed: 0.698, green: 0.698, blue: 0.698, alpha: 1) }

    override func layout() {
        super.layout()
        let m = ToolbarMorePopover.Metrics.self, s = m.iconSize
        // Row x starts at the card padding.
        icon.frame = backingAlignedRect(CGRect(x: m.iconCenterX - m.padding - s / 2, y: (bounds.height - s) / 2, width: s, height: s),
                                        options: .alignAllEdgesNearest)
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = ToolbarMorePopover.Metrics.self
        if (hovered || forcedHover) && row.isEnabled {
            (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(srgbRed: 0.827, green: 0.831, blue: 0.992, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: m.rowRadius, yRadius: m.rowRadius).fill()
        }
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]
        let titleSize = (row.title as NSString).size(withAttributes: title)
        (row.title as NSString).draw(at: CGPoint(x: m.titleX - m.padding, y: (bounds.height - titleSize.height) / 2), withAttributes: title)
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
