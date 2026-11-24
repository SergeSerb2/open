import AppKit

@MainActor
final class LibraryControl: NSButton {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    private let iconLayer = CALayer()
    private let textLayer = LibraryText.layer()
    private let dotLayer = CALayer()
    private let chevronLayer = CALayer()
    /// A pop-up button: the label sits at the leading edge and a chevron at the trailing edge,
    /// so it does not read as another segment next to List and Gallery (UXE E6).
    var showsPopUpChevron = false { didSet { if showsPopUpChevron != oldValue { needsDisplay = true } } }
    /// The label Open draws in `textLayer`. NSButton's own title stays empty: when both were set,
    /// the button cell drew a second, unstyled label (rail items showed "Media" over the glyph and
    /// again below it; PB1 rail fix). VoiceOver reads the accessibility label set here.
    private var label = ""
    override var title: String {
        get { label }
        set {
            label = newValue
            if !super.title.isEmpty { super.title = "" }
            setAccessibilityLabel(newValue.isEmpty ? nil : newValue)
            needsDisplay = true
        }
    }
    override var attributedTitle: NSAttributedString {
        get { NSAttributedString(string: label) }
        set { title = newValue.string }
    }
    /// Labels this control draws: its own text layer, plus NSButton's cell title if one is set.
    var drawnLabelCount: Int { (textLayer.isHidden || label.isEmpty ? 0 : 1) + (super.title.isEmpty ? 0 : 1) }
    var glyph: LibraryGlyph?
    var isTile = false
    var glyphSize: CGFloat?
    var isChip = false
    var keyboardFocus = false { didSet { if keyboardFocus != oldValue { needsDisplay = true } } }
    var onKeyboardFocus: (() -> Void)?
    var showsDot = false { didSet { if showsDot != oldValue { needsDisplay = true } } }
    /// The dot as drawn: the layer's pending update applied first. Read by
    /// `LibraryPanelView.automationState()`, which every build compiles.
    var drawnDot: Bool { layer?.displayIfNeeded(); return !dotLayer.isHidden }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } } }
    var foreground = NSColor.labelColor { didSet { if foreground != oldValue { needsDisplay = true } } }
    var overlay = NSColor.labelColor { didSet { if overlay != oldValue { needsDisplay = true } } }
    var baseAlpha: CGFloat = 0
    var labelSize: CGFloat = 14
    var onPress: (() -> Void)?
    var onArrow: ((Int) -> Void)?
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    /// False keeps an enabled control out of the key-view loop (mouse and AXPress still work).
    var allowsKeyView = true
    override var acceptsFirstResponder: Bool { isEnabled && allowsKeyView }
    override var canBecomeKeyView: Bool { isEnabled && allowsKeyView && !isHiddenOrHasHiddenAncestor }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, glyph: LibraryGlyph? = nil, tile: Bool = false) {
        super.init(frame: .zero)
        self.title = title; self.glyph = glyph; isTile = tile
        isBordered = false; focusRingType = .none
        wantsLayer = true; layer?.cornerRadius = tile ? 12 : 10
        layer?.cornerCurve = .continuous; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(iconLayer); layer?.addSublayer(textLayer); layer?.addSublayer(dotLayer); layer?.addSublayer(chevronLayer)
        chevronLayer.contentsGravity = .resizeAspect; chevronLayer.isHidden = true
        dotLayer.cornerRadius = 2
        iconLayer.contentsGravity = .resizeAspect
        target = self; action = #selector(press)
        if tile { setAccessibilityRole(.radioButton) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func press() { onPress?() }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { onKeyboardFocus?(); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if let onArrow, [123,124,125,126].contains(event.keyCode) { onArrow(event.keyCode == 123 || event.keyCode == 126 ? -1 : 1); return }
        if event.keyCode == 36 || event.keyCode == 49 { performClick(nil); return }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        LibraryRaster.note("trackingUpdates")
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func layout() { super.layout(); needsDisplay = true }
    override func updateLayer() {
        let alpha: CGFloat = isHighlighted ? 0.14 : selected ? 0.105 : hovered ? 0.05 : baseAlpha
        layer?.backgroundColor = overlay.withAlphaComponent(alpha).cgColor
        let focus = keyboardFocus && window?.firstResponder === self
        layer?.borderWidth = focus ? 2 : selected && isChip ? 1.5 : 0
        layer?.borderColor = foreground.withAlphaComponent(focus ? 0.60 : 0.46).cgColor
        dotLayer.isHidden = !showsDot; dotLayer.backgroundColor = foreground.cgColor
        dotLayer.frame = CGRect(x:bounds.width-8,y:5,width:4,height:4)
        let color = foreground.withAlphaComponent(isEnabled ? selected ? 1 : 0.68 : 0.46)
        let text = LibraryText.value(title,size:isTile ? 12 : labelSize,weight:.semibold,color:color)
        let textSize = text.size()
        if (textLayer.string as? NSAttributedString) !== text { textLayer.string = text }; textLayer.contentsScale = window?.backingScaleFactor ?? 2
        iconLayer.isHidden = glyph == nil
        // A tile keeps Arc's 80 pt geometry (glyph top 17, label top 51). A short window gives the
        // rail shorter tiles (LibraryPanelView.railMetrics): glyph and label then stay centred as one
        // group, and the glyph shrinks only when the label would not fit (UXE E1).
        let compact = isTile && bounds.height < 80
        let tileGlyph: CGFloat = compact ? max(16, min(28, bounds.height - 25)) : 28
        let tileTop: CGFloat = compact ? max(2, ((bounds.height - (tileGlyph + 5 + ceil(textSize.height))) / 2).rounded()) : 17
        let iconWidth: CGFloat = isTile ? tileGlyph : glyph == nil ? 0 : glyphSize ?? (title.isEmpty ? 18 : 16)
        let gap: CGFloat = title.isEmpty || glyph == nil ? 0 : 5
        // A label wider than the control (a long Profile or Space name in a filter chip) keeps the
        // chip's inner padding and ends in "…" (LibraryTextLayer truncates); labels that fit are unchanged.
        let natural = ceil(textSize.width), room = bounds.width-iconWidth-gap
        let textWidth = !isTile && natural > room ? max(0,room-(isChip ? 24 : 16)) : natural
        let group = (textWidth < natural ? textWidth : textSize.width) + gap + iconWidth
        let x = (bounds.width-group)/2
        iconLayer.frame = CGRect(x:isTile ? (bounds.width-tileGlyph)/2 : x,y:isTile ? tileTop : (bounds.height-iconWidth)/2,width:iconWidth,height:iconWidth)
        if let glyph { iconLayer.contents = glyph.image(size:iconWidth,color:color,selected:selected,scale:window?.backingScaleFactor ?? 2) }
        textLayer.frame = CGRect(x:isTile ? (bounds.width-textSize.width)/2 : x+(glyph == nil ? 0 : iconWidth+5),y:isTile ? (compact ? tileTop+tileGlyph+5 : 51) : (bounds.height-textSize.height)/2,width:textWidth,height:ceil(textSize.height))
        textLayer.isHidden = title.isEmpty
        chevronLayer.isHidden = !showsPopUpChevron
        if showsPopUpChevron {
            let scale = window?.backingScaleFactor ?? 2, chevron = CGSize(width:8,height:11)
            let room = max(0,bounds.width-12-chevron.width-6-10)
            textLayer.frame = CGRect(x:12,y:(bounds.height-textSize.height)/2,width:min(ceil(textSize.width),room),height:ceil(textSize.height))
            chevronLayer.frame = CGRect(x:bounds.width-10-chevron.width,y:(bounds.height-chevron.height)/2,width:chevron.width,height:chevron.height)
            chevronLayer.contentsScale = scale
            chevronLayer.contents = Self.chevron(color:color,scale:scale)
        }
    }
    /// The pop-up's up-and-down chevron (SF Symbol), tinted with the label colour.
    private static func chevron(color: NSColor, scale: CGFloat) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize:9,weight:.semibold).applying(.init(paletteColors:[color]))
        guard let symbol = NSImage(systemSymbolName:"chevron.up.chevron.down",accessibilityDescription:nil)?.withSymbolConfiguration(configuration) else { return nil }
        var rect = CGRect(origin:.zero,size:symbol.size)
        let context = NSGraphicsContext.current
        let hints: [NSImageRep.HintKey:Any] = [.ctm:NSAffineTransform(transform:AffineTransform(scale:scale))]
        return symbol.cgImage(forProposedRect:&rect,context:context,hints:hints)
    }
}
