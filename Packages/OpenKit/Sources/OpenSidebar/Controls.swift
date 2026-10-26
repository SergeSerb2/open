import AppKit
import OpenDesign
import OpenModel

/// One-line text drawn at a fixed baseline with tail truncation. Content and
/// color come from closures read inside `draw(_:)`, so AppKit's automatic
/// observation tracking (macOS 26) redraws the label when the model changes.
@MainActor
final class TextLabel: NSView {
    var text: () -> String = { "" } { didSet { needsDisplay = true } }
    var color: () -> NSColor = { .labelColor } { didSet { needsDisplay = true } }
    var font: NSFont = Typography.tabTitle.font { didSet { needsDisplay = true } }
    /// Baseline, in points from the top of this view.
    var baseline: CGFloat = 15 { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Width of the current text at this font (for layout of trailing items).
    var textWidth: CGFloat {
        ceil((text() as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let string = text()
        guard !string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(), .paragraphStyle: style]
        let lineTop = baseline - font.ascender
        let rect = NSRect(x: 0, y: lineTop, width: bounds.width, height: ceil(font.ascender - font.descender) + 2)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

/// Template glyph tinted with a token color, drawn as layer contents.
@MainActor
final class GlyphView: NSView {
    var glyph: Glyph? { didSet { needsDisplay = true } }
    var image: () -> NSImage? = { nil } { didSet { needsDisplay = true } }
    var tint: () -> NSColor? = { nil } { didSet { needsDisplay = true } }
    var opacity: CGFloat = 1 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = glyph?.image ?? image() else { return }
        let size = img.size
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        if img.isTemplate, let color = tint() {
            img.tinted(color).draw(in: rect.integralIfNeeded, from: .zero, operation: .sourceOver, fraction: opacity)
        } else {
            img.draw(in: rect.integralIfNeeded, from: .zero, operation: .sourceOver, fraction: opacity)
        }
    }
}

extension NSRect {
    /// Pixel-aligns an origin at 1x when the size is whole points.
    var integralIfNeeded: NSRect {
        NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }
}

/// Favicon for a tab: custom icon (emoji / SF Symbol), engine favicon, or a
/// fallback. Reads model state in `draw`, so AppKit redraws it on change.
@MainActor
final class FaviconView: NSView {
    weak var tab: Tab? { didSet { needsDisplay = true } }
    weak var context: SidebarContext?
    var inkSize: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tab else { return }
        let ink = NSRect(x: (bounds.width - inkSize) / 2, y: (bounds.height - inkSize) / 2, width: inkSize, height: inkSize)
        if let icon = tab.customIcon, !icon.isEmpty {
            if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                let tinted = symbol.withSymbolConfiguration(.init(pointSize: inkSize - 2, weight: .regular)) ?? symbol
                tinted.isTemplate = true
                tinted.tinted(SidebarRole.secondaryText.nsColor).draw(in: ink)
            } else {
                drawEmoji(icon, in: ink)
            }
            return
        }
        if let image = context?.faviconProvider?(tab) ?? FaviconCache.image(for: tab.live.faviconPNG) {
            image.draw(in: ink, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        if let globe = Glyph.globe.image {
            let s = globe.size
            let r = NSRect(x: ink.midX - s.width / 2, y: ink.midY - s.height / 2, width: s.width, height: s.height)
            globe.tinted(SidebarRole.secondaryText.nsColor).draw(in: r.integralIfNeeded)
        }
    }

    private func drawEmoji(_ emoji: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: rect.height * 0.86)
        let s = NSAttributedString(string: emoji, attributes: [.font: font])
        let b = s.size()
        s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2))
    }
}

/// Decoded favicons by PNG bytes. Favicons are tiny; decoding on the main
/// thread costs microseconds and keeps redraws synchronous.
@MainActor
enum FaviconCache {
    private static var cache: [Data: NSImage] = [:]
    static func image(for data: Data?) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        if let i = cache[data] { return i }
        guard let i = NSImage(data: data) else { return nil }
        if cache.count > 512 { cache.removeAll() }
        cache[data] = i
        return i
    }
}

/// A plate button: glyph centered in a square, hover plate, click action.
/// Used for the toolbar (32×32), the bottom bar, and row accessories.
@MainActor
class PlateButton: NSView {
    let glyphView = GlyphView()
    private let plate = CALayer()
    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isEnabled: () -> Bool = { true } { didSet { needsDisplay = true } }
    var plateInset: CGFloat = 0
    var plateRadius: CGFloat = 8
    var showsHoverPlate = true
    private(set) var isPressed = false { didSet { updatePlate() } }
    var isHovered = false { didSet { if isHovered != oldValue { updatePlate() } } }
    private var tracking: NSTrackingArea?

    init(glyph: Glyph?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(plate)
        plate.opacity = 0
        glyphView.glyph = glyph
        addSubview(glyphView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        glyphView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds.insetBy(dx: plateInset, dy: plateInset)
        plate.cornerRadius = plateRadius
        plate.cornerCurve = .continuous
        CATransaction.commit()
    }

    override func updateLayer() {
        // Observation-tracked read: the enabled state comes from the model.
        let enabled = isEnabled()
        glyphView.alphaValue = 1
        glyphView.tint = { [weak self] in self?.glyphColor(enabled: enabled) }
        updatePlate()
    }

    func glyphColor(enabled: Bool) -> NSColor {
        (enabled ? SidebarRole.toolbarGlyph : SidebarRole.toolbarGlyphDisabled).nsColor
    }

    private func updatePlate() {
        let appearance = contentAppearance
        let show = showsHoverPlate && isEnabled() && (isHovered || isPressed)
        plate.backgroundColor = (isPressed ? SidebarColors.itemHoveredBackground : SidebarRole.toolbarHover).cgColor(appearance)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.hoverFade)
        plate.opacity = show ? 1 : 0
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled() else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            if let menu = menuProvider?() {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            } else {
                action?()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) } else { super.rightMouseDown(with: event) }
    }
}
