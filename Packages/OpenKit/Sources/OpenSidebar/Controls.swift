import AppKit
import OpenDesign
import OpenModel
import ImageIO

/// One-line text drawn with Core Text at an exact baseline, with tail
/// truncation. Content and color come from closures read inside `draw(_:)`
/// under Observation tracking, so the label redraws when the model values it
/// read change.
@MainActor
final class TextLabel: NSView {
    private(set) var lastDrawnText = ""
    /// Optional receipt for a real Core Text draw. Only mini-player titles install it.
    var onDrawnLine: (@MainActor (CTLine, String, Bool, CGFloat) -> Void)?
    private static let truncationToken = NSAttributedString.Key("OpenTextLabelTruncationToken")

    static func visibleText(_ line: CTLine, original: String) -> String {
        let source = original as NSString
        return (CTLineGetGlyphRuns(line) as! [CTRun]).map { run in
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if attrs[truncationToken.rawValue] as? Bool == true { return "…" }
            let range = CTRunGetStringRange(run)
            guard range.location >= 0, range.length >= 0, range.location + range.length <= source.length else { return "" }
            return source.substring(with: NSRange(location: range.location, length: range.length))
        }.joined()
    }
    var text: @MainActor () -> String = { "" } { didSet { needsDisplay = true } }
    var color: @MainActor () -> NSColor = { .labelColor } { didSet { needsDisplay = true } }
    var font: NSFont = Typography.tabTitle.font { didSet { needsDisplay = true } }
    /// Baseline, in points from the top of this view.
    var baseline: CGFloat = 15 { didSet { needsDisplay = true } }
    /// Text origin inside the view (Arc's text fields draw 2 pt inside their frame).
    var inset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Space kept free at the right end when the text truncates.
    var trailingInset: CGFloat = 0 { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

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
        ceil((text() as NSString).size(withAttributes: [.font: font]).width) + inset
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarDiagnostics.traceFolderView(self, "draw", rect: dirtyRect)
        if SidebarDiagnostics.measuresFolderTransitions { SidebarDiagnostics.folderTitleDraws += 1 }
        let (string, textColor) = tracked({ (text(), color()) }) { [weak self] in self?.needsDisplay = true }
        lastDrawnText = ""
        guard !string.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let available = bounds.width - inset - trailingInset
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        var wasTruncated = false
        if width > available {
            // Tail truncation, like Arc's titles ("Keepi…", F0079). A box too narrow
            // for even "…" (four-pane split rows) draws nothing rather than overflow.
            var tokenAttrs = attrs
            if onDrawnLine != nil { tokenAttrs[Self.truncationToken] = true }
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: tokenAttrs))
            guard available > 0, let truncated = CTLineCreateTruncatedLine(line, available, .end, token) else { return }
            line = truncated; wasTruncated = true
        }
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        var x = inset
        if alignment == .right { x = bounds.width - lineWidth } else if alignment == .center { x = (bounds.width - lineWidth) / 2 }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        lastDrawnText = string
        onDrawnLine?(line, string, wasTruncated, lineWidth)
        ctx.restoreGState()
    }
}

