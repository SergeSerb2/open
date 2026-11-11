import AppKit
import OpenDesign

/// What the status button under the URL field shows (page-platform §4.7.3). Generic, so Share
/// Quote (§4.2.5, Step 15) can reuse the button: a title, a short title for narrow sidebars, an SF
/// Symbol, a busy state, and the intent it sends.
public struct URLStatusItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case translation, shareQuote }
    public var action: Action
    public var title: String
    /// Shown when the button is `URLStatusMetrics.compactWidth` wide or less (PG-7.3: "Translation…").
    public var compactTitle: String
    public var symbol: String
    /// A 12 pt spinner replaces the symbol ("Translating…").
    public var isBusy: Bool
    public init(action: Action, title: String, compactTitle: String? = nil, symbol: String, isBusy: Bool = false) {
        self.action = action; self.title = title; self.compactTitle = compactTitle ?? title; self.symbol = symbol; self.isBusy = isBusy
    }
}

/// The button itself: the URL field's fill and radius 8, symbol + 6 pt + title centered, sidebar
/// secondary text color (§4.7.3, values guess pending capture C-R1). A click sends
/// `.showTranslation(anchor:)` or `.shareQuote(anchor:)` with its frame in window coordinates.
@MainActor
final class URLStatusButton: NSView {
    unowned let context: SidebarContext
    private let fill = CALayer()
    private let symbol = NSImageView()
    private let label = TextLabel()
    private var spinner: NSProgressIndicator?
    private var pointerInside = false { didSet { if pointerInside != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        label.font = Typography.statusButton.font
        label.text = { [weak self] in self?.currentTitle ?? "" }
        label.color = { SidebarRole.secondaryText.nsColor }
        addSubview(symbol); addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var item: URLStatusItem? { context.urlStatus }
    /// PG-7.3: the short title at a button width of 200 pt or less.
    var currentTitle: String {
        guard let item else { return "" }
        return bounds.width <= URLStatusMetrics.compactWidth ? item.compactTitle : item.title
    }

    override func updateLayer() {
        let hovered = context.forcedHover == .urlStatus || pointerInside
        CATransaction.begin(); CATransaction.setAnimationDuration(Motion.hoverFade)
        fill.backgroundColor = URLFieldView.fill(context: context, hovered: hovered).cgColor(contentAppearance)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds; fill.cornerRadius = URLStatusMetrics.cornerRadius
        CATransaction.commit()
        let item = tracked({ self.item }) { [weak self] in self?.needsLayout = true; self?.label.needsDisplay = true }
        let m = URLStatusMetrics.self
        let font = Typography.statusButton.font
        let title = currentTitle
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let leading = item?.isBusy == true ? m.spinnerSize : m.symbolSize
        let total = min(bounds.width - 16, leading + m.symbolToTitle + textWidth)
        let x = max(8, (bounds.width - total) / 2)
        let glyphFrame = CGRect(x: x, y: (bounds.height - leading) / 2, width: leading, height: leading)
        if let item, !item.isBusy {
            // The palette color is resolved for this view's appearance (the label's color).
            let tint = SidebarRole.secondaryText.resolved(ContentAppearance(effectiveAppearance)).nsColor
            let config = NSImage.SymbolConfiguration(pointSize: m.symbolSize, weight: .medium).applying(.init(paletteColors: [tint, tint]))
            symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            symbol.isHidden = false
        } else { symbol.isHidden = true }
        symbol.frame = glyphFrame
        if item?.isBusy == true {
            let s = spinner ?? { let p = NSProgressIndicator(); p.style = .spinning; p.controlSize = .small; p.isDisplayedWhenStopped = false; addSubview(p); spinner = p; return p }()
            s.frame = glyphFrame; s.isHidden = false
            if window != nil { s.startAnimation(nil) }
        } else if let spinner { spinner.stopAnimation(nil); spinner.isHidden = true }
        let tx = glyphFrame.maxX + m.symbolToTitle
        // Baseline: 12 pt Medium centered in the 28 pt height.
        label.baseline = round((bounds.height + font.capHeight) / 2)
        label.frame = CGRect(x: tx, y: 0, width: max(0, min(bounds.width - 8 - tx, textWidth + 2)), height: bounds.height)
        label.needsDisplay = true
        setAccessibilityLabel(item?.title)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true; needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner?.stopAnimation(nil) } else { needsLayout = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }
    override func accessibilityPerformPress() -> Bool { press() }

    /// Sends the item's intent with this button's frame in window coordinates.
    @discardableResult func press() -> Bool {
        guard let item, !isHidden else { return false }
        let anchor = convert(bounds, to: nil)
        switch item.action {
        case .translation: return context.send(.showTranslation(anchor: anchor))
        case .shareQuote: return context.send(.shareQuote(anchor: anchor))
        }
    }
    var displayedTitle: String { label.lastDrawnText }
}
