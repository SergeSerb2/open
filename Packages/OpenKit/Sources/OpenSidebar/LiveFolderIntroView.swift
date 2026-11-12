import AppKit
import OpenDesign

/// First-creation card beside a new Live Folder row (capture s5 b3; strings: live-data §2.2).
/// Measured: about 228 pt wide, vertically centred on the folder row, to the right of the
/// sidebar, with an arrow pointing at the row. Our own glyph (`PullRequestGlyph`),
/// never GitHub's mark. Type sizes, padding, radius and colours: GUESS — capture pending.
/// Arc's title shimmer is not reproduced (motion not measured).
@MainActor
public final class LiveFolderIntroView: NSView {
    public static let title = "Pull Requests"
    public static let body = "Pull requests from you and your team will show up here automatically"
    public static let width: CGFloat = 228
    static let arrow: CGFloat = 8
    static let padding: CGFloat = 14
    private let glyph = PullRequestGlyphView()
    private let titleLabel = NSTextField(labelWithString: LiveFolderIntroView.title)
    private let bodyLabel = NSTextField(wrappingLabelWithString: LiveFolderIntroView.body)
    private let appearanceValue: ContentAppearance

    public init(appearance: ContentAppearance) {
        appearanceValue = appearance
        super.init(frame: .zero)
        wantsLayer = true
        self.appearance = appearance.nsAppearance
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 12; shadow.shadowOffset = CGSize(width: 0, height: -3)
        self.shadow = shadow
        glyph.ink = Core.foregroundPrimary.resolved(appearance).nsColor
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Core.foregroundPrimary.resolved(appearance).nsColor
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = Core.foregroundPrimary.resolved(appearance).nsColor.withAlphaComponent(0.85)
        bodyLabel.preferredMaxLayoutWidth = Self.width - Self.arrow - 2 * Self.padding
        for view in [glyph, titleLabel, bodyLabel] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.popover)
        setAccessibilityLabel(Self.title + ". " + Self.body)
        frame.size = fittingSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }

    public override var fittingSize: NSSize {
        let textWidth = Self.width - Self.arrow - 2 * Self.padding
        let body = bodyLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 400)).height ?? 36
        return CGSize(width: Self.width, height: Self.padding + 22 + 6 + body + Self.padding)
    }

    public override func layout() {
        super.layout()
        let x = Self.arrow + Self.padding, textWidth = bounds.width - x - Self.padding
        glyph.frame = CGRect(x: x, y: Self.padding + 1, width: 20, height: 20)
        titleLabel.frame = CGRect(x: x + 26, y: Self.padding + 1, width: textWidth - 26, height: 20)
        let body = bodyLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 400)).height ?? 36
        bodyLabel.frame = CGRect(x: x, y: Self.padding + 28, width: textWidth, height: body)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let card = CGRect(x: Self.arrow, y: 0, width: bounds.width - Self.arrow, height: bounds.height)
        let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        let tip = NSBezierPath()
        tip.move(to: CGPoint(x: Self.arrow + 1, y: bounds.midY - Self.arrow))
        tip.line(to: CGPoint(x: 0, y: bounds.midY))
        tip.line(to: CGPoint(x: Self.arrow + 1, y: bounds.midY + Self.arrow))
        tip.close()
        path.append(tip)
        PreviewColors.background.resolved(appearanceValue).nsColor.setFill()
        path.fill()
        (appearanceValue == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}
