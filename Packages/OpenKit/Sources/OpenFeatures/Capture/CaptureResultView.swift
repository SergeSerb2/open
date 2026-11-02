import AppKit
import OpenDesign

/// The card a finished capture shows at the toast anchor (page-platform §4.6.5, guess pending
/// capture C-C1): the thumbnail, "Saved to Library" (not in incognito), and the action row.
/// Site Control panel chrome. No timer lives here; `CaptureController` owns the 8 s lifetime.
@MainActor
public final class CaptureResultView: NSView {
    public enum Action: String, CaseIterable, Sendable {
        case copy, save, share, library, retake, delete
        public var symbol: String {
            switch self {
            case .copy: "doc.on.doc"; case .save: "square.and.arrow.down"; case .share: "square.and.arrow.up"
            case .library: "photo.on.rectangle"; case .retake: "arrow.counterclockwise"; case .delete: "trash"
            }
        }
        public var title: String {
            switch self {
            case .copy: "Copy"; case .save: "Save…"; case .share: "Share"
            case .library: "Show in Library"; case .retake: "Retake"; case .delete: "Delete"
            }
        }
    }
    /// The buttons a capture gets: Retake only for area captures (PG-6.5 "Action to retake
    /// capture."); an unsaved (incognito) capture offers Copy, Save…, and Share only (§4.6.1).
    public static func actions(area: Bool, saved: Bool) -> [Action] {
        Action.allCases.filter { action in
            switch action {
            case .retake: area && saved
            case .library, .delete: saved
            default: true
            }
        }
    }

    public override var isFlipped: Bool { true }
    public let actions: [Action]
    public let showsSavedLine: Bool
    public let note: String?
    public private(set) var buttons: [Action: CaptureActionButton] = [:]
    public let thumbnail = NSImageView()
    public let savedLine = NSTextField(labelWithString: "Saved to Library")
    public let noteLine = NSTextField(labelWithString: "")
    public var onAction: ((Action, NSView) -> Void)?
    public var onHover: ((Bool) -> Void)?
    public private(set) var isHovered = false
    private let body = NSView()
    private let imageSize: CGSize