/// Template glyph tinted with a token color.
@MainActor
final class GlyphView: NSView {
    var glyph: Glyph? { didSet { if glyph != oldValue { needsDisplay = true } } }
    var image: @MainActor () -> NSImage? = { nil } { didSet { needsDisplay = true } }
    var tint: @MainActor () -> NSColor? = { nil } { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        SidebarDiagnostics.traceFolderView(self, "draw", rect: dirtyRect)
        let (img, color) = tracked({ (glyph?.image ?? image(), tint()) }) { [weak self] in self?.needsDisplay = true }
        guard let img else { return }
        let size = img.size
        let nudge = glyph?.spec.offset ?? .zero
        let rect = backingAlignedRect(NSRect(x: (bounds.width - size.width) / 2 + nudge.width, y: (bounds.height - size.height) / 2 + nudge.height,
                                             width: size.width, height: size.height), options: .alignAllEdgesNearest)
        if img.isTemplate, let color {
            img.drawTinted(in: rect, color: color)
        } else {
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

extension NSImage {
    /// Draws a template image filled with `color` into the current context.
    @MainActor func drawTinted(in rect: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Favicon for a tab: custom icon (emoji or SF Symbol), engine favicon, or a
/// letter fallback. Reads model state in `draw` under Observation tracking.
@MainActor
final class FaviconView: NSView {
    private(set) var lastDrawnImage: NSImage?
    private(set) var lastDrawnSource = "placeholder"
    weak var tab: Tab? { didSet { if tab !== oldValue { lastDrawnImage = nil; needsDisplay = true } } }
    weak var context: SidebarContext?
    var inkSize: CGFloat = SpaceListMetrics.faviconInk
    var fallbackTint: @MainActor () -> NSColor = { SidebarRole.secondaryText.nsColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func resolvedImage(for tab: Tab) -> (NSImage?, String) {
        // Unload keeps the old live PNG in the model. Once the host is gone,
        // resolve from storage so another page/report can replace that old icon.
        if (tab.live.hasWebContent || context?.storedFavicons == nil), let image = FaviconCache.image(for: tab.live.faviconPNG) {
            return (image, "live")
        }
        if let image = context?.faviconProvider?(tab) { return (image, "provider") }
        if let image = context?.storedFavicons?.image(for: tab.url) { return (image, "stored") }
        return (nil, "placeholder")
    }

    override func draw(_ dirtyRect: NSRect) {
        lastDrawnImage = nil; lastDrawnSource = "placeholder"
        guard let tab else { return }
        if SidebarDiagnostics.measuresFolderTransitions { SidebarDiagnostics.folderFaviconDraws += 1 }
        let (override, icon, resolved, host, tint) = tracked({
            (tab.iconOverride, tab.customIcon, resolvedImage(for: tab), tab.displayHost, fallbackTint())
        }) { [weak self] in
            self?.needsDisplay = true
        }
        let ink = backingAlignedRect(NSRect(x: (bounds.width - inkSize) / 2, y: (bounds.height - inkSize) / 2, width: inkSize, height: inkSize),
                                     options: .alignAllEdgesNearest)
        if let override {
            lastDrawnSource = "custom"
            NodeIconRenderer.draw(override, in: ink, tint: tint)
            return
        }
        if let icon, !icon.isEmpty {
            lastDrawnSource = "custom"
            if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                let img = symbol.withSymbolConfiguration(.init(pointSize: inkSize - 3, weight: .medium)) ?? symbol
                let s = img.size
                img.drawTinted(in: NSRect(x: ink.midX - s.width / 2, y: ink.midY - s.height / 2, width: s.width, height: s.height), color: tint)
            } else {
                EmojiRenderer.draw(icon, in: ink)
            }
            return
        }
        if let image = resolved.0 {
            lastDrawnImage = image; lastDrawnSource = resolved.1
            image.draw(in: ink, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        CustomIcon.letterFavicon(host.first.map(String.init) ?? "·", size: inkSize,
                                 fill: tint.withAlphaComponent(0.25), text: tint).draw(in: ink, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Typed icon resolution shared by tab and folder rows. Legacy tab drawing stays unchanged.
@MainActor
enum NodeIconRenderer {
    static func legacy(_ value: String?) -> SpaceIcon? {
        guard let value, !value.isEmpty else { return nil }
        return NSImage(systemSymbolName: value, accessibilityDescription: nil) == nil ? .emoji(value) : .symbol(value)
    }

    static func draw(_ icon: SpaceIcon, in ink: CGRect, tint: NSColor) {
        let name: String
        switch icon {
        case .emoji(let emoji): EmojiRenderer.draw(emoji, in: ink); return
        case .named(let identifier): name = NamedSpaceIcons.symbolName(for: identifier)
        case .symbol(let symbol): name = symbol
        }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: NamedSpaceIcons.fallbackSymbol, accessibilityDescription: nil) else { return }
        let image = symbol.withSymbolConfiguration(.init(pointSize: ink.height - 3, weight: .medium)) ?? symbol
        let size = image.size
        image.drawTinted(in: CGRect(x: ink.midX - size.width / 2, y: ink.midY - size.height / 2,
                                   width: size.width, height: size.height), color: tint)
    }
}

/// Emoji drawn to fit a box (Space icons, emoji tab icons).
@MainActor
enum EmojiRenderer {
    /// Draws `emoji` at `fontSize`, centered on its typographic box in `rect`.
    static func draw(_ emoji: String, fontSize: CGFloat? = nil, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: fontSize ?? rect.height * 0.82)
        let s = NSAttributedString(string: emoji, attributes: [.font: font])
        let b = s.size()
        s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2))
    }

    private static var grayCache: [String: NSImage] = [:]

    /// The emoji with its color removed (inactive switcher items): Rec. 709 luma
    /// of the sRGB values, alpha kept.
    static func grayscale(_ emoji: String, size: CGFloat) -> NSImage? {
        let key = "\(emoji)|\(size)"
        if let i = grayCache[key] { return i }
        let scale: CGFloat = 2
        let px = Int(size * 1.4 * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        draw(emoji, fontSize: size, in: NSRect(x: 0, y: 0, width: size * 1.4, height: size * 1.4))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: px * px * 4)
        for i in 0..<(px * px) {
            let r = Double(p[i * 4]), g = Double(p[i * 4 + 1]), b = Double(p[i * 4 + 2])
            let y = UInt8(min(255, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
            p[i * 4] = y; p[i * 4 + 1] = y; p[i * 4 + 2] = y
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: size * 1.4, height: size * 1.4))
        if grayCache.count > 64 { grayCache.removeAll() }
        grayCache[key] = image
        return image
    }
}

/// Live PNG cache; refuses large data/dimensions and decodes only 64 px.
/// Stored icons use StoredFaviconCache and decode on the store actor.
@MainActor
enum FaviconCache {
    private static var cache: [Data: NSImage] = [:]
    static func image(for data: Data?) -> NSImage? {
        guard let data, !data.isEmpty, data.count <= 512 * 1024 else { return nil }
        if let i = cache[data] { return i }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) <= 32,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 16, height: 16))
        // 128 decoded images <= 2 MiB. Engine reports are normalized to 64 px.
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[data] = image
        return image
    }
}

/// A plate button: glyph centered in a frame, a hover plate, a click action,
/// an optional menu and tooltip. Used for the toolbar, the bottom bar, the URL
/// field accessories, and row accessories.
@MainActor
class PlateButton: NSView {
    let glyphView = GlyphView()
    let plate = CALayer()
    var accessibleTitle: (@MainActor () -> String)?
    var action: (@MainActor () -> Void)?
    var menuProvider: (@MainActor () -> NSMenu?)?
    var tooltip: (@MainActor () -> Tooltip?)?
    var isEnabled: @MainActor () -> Bool = { true } { didSet { needsDisplay = true } }
    var glyphTint: @MainActor (_ enabled: Bool) -> NSColor = { enabled in
        (enabled ? SidebarRole.toolbarGlyph : SidebarRole.toolbarGlyphDisabled).nsColor
    } { didSet { needsDisplay = true } }
    var plateColor: @MainActor (_ pressed: Bool) -> DesignColor = { pressed in pressed ? SidebarRole.buttonPressed : SidebarRole.buttonHover }
    var plateRect: @MainActor (NSRect) -> NSRect = { $0 }
    var plateRadius: CGFloat = ChromeMetrics.buttonPlateRadius
    var showsHoverPlate = true
    /// Chrome glyphs (toolbar, bottom bar) take the disabled tone while the window
    /// is inactive: measured black ≈ 0.21–0.26 on the inactive capture vs 0.52–0.56 active.
    var dimsWhenInactive = false
    var inactiveTint: DesignColor = SidebarRole.toolbarGlyphDisabled
    /// Forced hover key for renders; compared against `SidebarContext.forcedHover`.
    var hoverKey: SidebarHoverTarget?
    weak var context: SidebarContext?
    private(set) var isPressed = false { didSet { needsDisplay = true } }
    private var pointerInside = false { didSet { if pointerInside != oldValue { needsDisplay = true; hoverChanged() } } }
    private var tracking: NSTrackingArea?

    init(glyph: Glyph?) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        plate.opacity = 0
        plate.cornerCurve = .continuous
        layer?.addSublayer(plate)
        glyphView.glyph = glyph
        addSubview(glyphView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var isHovered: Bool {
        if let key = hoverKey, let forced = context?.forcedHover { return forced == key }
        return pointerInside
    }

    override func layout() {
        super.layout()
        glyphView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = plateRect(bounds)
        plate.cornerRadius = plateRadius
        CATransaction.commit()
    }

    override func updateLayer() {
        let (enabled, hovered, active) = tracked({ (isEnabled(), isHovered, context?.isWindowActive ?? true) }) { [weak self] in self?.needsDisplay = true }
        let dim = dimsWhenInactive && !active
        glyphView.tint = { [glyphTint, inactiveTint] in dim ? inactiveTint.nsColor : glyphTint(enabled) }
        let appearance = contentAppearance
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.hoverFade)
        plate.backgroundColor = plateColor(isPressed).cgColor(appearance)
        plate.opacity = showsHoverPlate && enabled && (hovered || isPressed) ? 1 : 0
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

    private func hoverChanged() {
        guard let tooltip else { return }
        if pointerInside, let tip = tooltip() { TooltipController.shared.schedule(tip, for: self) } else { TooltipController.shared.cancel(for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled() else { return }
        TooltipController.shared.cancel(for: self)
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        } else {
            action?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) } else { super.rightMouseDown(with: event) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { accessibleTitle?() ?? tooltip?()?.title ?? super.accessibilityLabel() }
    override func isAccessibilityEnabled() -> Bool { isEnabled() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled() else { return false }
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            return true
        }
        action?()
        return action != nil
    }
}
