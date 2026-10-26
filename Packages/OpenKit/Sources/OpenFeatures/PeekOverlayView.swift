import AppKit
import OpenDesign

@MainActor
public final class PeekOverlayView: NSView {
    public let panel = NSView()
    public let pageClip = NSView()
    public private(set) var buttons: [NSButton] = []
    public var contentRect = CGRect.zero { didSet { needsLayout = true } }
    /// The measured Peek base includes the window's right margin with an anchored sidebar.
    public var baseWidth: CGFloat = 0 { didSet { needsLayout = true } }
    public var onDismiss: (() -> Void)?
    public var onExpand: (() -> Void)?
    public var onSplit: (() -> Void)?
    public var scrimColor = NSColor.black.withAlphaComponent(0.55) { didSet { layer?.backgroundColor = scrimColor.cgColor } }
    public var controlsFill = NSColor.black { didSet { buttons.forEach { ($0 as? ActionButton)?.circleFill = controlsFill } } }
    public init() {
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = scrimColor.cgColor
        panel.wantsLayer = true; pageClip.wantsLayer = true; pageClip.layer?.masksToBounds = true
        pageClip.layer?.cornerRadius = PanelMetrics.cornerRadius; pageClip.layer?.backgroundColor = NSColor.black.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = PeekMetrics.shadowOpacity
        panel.layer?.shadowRadius = PeekMetrics.shadowRadius; panel.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(panel); panel.addSubview(pageClip)
        let specs = [("xmark", "Close", "confirmCloseModal"), ("arrow.up.left.and.arrow.down.right", "Enter Full Screen", "openInSpaceExpander"), ("square.split.2x1", "Open in Split View", "openInSplit")]
        for (i, spec) in specs.enumerated() {
            let button = ActionButton(symbol: spec.0, title: spec.1) { [weak self] in
                switch i { case 0: self?.onDismiss?(); case 1: self?.onExpand?(); default: self?.onSplit?() }
            }
            button.wantsLayer = true; button.circleFill = controlsFill
            button.contentTintColor = PeekMetrics.defaultGlyph.nsColor
            button.setAccessibilityIdentifier(spec.2); button.identifier = .init(spec.2)
            addSubview(button); buttons.append(button)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() {
        super.layout(); let width = round(baseWidth * PeekMetrics.widthFraction)
        panel.frame = CGRect(x: contentRect.minX + (baseWidth - width) / 2, y: contentRect.minY + PeekMetrics.verticalInset,
                             width: width, height: max(0, contentRect.height - 2 * PeekMetrics.verticalInset))
        layoutPanel()
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: panel.frame.maxX + PeekMetrics.buttonGap, y: panel.frame.maxY - PeekMetrics.buttonTop - CGFloat(i) * PeekMetrics.buttonPitch - PeekMetrics.buttonDiameter,
                             width: PeekMetrics.buttonHitWidth, height: PeekMetrics.buttonDiameter)
        }
    }
    func layoutPanel() {
        pageClip.frame = panel.bounds
        pageClip.subviews.forEach { $0.frame = pageClip.bounds }
        panel.layer?.shadowPath = CGPath(roundedRect: panel.bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
    }
    func clearHost() { pageClip.subviews.forEach { $0.removeFromSuperview() } }
    func showHost(_ host: any WebContentHost) {
        pageClip.subviews.forEach { $0.removeFromSuperview() }
        pageClip.addSubview(host.view); host.view.frame = pageClip.bounds; host.view.autoresizingMask = [.width, .height]
        host.view.alphaValue = host.isLoading ? 0 : 1
    }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onDismiss?() }
    }
}
