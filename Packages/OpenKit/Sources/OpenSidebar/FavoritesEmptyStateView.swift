import AppKit
import OpenDesign

/// The Favorites empty-state card (audit A3). Arc shows it in a Profile without Favorites until the
/// user dismisses it (`sidebarFavoritesEmptyStateDismissButton`; `topAppsEmptyStateDismissedForProfiles`).
///
/// Measured (interaction-states §20.3, S2 07/0001; C-report-s10 (a), capture PB5-c):
/// - Geometry from the section top: card at +7 (95 pt tall, 7 pt in); star 16.5 pt at +19.5; "×"
///   14 × 14, 16 pt from the top and right; title at +41.5 (13 Semibold); body at +61.5 (11.5 Regular,
///   150 pt wide). At the narrowest sidebar the title takes two lines and the body three, and the
///   card grows by the extra lines (section 136.5 against 105.5).
/// - Colours follow the Space theme. The rules below reproduce the three measured sets (light
///   default, red preset, dark default) to within a few 8-bit steps:
///   light content (light default `#DEDCF2` sidebar, and the red preset in light and dark): fill =
///   white 0.14 over the sidebar (`#E1E0F5`, red `#F2A1A8`); title = the sidebar title ink
///   (`#090D4E`, red `#360009`); body and "×" = that ink at 0.70 (`#4A4C81`, red `#6E2F39`); star
///   disc = the title ink × 3.35 per sRGB channel, clamped (`#202BFF`, red `#B60021`), white star;
///   outline = the disc colour at 0.30 (`#A2A6FB`, red `#DF6C75` / `#D05D67`).
///   Dark content (the dark default, measured in session 2: fill `#202035` on `#252538`, outline
///   `#616173`, disc `#EDEEFF` with a `#262471` star, title `#DEDFFF`, body `#A5A7C4`): fill = black
///   0.12; outline = white 0.28; star disc = the title ink with a dark star; body = title at 0.70.
/// - Hover: nothing on the card; a round grey plate behind "×"; no tooltip.
/// - Drag over the section: the content fades to about half and the outline becomes a soft solid
///   light border.
@MainActor
public final class FavoritesEmptyStateView: NSView {
    public static let title = "Drag to add Favorites"
    public static let body = "Favorites keep your most used sites and apps close"
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 11.5)
    private let titleLabel = NSTextField(wrappingLabelWithString: FavoritesEmptyStateView.title)
    private let bodyLabel = NSTextField(wrappingLabelWithString: FavoritesEmptyStateView.body)
    public let dismissButton = FavoritesEmptyDismissButton()
    private var roles: SidebarRoles?
    private var content: ContentAppearance = .dark
    var onDismiss: (@MainActor () -> Void)? { didSet { dismissButton.onPress = onDismiss } }
    public var isDropTarget = false { didSet { if isDropTarget != oldValue { applyColors(); needsDisplay = true } } }

    /// Text sizes at a card width: one title line is 16 pt and two body lines are 30 pt (measured).
    static func textHeights(cardWidth: CGFloat) -> (title: CGFloat, body: CGFloat, bodyWidth: CGFloat) {
        func lines(_ text: String, _ font: NSFont, _ width: CGFloat) -> Int {
            let box = (text as NSString).boundingRect(with: CGSize(width: max(1, width), height: 1_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: [.font: font])
            let line = font.ascender - font.descender + font.leading
            return max(1, Int((box.height / line).rounded()))
        }
        let titleWidth = max(1, cardWidth - 22), bodyWidth = min(150, titleWidth)
        return (CGFloat(lines(title, titleFont, titleWidth)) * 16, CGFloat(max(2, lines(body, bodyFont, bodyWidth))) * 15, bodyWidth)
    }
    /// Card height at a sidebar width: 95 with one title line and two body lines.
    public static func cardHeight(sidebarWidth: CGFloat) -> CGFloat {
        let t = textHeights(cardWidth: FavoritesMetrics.emptyCardFrame(sidebarWidth: sidebarWidth).width)
        return 95 + (t.title - 16) + (t.body - 30)
    }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = Self.titleFont; titleLabel.alignment = .center; titleLabel.maximumNumberOfLines = 2
        bodyLabel.font = Self.bodyFont; bodyLabel.alignment = .center; bodyLabel.maximumNumberOfLines = 3
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
    private var isDark: Bool { content == .dark }
    private var fade: CGFloat { isDropTarget ? 0.5 : 1 }
    private var titleInk: NSColor { roles?.title.nsColor ?? .labelColor }
    private var titleColor: NSColor { titleInk.withAlphaComponent(titleInk.alphaComponent * fade) }
    private var bodyColor: NSColor { titleInk.withAlphaComponent(titleInk.alphaComponent * 0.70 * fade) }
    /// Light content: the title ink × 3.35 per sRGB channel (fits `#202BFF` from `#090D4E` and
    /// `#B60021` from `#360009`); dark content: the title ink itself (measured `#EDEEFF`).
    private var discColor: NSColor {
        isDark ? titleInk : Self.accentColor(titleInk: titleInk)
    }
    /// Shared bright Space accent: the light title role, amplified as measured in PB5-c.
    static func accentColor(titleInk: NSColor) -> NSColor {
        guard let c = titleInk.usingColorSpace(.sRGB) else { return titleInk }
        return NSColor(srgbRed: min(1, c.redComponent * 3.35), green: min(1, c.greenComponent * 3.35), blue: min(1, c.blueComponent * 3.35), alpha: 1)
    }
    static func cardFillColor(_ appearance: ContentAppearance) -> NSColor {
        appearance == .dark ? NSColor.black.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.14)
    }
    /// The card's resolved colours as sRGB hex with alpha (checks read them; the drawing uses the same values).
    public var resolvedColors: [String: String] {
        func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02X%02X%02X@%.2f", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()), c.alphaComponent)
        }
        return ["title": hex(titleColor), "body": hex(bodyColor), "disc": hex(discColor), "outline": hex(outlineColor), "fill": hex(fillColor),
                "dismissPlate": hex(dismissButton.plate), "content": isDark ? "dark" : "light"]
    }
    private var fillColor: NSColor { Self.cardFillColor(content) }
    private var outlineColor: NSColor {
        if isDropTarget { return NSColor.white.withAlphaComponent(isDark ? 0.35 : 0.55) }
        return isDark ? NSColor.white.withAlphaComponent(0.28) : discColor.withAlphaComponent(0.30)
    }
    private func applyColors() {
        titleLabel.textColor = titleColor
        bodyLabel.textColor = bodyColor
        dismissButton.ink = bodyColor
        dismissButton.plate = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)
    }

    public override func layout() {
        super.layout()
        // Offsets from the card top = section offsets − 7 (C-report-s10 (a) 1).
        let t = Self.textHeights(cardWidth: bounds.width)
        dismissButton.frame = CGRect(x: bounds.width - 23, y: 9, width: 14, height: 14)   // sidebar x W − 30
        titleLabel.frame = CGRect(x: 11, y: 34.5, width: max(0, bounds.width - 22), height: t.title)
        bodyLabel.frame = CGRect(x: (bounds.width - t.bodyWidth) / 2, y: 54.5 + (t.title - 16), width: t.bodyWidth, height: t.body)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        fillColor.setFill()
        shape.fill()
        shape.lineWidth = 1
        // Dashed at rest; a soft solid light border while a tab or link is held over the section.
        outlineColor.setStroke()
        if !isDropTarget { shape.setLineDash([5, 5], count: 2, phase: 0) }
        shape.stroke()
        // Star disc 16.5 pt at the top centre (card y 12.5): a filled disc with the star cut in the other ink.
        let disc = CGRect(x: (bounds.width - 16.5) / 2, y: 12.5, width: 16.5, height: 16.5)
        discColor.withAlphaComponent(discColor.alphaComponent * fade).setFill()
        NSBezierPath(ovalIn: disc).fill()
        let starInk: NSColor = isDark ? NSColor(srgbRed: 0x26 / 255, green: 0x24 / 255, blue: 0x71 / 255, alpha: 1) : .white
        if let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold)) {
            let size = symbol.size
            symbol.drawTinted(in: CGRect(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2, width: size.width, height: size.height),
                              color: starInk.withAlphaComponent(fade))
        }
    }
}

/// The card's Dismiss "×" (ink about 7 × 8 pt in a 14 pt hit area). Hover: a round grey plate
/// (measured `#D4D2E1` on the light default card; C-report-s10 (a) 3).
@MainActor
public final class FavoritesEmptyDismissButton: NSView {
    var onPress: (@MainActor () -> Void)?
    var ink: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var plate: NSColor = NSColor.black.withAlphaComponent(0.06)
    private var hovered = false
    private var tracking: NSTrackingArea?
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        if hovered {
            plate.setFill()
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