    /// `imageSize` in pixels; the thumbnail fits it into 224 × 160.
    public init(image: NSImage, imageSize: CGSize, actions: [Action], savedToLibrary: Bool, note: String? = nil) {
        self.actions = actions; self.showsSavedLine = savedToLibrary; self.note = note; self.imageSize = imageSize
        super.init(frame: CGRect(origin: .zero, size: Self.size(imageSize: imageSize, savedLine: savedToLibrary, note: note != nil)))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = CaptureMetrics.cardShadowAlpha
        layer?.shadowRadius = CaptureMetrics.cardShadowRadius; layer?.shadowOffset = CGSize(width: 0, height: -CaptureMetrics.cardShadowOffsetY)
        body.wantsLayer = true
        body.layer?.cornerRadius = CaptureMetrics.cardRadius; body.layer?.cornerCurve = .continuous; body.layer?.masksToBounds = true
        body.layer?.borderWidth = 1
        addSubview(body)
        thumbnail.image = image; thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = CaptureMetrics.thumbnailRadius; thumbnail.layer?.masksToBounds = true
        thumbnail.setAccessibilityLabel("Capture")
        body.addSubview(thumbnail)
        for line in [savedLine, noteLine] {
            line.font = CaptureMetrics.savedLineFont.font; line.textColor = Core.foregroundSecondary.nsColor; line.alignment = .center
            line.lineBreakMode = .byTruncatingTail
        }
        noteLine.stringValue = note ?? ""
        if savedToLibrary { body.addSubview(savedLine) }
        if note != nil { body.addSubview(noteLine) }
        for action in actions {
            let button = CaptureActionButton(action: action)
            button.target = self; button.action = #selector(pressed(_:))
            buttons[action] = button; body.addSubview(button)
        }
        setAccessibilityRole(.group); setAccessibilityLabel("Capture")
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Card size for an image: width 248; padding 12; thumbnail height ≤ 160; lines; the 28 pt row.
    public static func size(imageSize: CGSize, savedLine: Bool, note: Bool) -> CGSize {
        let m = CaptureMetrics.self
        var height = m.cardPadding + thumbnailSize(imageSize).height
        if savedLine { height += m.lineGap + m.savedLineHeight }
        if note { height += m.lineGap + m.savedLineHeight }
        height += m.lineGap + m.buttonSize + m.cardPadding
        return CGSize(width: m.cardWidth, height: height)
    }
    /// Aspect fit into the content width × 160.
    public static func thumbnailSize(_ imageSize: CGSize) -> CGSize {
        let maxWidth = CaptureMetrics.cardWidth - CaptureMetrics.cardPadding * 2, maxHeight = CaptureMetrics.thumbnailMaxHeight
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height)
        return CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    public override func layout() {
        super.layout()
        let m = CaptureMetrics.self
        body.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: m.cardRadius, cornerHeight: m.cardRadius, transform: nil)
        let thumb = Self.thumbnailSize(imageSize)
        thumbnail.frame = CGRect(x: ((bounds.width - thumb.width) / 2).rounded(), y: m.cardPadding, width: thumb.width, height: thumb.height)
        var y = thumbnail.frame.maxY
        let content = bounds.width - m.cardPadding * 2
        if showsSavedLine { y += m.lineGap; savedLine.frame = CGRect(x: m.cardPadding, y: y, width: content, height: m.savedLineHeight); y += m.savedLineHeight }
        if note != nil { y += m.lineGap; noteLine.frame = CGRect(x: m.cardPadding, y: y, width: content, height: m.savedLineHeight); y += m.savedLineHeight }
        y += m.lineGap
        let row = CGFloat(actions.count) * m.buttonSize + CGFloat(max(0, actions.count - 1)) * m.buttonGap
        var x = ((bounds.width - row) / 2).rounded()
        for action in actions {
            buttons[action]?.frame = CGRect(x: x, y: y, width: m.buttonSize, height: m.buttonSize)
            x += m.buttonSize + m.buttonGap
        }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        let appearance = contentAppearance
        body.layer?.backgroundColor = Core.popoverBackground.cgColor(appearance)
        body.layer?.borderColor = CaptureMetrics.cardEdge.cgColor(appearance)
        for button in buttons.values { button.needsDisplay = true }
    }

    @objc private func pressed(_ sender: CaptureActionButton) { onAction?(sender.captureAction, sender) }

    // Hover pauses the card's lifetime.
    private var tracking: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { setHovered(true) }
    public override func mouseExited(with event: NSEvent) { setHovered(false) }
    /// Also the automation entry for the hover-pause check.
    public func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered; onHover?(hovered)
    }
    /// Clicks on the card never reach the page below it.
    public override func mouseDown(with event: NSEvent) {}
}

/// One 28 × 28 action button: SF Symbol 15 pt, radius 6, a fill on hover and press.
@MainActor
public final class CaptureActionButton: NSButton {
    public let captureAction: CaptureResultView.Action
    private var hovered = false
    private var tracking: NSTrackingArea?
    public init(action: CaptureResultView.Action) {
        captureAction = action
        super.init(frame: .zero)
        isBordered = false; bezelStyle = .regularSquare; title = ""; setButtonType(.momentaryChange)
        let config = NSImage.SymbolConfiguration(pointSize: CaptureMetrics.buttonSymbolSize, weight: .regular)
        image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly; contentTintColor = Core.foregroundPrimary.nsColor
        toolTip = action.title; setAccessibilityLabel(action.title)
        wantsLayer = true; layer?.cornerRadius = CaptureMetrics.buttonRadius; layer?.cornerCurve = .continuous
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; updateFill() }
    public override func mouseExited(with event: NSEvent) { hovered = false; updateFill() }
    public override func highlight(_ flag: Bool) { super.highlight(flag); updateFill() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        let appearance = contentAppearance
        layer?.backgroundColor = isHighlighted ? CaptureMetrics.buttonPressed.cgColor(appearance)
            : hovered ? CaptureMetrics.buttonHover.cgColor(appearance) : nil
    }
}
