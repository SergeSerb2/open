import AppKit
import OpenDesign

/// One line of text set with Core Text. Built once per string, font, and color, then
/// drawn at an exact baseline. Width queries do not draw.
@MainActor
struct TextLine {
    let line: CTLine
    let width: CGFloat

    init(_ string: String, font: NSFont, color: CGColor, boldRanges: [Range<Int>] = []) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if boldRanges.isEmpty {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        } else {
            let text = NSMutableAttributedString(string: string, attributes: attrs)
            for range in boldRanges.prefix(256) where range.lowerBound >= 0 && range.upperBound <= text.length {
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: NSRange(location: range.lowerBound, length: range.count))
            }
            line = CTLineCreateWithAttributedString(text)
        }
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private init(line: CTLine) {
        self.line = line
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The line cut to `maxWidth` with "…" at the end or in the middle.
    func truncated(to maxWidth: CGFloat, mode: CTLineTruncationType = .end, font: NSFont, color: CGColor) -> TextLine {
        guard width > maxWidth else { return self }
        guard maxWidth > 0 else { return TextLine("", font: font, color: color) }
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: color]))
        guard let cut = CTLineCreateTruncatedLine(line, Double(maxWidth), mode, token) else { return self }
        return TextLine(line: cut)
    }

    /// Draws with the baseline at `y` in a flipped context.
    func draw(at x: CGFloat, baseline y: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// SF Symbols tinted with a token color, cached by name, size, weight, and color.
@MainActor
enum SymbolCache {
    private struct Key: Hashable { var name: String; var size: CGFloat; var weight: CGFloat; var color: RGBA; var scale: CGFloat }
    private static var cache: [Key: NSImage] = [:]

    /// Backing scale of the context being drawn into (1 or 2); 2 outside a draw pass.
    static var currentScale: CGFloat {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return 2 }
        return ctx.userSpaceToDeviceSpaceTransform.a.magnitude > 1.5 ? 2 : 1
    }

    /// The tinted symbol as one bitmap at the current drawing scale, rendered once. Every layer
    /// of the symbol at full strength, then the token color (palette configurations dim
    /// secondary layers). One bitmap per scale: an image that also held a 2x bitmap would be
    /// downsampled into a 1x context. Drawing the vector each time cost ≈ 0.6 ms per keystroke.
    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: RGBA, scale explicitScale: CGFloat? = nil) -> NSImage? {
        let scale = explicitScale ?? currentScale
        let key = Key(name: name, size: size, weight: weight.rawValue, color: color, scale: scale)
        if let i = cache[key] { return i }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) else { return nil }
        let template = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? base
        template.isTemplate = true
        let w = Int((template.size.width * scale).rounded(.up)), h = Int((template.size.height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB) else { return nil }
        rep.size = NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: template.size)
        template.draw(in: rect)
        color.nsColor.set()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Glyph specs for the bar. Sizes are tuned so the 1x ink matches Arc's (measured boxes).
enum BarGlyph {
    /// Input magnifier: ink 12×12 in the 18 pt frame (F0063 751…762 × 554…565).
    static let inputSymbolSize: CGFloat = 15
    static let inputSymbolWeight: NSFont.Weight = .medium
    /// fitted: ink centered in the 18 pt frame (F0063 magnifier at 751…762 × 554…565).
    static let inputSymbolOffsetY: CGFloat = 0
    /// Row symbols (magnifier, globe): ink 11–12 pt (F0052 rows). fitted.
    /// fitted on Arc's ink: magnifier 12×12, globe 12×13 (F0052, F0048). SF Symbol art can change
    /// with the OS (sizes were re-fitted on macOS 27.2, build 26B5112a).
    /// D3 card: the search glyph 14 pt (16 pt box in the mock-up). Action glyphs on a plate 13.
    static func rowSymbolSize(_ name: String) -> CGFloat { 14 }
    /// Arrow in the selected row's 20 pt key cap (13 pt box in the mock-up).
    static let keyCapArrowSize: CGFloat = 11
    /// Arc draws the magnifier and the globe in one color (core #AEAEAF / #B3B3B3); our symbols'
    /// stroke widths differ, so the tint is fitted per symbol to match the core pixels.
    static func rowSymbolAlpha(_ name: String) -> Double { name == "magnifyingglass" ? 0.68 : 0.72 }
    /// fitted: row symbols are centered on the icon frame (F0052 magnifier at row + 19, F0048 globe).
    static func rowSymbolOffsetY(_ name: String) -> CGFloat { 0 }
    static let rowSymbolWeight: NSFont.Weight = .medium
    /// Action symbols on their plate (F0063 row 4 ink 15×12). fitted.
    static let plateSymbolSize: CGFloat = 13
    /// fitted: plated symbols sit 2 pt above the plate's center (F0063 row 4 ink 764…776, plate 760…783).
    static let plateSymbolOffsetY: CGFloat = -2
    /// Arrow in the accessory plate: ink 14×12 (F0063 1450…1463 × 616…627).
    static let arrowSymbol = "arrow.right"
    static let arrowSize: CGFloat = 14.5
    /// fitted: ink 1 pt right of and 1 pt above the plate's centered position (F0063 1450…1462, 616…627).
    static let arrowOffset = CGSize(width: 1, height: -1)
    static let arrowWeight: NSFont.Weight = .semibold
    /// Info (i): ink 16×15 (F0063 1449…1464 × 553…567).
    static let infoSymbol = "info.circle"
    static let infoSize: CGFloat = 14
    static let infoWeight: NSFont.Weight = .regular
}

