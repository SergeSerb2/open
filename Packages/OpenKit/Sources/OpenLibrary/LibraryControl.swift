import AppKit

@MainActor
final class LibraryControl: NSButton {
    override var isFlipped: Bool { true }
    var glyph: LibraryGlyph?
    var isTile = false
    var glyphSize: CGFloat?
    var isChip = false
    var keyboardFocus = false { didSet { needsDisplay = true } }
    var onKeyboardFocus: (() -> Void)?
    var showsDot = false
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    var foreground = NSColor.labelColor { didSet { needsDisplay = true } }
    var overlay = NSColor.labelColor { didSet { needsDisplay = true } }
    var baseAlpha: CGFloat = 0
    var labelSize: CGFloat = 14
    var onPress: (() -> Void)?
    var onArrow: ((Int) -> Void)?
    var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, glyph: LibraryGlyph? = nil, tile: Bool = false) {
        super.init(frame: .zero)
        self.title = title; self.glyph = glyph; isTile = tile
        isBordered = false; focusRingType = .none
        wantsLayer = true; layer?.cornerRadius = tile ? 12 : 10
        layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        target = self; action = #selector(press)
        setAccessibilityLabel(title)
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
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHighlighted ? 0.14 : selected ? 0.105 : hovered ? 0.05 : baseAlpha
        if alpha > 0 { overlay.withAlphaComponent(alpha).setFill(); bounds.fill() }
        if selected && isChip {
            foreground.withAlphaComponent(0.46).setStroke()
            let ring=NSBezierPath(roundedRect:bounds.insetBy(dx:0.75,dy:0.75),xRadius:10,yRadius:10);ring.lineWidth=1.5;ring.stroke()
        }
        if showsDot { foreground.setFill(); NSBezierPath(ovalIn:CGRect(x:bounds.width-8,y:5,width:4,height:4)).fill() }
        let color = foreground.withAlphaComponent(isEnabled ? selected ? 1 : 0.68 : 0.46)
        let font = NSFont.systemFont(ofSize: isTile ? 12 : labelSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font,.foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attrs)
        if isTile {
            glyph?.draw(in: CGRect(x: (bounds.width-28)/2, y: 17, width:28,height:28), color: color, selected:selected)
            (title as NSString).draw(at: CGPoint(x:(bounds.width-textSize.width)/2,y:51),withAttributes:attrs)
        } else {
            let iconWidth: CGFloat = glyph == nil ? 0 : glyphSize ?? (title.isEmpty ? 18 : 16)
            let group = textSize.width + (title.isEmpty || glyph == nil ? 0 : 5) + iconWidth
            let x = (bounds.width-group)/2
            glyph?.draw(in: CGRect(x:x,y:(bounds.height-iconWidth)/2,width:iconWidth,height:iconWidth),color:color)
            if !title.isEmpty { (title as NSString).draw(at: CGPoint(x:x+(glyph == nil ? 0 : iconWidth+5),y:(bounds.height-textSize.height)/2),withAttributes:attrs) }
        }
        if keyboardFocus && window?.firstResponder === self {
            foreground.withAlphaComponent(0.60).setStroke()
            let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:isTile ? 12 : 10,yRadius:isTile ? 12 : 10);focus.lineWidth=2;focus.stroke()
        }
    }
}
