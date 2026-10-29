import AppKit
import OpenDesign

/// The (i) footer: the search-suggestion privacy notice as a black band at the bottom of the
/// panel (CC-42, S2 18/0044). Only (i) and Cmd+I show it; it never shows by itself (D14).
/// Same notice as Settings ▸ Profiles ("Code 4", `open.general.searchSuggestNoticeDismissed`).
@MainActor
final class PrivacyFooterView: NSView {
    let settingsButton = FooterButton(title: CommandBarText.searchSettings)
    let dismissButton = FooterButton(title: CommandBarText.dismissNotice)
    /// "here" in line 2. A transparent control over the drawn word: hit target, cursor, AX link.
    let link = FooterLink(frame: .zero)
    /// Line 2 links to Open's privacy page. Without a page the line hides: no dead link.
    var showsLearnMore = false {
        didSet {
            guard showsLearnMore != oldValue else { return }
            link.isHidden = !showsLearnMore
            needsDisplay = true
            needsLayout = true
        }
    }

    private let title = AccessibleText(role: .staticText)
    private let body = AccessibleText(role: .staticText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        link.isHidden = true
        for v in [settingsButton, dismissButton, link] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // The band takes every click and pointer move, so rows behind it never react.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Search suggestions privacy" }
    override func accessibilityChildren() -> [Any]? {
        title.update(parent: self, label: CommandBarText.privacyTitle, frame: Self.titleFrame(width: bounds.width))
        var children: [Any] = [title]
        if showsLearnMore {
            body.update(parent: self, label: CommandBarText.privacyLearnMorePrefix.trimmingCharacters(in: .whitespaces), frame: lineFrame(top: CommandBarMetrics.footerLine2Top, width: Self.prefixWidth))
            children += [body, link]
        }
        return children + [settingsButton, dismissButton]
    }

    // MARK: Layout and drawing (band coordinates, top-left origin)

    private static var titleFont: NSFont { FontToken(13, .bold).font }
    private static var bodyFont: NSFont { FontToken(13, .regular).font }
    private static var prefixWidth: CGFloat {
        TextLine(CommandBarText.privacyLearnMorePrefix, font: bodyFont, color: CommandBarRole.footerBody.cgColor).width
    }
    private static var linkWidth: CGFloat {
        TextLine(CommandBarText.privacyLinkWord, font: bodyFont, color: CommandBarRole.footerBody.cgColor).width
    }
    private static func titleFrame(width: CGFloat) -> CGRect {
        CGRect(x: CommandBarMetrics.footerTextX, y: CommandBarMetrics.footerLine1Top,
               width: ceil(TextLine(CommandBarText.privacyTitle, font: titleFont, color: CommandBarRole.footerTitle.cgColor).width), height: 16)
    }
    private func lineFrame(top: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: CommandBarMetrics.footerTextX, y: top, width: ceil(width), height: 16)
    }

    override func layout() {
        super.layout()
        let m = CommandBarMetrics.self
        let w = bounds.width
        dismissButton.frame = CGRect(x: w - m.footerDismissTrailing - m.footerDismissButtonWidth, y: m.footerButtonTop,
                                     width: m.footerDismissButtonWidth, height: m.footerButtonHeight)
        settingsButton.frame = CGRect(x: dismissButton.frame.minX - m.footerButtonGap - m.footerSettingsButtonWidth, y: m.footerButtonTop,
                                      width: m.footerSettingsButtonWidth, height: m.footerButtonHeight)
        link.frame = CGRect(x: m.footerTextX + Self.prefixWidth, y: m.footerLine2Top, width: ceil(Self.linkWidth), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = CommandBarMetrics.self
        ctx.setFillColor(CommandBarRole.footerBand.cgColor)
        ctx.fill(bounds)
        if let icon = SymbolCache.image("info.circle", size: 13, weight: .regular, color: CommandBarRole.footerIcon) {
            let f = m.footerIconFrame
            let s = icon.size
            icon.drawFlipped(in: CGRect(x: (f.midX - s.width / 2).rounded(), y: (f.midY - s.height / 2).rounded(), width: s.width, height: s.height))
        }
        TextLine(CommandBarText.privacyTitle, font: Self.titleFont, color: CommandBarRole.footerTitle.cgColor)
            .draw(at: m.footerTextX, baseline: m.footerLine1Top + m.footerTextBaseline, in: ctx)
        guard showsLearnMore else { return }
        let color = CommandBarRole.footerBody.cgColor
        let baseline = m.footerLine2Top + m.footerTextBaseline
        let prefix = Self.prefixWidth, word = Self.linkWidth
        TextLine(CommandBarText.privacyLearnMorePrefix, font: Self.bodyFont, color: color).draw(at: m.footerTextX, baseline: baseline, in: ctx)
        TextLine(CommandBarText.privacyLinkWord, font: Self.bodyFont, color: color).draw(at: m.footerTextX + prefix, baseline: baseline, in: ctx)
        TextLine(".", font: Self.bodyFont, color: color).draw(at: m.footerTextX + prefix + word, baseline: baseline, in: ctx)
        // "here" is underlined in the text color. guess (S2 18/0044 shows a 1 px line under it).
        let font = Self.bodyFont
        let y = (baseline - font.underlinePosition).rounded() + 0.5
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1, font.underlineThickness.rounded()))
        ctx.move(to: CGPoint(x: m.footerTextX + prefix, y: y))
        ctx.addLine(to: CGPoint(x: m.footerTextX + prefix + word, y: y))
        ctx.strokePath()
    }
}

/// "Search Settings…" and "Dismiss": a filled, edged rounded rect with a centered title.
@MainActor
final class FooterButton: NSView {
    let title: String
    var action: (() -> Void)?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        guard !isHiddenOrHasHiddenAncestor, let action else { return false }
        action()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = CommandBarMetrics.footerButtonRadius
        let outer = bounds
        let path = NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        CommandBarRole.footerButtonFill.nsColor.setFill()
        path.fill()
        CommandBarRole.footerButtonEdge.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = FontToken(13, .regular).font
        let line = TextLine(title, font: font, color: CommandBarRole.footerButtonTitle.cgColor)
        line.draw(at: (outer.midX - line.width / 2).rounded(), baseline: (outer.midY + font.capHeight / 2).rounded(), in: ctx)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// The "here" link in line 2: a pointing-hand cursor and an AX link over the drawn word.
@MainActor
final class FooterLink: NSView {
    var action: (() -> Void)?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .link }
    override func accessibilityLabel() -> String? { CommandBarText.privacyLinkWord }
    override func accessibilityPerformPress() -> Bool {
        guard !isHiddenOrHasHiddenAncestor, let action else { return false }
        action()
        return true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// A static-text AX child of a drawn view (the footer's two lines).
@MainActor
final class AccessibleText: NSAccessibilityElement {
    init(role: NSAccessibility.Role) {
        super.init()
        setAccessibilityRole(role)
    }

    func update(parent: NSView, label: String, frame: CGRect) {
        setAccessibilityParent(parent)
        setAccessibilityLabel(label)
        setAccessibilityValue(label)
        // Parent space is the parent's unflipped bounds.
        let y = parent.isFlipped ? parent.bounds.height - frame.maxY : frame.minY
        setAccessibilityFrameInParentSpace(CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
    }
}