/// Fonts. D3 card (plan §2.1): input 19 Regular (inline 15), rows 15 Medium, selected title 15 Semibold,
/// subtitle 15 Regular, the selected row's hint 13 Semibold. Hint and keycaps fitted (older captures).
enum BarFont {
    @MainActor static func input(_ size: CGFloat) -> NSFont { FontToken(size, .regular).font }
    @MainActor static func row(_ size: CGFloat) -> NSFont { FontToken(size, .medium).font }
    @MainActor static func rowSelected(_ size: CGFloat) -> NSFont { FontToken(size, .semibold).font }
    @MainActor static func rowSubtitle(_ size: CGFloat) -> NSFont { FontToken(size, .regular).font }
    @MainActor static var hintLabel: NSFont { FontToken(CommandCard.hintFontSize, .semibold).font }
    @MainActor static var input: NSFont { input(19) }
    /// The field inside a scope: 18 Regular (fitted on two ink widths: "Search…" 68 px in S2 18/0016,
    /// "bird" 28 px in 0018; 18 Medium gives 70 and 30).
    @MainActor static var inputScoped: NSFont { FontToken(18, .regular).font }
    /// Hint label: 12.75 Medium, fitted on two ink widths ("Search Google" 88 px in F0061, "Search Wikipedia"
    /// 105 px in S2 18/0009); 12.75 Regular was 2 px narrow on the longer one.
    @MainActor static var hint: NSFont { FontToken(12.75, .medium).font }
    @MainActor static var keycap: NSFont { FontToken(13, .semibold).font }
    /// Scope chip text: 13 Medium, white. fitted on S2 18/0016 "Wikipedia": ink 59 px and chip 81 px
    /// (advance 60.8 + 2 × 10); 12.75 Semibold fits the widths too but has 16% more ink than Arc's
    /// (13 Medium: 7%).
    @MainActor static var chip: NSFont { FontToken(13, .medium).font }
}

/// Keycaps: a white 5 % plate with the key label (F0061 "Tab": plate 31×24, radius ≈ 5).
@MainActor
enum Keycap {
    static func width(_ key: String, height: CGFloat) -> CGFloat {
        let w = TextLine(key, font: BarFont.keycap, color: CGColor(gray: 1, alpha: 1)).width
        return max(height, (w + 2 * CommandBarMetrics.keycapPadding).rounded())
    }

    /// Draws one keycap with its top-left at `origin` (flipped context). Returns its width.
    @discardableResult
    static func draw(_ key: String, at origin: CGPoint, height: CGFloat, plate: RGBA, text: RGBA, in ctx: CGContext) -> CGFloat {
        let w = width(key, height: height)
        let rect = CGRect(x: origin.x, y: origin.y, width: w, height: height)
        ctx.setFillColor(plate.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: CommandBarMetrics.keycapRadius, cornerHeight: CommandBarMetrics.keycapRadius, transform: nil))
        ctx.fillPath()
        let line = TextLine(key, font: BarFont.keycap, color: text.cgColor)
        let baseline = origin.y + (height + BarFont.keycap.capHeight) / 2
        line.draw(at: (rect.midX - line.width / 2).rounded(), baseline: baseline.rounded(), in: ctx)
        return w
    }
}

extension NSImage {
    /// Draws the image into a flipped context rect.
    @MainActor func drawFlipped(in rect: CGRect) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
