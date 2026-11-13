import AppKit
import OpenDesign
import OpenModel

/// Hover card for a Live Folder pull-request row (C-LF-1, Open's design, live-data §8; Arc's
/// `LiveItemPopoverViewModel {title, subtitle, icon, width}` and "%@ needs your review").
/// Folder-card family, 240 wide: the PR-state glyph, the PR title, "#N · owner/repo", and a
/// review line only when the PR awaits my review. Reads the row's stored facts only: no fetch.
@MainActor
public final class LiveItemPreviewView: NSView {
    public let context: SidebarContext
    public let tab: Tab
    public let info: LiveItemInfo
    private let glyph = PRStatusGlyphView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let reviewLabel = NSTextField(labelWithString: "")
    private var loops: [ObservationLoop] = []

    static let padding: CGFloat = 14
    static let glyphSize: CGFloat = 16
    static let textX: CGFloat = padding + glyphSize + 10

    public var subtitle: String { "#\(info.number) · \(info.repository)" }
    public var reviewLine: String? { info.awaitingMyReview && !info.author.isEmpty ? "\(info.author) needs your review" : nil }

    public init(context: SidebarContext, tab: Tab, info: LiveItemInfo) {
        self.context = context; self.tab = tab; self.info = info
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = HoverPreviewMetrics.radius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        glyph.status = info.status
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold); titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail; titleLabel.stringValue = tab.displayTitle
        subtitleLabel.font = .systemFont(ofSize: 12); subtitleLabel.stringValue = subtitle
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        reviewLabel.font = .systemFont(ofSize: 12); reviewLabel.stringValue = reviewLine ?? ""
        reviewLabel.lineBreakMode = .byTruncatingTail; reviewLabel.isHidden = reviewLine == nil
        for view in [glyph, titleLabel, subtitleLabel, reviewLabel] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel([tab.displayTitle, subtitle, reviewLine].compactMap { $0 }.joined(separator: ", "))
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }; _ = self.context.systemAppearance; _ = self.context.focusedSpace?.theme
        }) { [weak self] in self?.applyAppearance() })
        applyAppearance()
        frame.size = fittingSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loops.forEach { $0.cancel() } }
    public override var isFlipped: Bool { true }

    private var textWidth: CGFloat { HoverPreviewMetrics.folderWidth - Self.textX - Self.padding }
    private var titleHeight: CGFloat {
        ceil(titleLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? 17)
    }
    public override var fittingSize: NSSize {
        let lines: CGFloat = reviewLine == nil ? 1 : 2
        return CGSize(width: HoverPreviewMetrics.folderWidth, height: Self.padding + titleHeight + 4 + lines * 16 + Self.padding)
    }

    private func applyAppearance() {
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        self.appearance = appearance.nsAppearance
        layer?.backgroundColor = PreviewColors.background.cgColor(appearance)
        layer?.borderWidth = appearance == .dark ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        titleLabel.textColor = Core.foregroundPrimary.nsColor
        subtitleLabel.textColor = Core.foregroundSecondary.nsColor
        reviewLabel.textColor = Core.foregroundSecondary.nsColor
        glyph.needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let p = Self.padding, x = Self.textX, w = textWidth, title = titleHeight
        glyph.frame = CGRect(x: p, y: p + 1, width: Self.glyphSize, height: Self.glyphSize)
        titleLabel.frame = CGRect(x: x, y: p, width: w, height: title)
        subtitleLabel.frame = CGRect(x: x, y: p + title + 4, width: w, height: 16)
        reviewLabel.frame = CGRect(x: x, y: p + title + 4 + 16, width: w, height: 16)
    }
}

/// The PR-state glyph as a view (card header).
@MainActor
final class PRStatusGlyphView: NSView {
    var status: LiveItemInfo.Status = .open { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { PullRequestStatusGlyph.draw(status, in: bounds) }
}
