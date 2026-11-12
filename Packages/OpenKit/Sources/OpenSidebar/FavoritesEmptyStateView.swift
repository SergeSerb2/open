import AppKit
import OpenDesign

/// The Favorites empty-state card (audit A3). Arc shows it in a Profile without Favorites until the
/// user dismisses it (`sidebarFavoritesEmptyStateDismissButton`; keys `topAppsEmptyStateDismissed…`).
///
/// Measured (interaction-states §20.3, S2 07/0001, dark default theme, sidebar width 228): a dashed
/// 1 pt outline (dash 5, gap 5, corner about 12) 95 pt tall; a 17 pt `star.circle.fill` at the top
/// centre; a 14 pt "x" Dismiss button at the top right; "Drag to add Favorites" (13 Semibold) and
/// "Favorites keep your most used sites and apps close" (11.5 Regular, two lines), both centred.
/// Dark colours measured over Arc's default indigo: outline about white 0.28, inside a little darker
/// than the sidebar, title as the row title, body as the secondary text; here they come from the
/// Space's sidebar roles so a themed Space stays readable.
/// GUESS — capture pending (PB5-c): the light look, the hover of the "x", the drop-target dim
/// amount, and that the card has no hover state of its own.
@MainActor
public final class FavoritesEmptyStateView: NSView {
    public static let title = "Drag to add Favorites"
    public static let body = "Favorites keep your most used sites and apps close"
    private let titleLabel = NSTextField(labelWithString: FavoritesEmptyStateView.title)
    private let bodyLabel = NSTextField(wrappingLabelWithString: FavoritesEmptyStateView.body)
    public let dismissButton = FavoritesEmptyDismissButton()
    private var roles: SidebarRoles?
    private var content: ContentAppearance = .dark
    var onDismiss: (@MainActor () -> Void)? { didSet { dismissButton.onPress = onDismiss } }
    /// While a tab or link is dragged over the section the icon and text dim (measured: they dim;
    /// the amount is a guess).
    public var isDropTarget = false { didSet { if isDropTarget != oldValue { applyColors(); needsDisplay = true } } }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold); titleLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 11.5); bodyLabel.alignment = .center; bodyLabel.maximumNumberOfLines = 2
        for label in [titleLabel, bodyLabel] { label.isSelectable = false; label.drawsBackground = false; addSubview(label) }
        dismissButton.setAccessibilityLabel("Dismiss")
        dismissButton.setAccessibilityIdentifier("sidebarFavoritesEmptyStateDismissButton")
        addSubview(dismissButton)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title + ". " + Self.body)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }

    func apply(roles: SidebarRoles, appearance: ContentAppearance) {
        self.roles = roles; content = appearance
        applyColors(); needsDisplay = true
    }
    private var dim: CGFloat { isDropTarget ? 0.45 : 1 }
    private var titleColor: NSColor { (roles?.title.nsColor ?? .labelColor).withAlphaComponent(dim) }
    private var bodyColor: NSColor { (roles?.subtitle.nsColor ?? .secondaryLabelColor).blended(alpha: dim) }
    private func applyColors() {
        titleLabel.textColor = titleColor
        bodyLabel.textColor = bodyColor
        dismissButton.ink = bodyColor
    }

    public override func layout() {
        super.layout()
        // Offsets from the card top (measured at width 228: star y 101, "x" [W − 30, 98], title
        // y 123, card top y 89; the body's y is fitted so 12 pt stay under its second line).
        // Sidebar x W − 30 = card x (W − 14) − 23.
        dismissButton.frame = CGRect(x: bounds.width - 23, y: 9, width: 14, height: 14)
        titleLabel.frame = CGRect(x: 11, y: 34, width: max(0, bounds.width - 22), height: 16)
        bodyLabel.frame = CGRect(x: max(11, (bounds.width - 150) / 2), y: 52, width: min(150, max(0, bounds.width - 22)), height: 30)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let dark = content == .dark
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        // Inside: a little darker than the sidebar (dark, measured); light is a guess.
        (dark ? NSColor.black.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.025)).setFill()
        shape.fill()
        (dark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.22)).withAlphaComponent((dark ? 0.28 : 0.22) * (isDropTarget ? 1.6 : 1)).setStroke()
        shape.lineWidth = 1
        shape.setLineDash([5, 5], count: 2, phase: 0)
        shape.stroke()
        // Star disc: `star.circle.fill`, 17 pt, top centre (y 12).
        let star = CGRect(x: (bounds.width - 17) / 2, y: 12, width: 17, height: 17)
        if let symbol = NSImage(systemSymbolName: "star.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            symbol.drawTinted(in: star, color: titleColor)
        }
    }
}

private extension NSColor {
    func blended(alpha factor: CGFloat) -> NSColor { withAlphaComponent(alphaComponent * factor) }
}

/// The card's Dismiss "x" (ink about 7 × 8 pt in a 14 pt hit area). Hover plate: GUESS.
@MainActor
public final class FavoritesEmptyDismissButton: NSView {
    var onPress: (@MainActor () -> Void)?
    var ink: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        if hovered {
            ink.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let r = CGRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)
        let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round
        path.move(to: CGPoint(x: r.minX, y: r.minY)); path.line(to: CGPoint(x: r.maxX, y: r.maxY))
        path.move(to: CGPoint(x: r.maxX, y: r.minY)); path.line(to: CGPoint(x: r.minX, y: r.maxY))
        ink.setStroke(); path.stroke()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
