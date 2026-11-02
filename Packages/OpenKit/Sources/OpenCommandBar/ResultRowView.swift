import AppKit
import OpenDesign
import OpenSuggest

/// One result row: icon (and its plate), title, subtitle, and the accessory. The
/// selected fill is not drawn here: `ResultsView` moves one shared layer under the
/// rows, so a selection change redraws only the two rows whose text color changes.
@MainActor
final class ResultRowView: NSView {
    var row: CommandBarRow? { didSet { if row != oldValue { needsDisplay = true } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var theme = CommandBarTheme.default { didSet { if theme != oldValue { needsDisplay = true } } }
    weak var favicons: CommandBarFaviconSource?
    /// Diagnostics: draw passes since creation.
    private(set) var drawCount = 0
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { row != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { row?.title }
    override func accessibilityValue() -> Any? {
        guard let row else { return nil }
        let accessory: String
        switch row.accessory {
        case .none: accessory = ""
        case .switchTo(let label): accessory = label
        case .keys(let keys): accessory = keys.joined(separator: " ")
        }
        return [row.subtitle, accessory].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    override func isAccessibilitySelected() -> Bool { isSelected }
    override func accessibilityPerformPress() -> Bool {
        guard row != nil, let onPress else { return false }
        onPress()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCount += 1
        let m = CommandBarMetrics.self
        let w = bounds.width
        drawIcon(row.icon, in: ctx)

        // Accessory first: the text stops before it.
        var textMaxX = w - m.accessoryTextGap
        switch row.accessory {
        case .none:
            textMaxX = w - 16
        case .switchTo(let label):
            let plateRect = CGRect(x: w - m.accessoryPlateTrailing - m.accessoryPlateSize, y: m.accessoryPlateY,
                                   width: m.accessoryPlateSize, height: m.accessoryPlateSize)
            fillRounded(plateRect, radius: m.accessoryPlateRadius, color: isSelected ? CommandBarRole.plateSelected : CommandBarRole.plate, in: ctx)
            let arrowColor = isSelected ? theme.focus : CommandBarRole.plateGlyph
            if let arrow = SymbolCache.image(BarGlyph.arrowSymbol, size: BarGlyph.arrowSize, weight: BarGlyph.arrowWeight, color: arrowColor) {
                let s = arrow.size
                arrow.drawFlipped(in: CGRect(x: (plateRect.midX - s.width / 2).rounded() + BarGlyph.arrowOffset.width,
                                             y: (plateRect.midY - s.height / 2).rounded() + BarGlyph.arrowOffset.height, width: s.width, height: s.height))
            }
            let color = isSelected ? CommandBarRole.secondaryTextSelected : CommandBarRole.secondaryText
            let line = TextLine(label, font: BarFont.row, color: color.cgColor)
            let right = plateRect.minX - m.accessoryLabelGap
            line.draw(at: right - line.width, baseline: m.textBaseline, in: ctx)
            textMaxX = right - line.width - m.accessoryTextGap
        case .keys(let keys):
            let h = m.rowKeycapHeight
            var x = w - m.accessoryPlateTrailing
            let y = ((bounds.height - h) / 2).rounded()
            let plate = isSelected ? RGBA.white(0.18) : CommandBarRole.plate
            let text = isSelected ? RGBA.white(1) : CommandBarRole.keycapText
            for key in keys.reversed() {
                let kw = Keycap.width(key, height: h)
                x -= kw
                Keycap.draw(key, at: CGPoint(x: x, y: y), height: h, plate: plate, text: text, in: ctx)
                x -= m.rowKeycapGap
            }
            textMaxX = x - m.accessoryTextGap
        }

        // Title, then " — subtitle".
        let titleColor = isSelected ? CommandBarRole.rowTitleSelected : CommandBarRole.rowTitle
        let subColor = isSelected ? CommandBarRole.subtitleSelected : CommandBarRole.secondaryText
        let font = BarFont.row
        var title = TextLine(row.title, font: font, color: titleColor.cgColor)
        let available = textMaxX - m.titleX
        var subtitle: TextLine?
        if !row.subtitle.isEmpty {
            let full = TextLine(m.subtitlePrefix + row.subtitle, font: font, color: subColor.cgColor)
            let room = available - ceil(title.width) - m.subtitleGap
            let maxSub = max(0, min(room, m.subtitleMaxWidth))
            if maxSub >= 60 {
                subtitle = full.truncated(to: maxSub, mode: .middle, font: font, color: subColor.cgColor)
            }
        }
        let subtitleSpace = subtitle.map { $0.width + m.subtitleGap } ?? 0
        title = title.truncated(to: available - subtitleSpace, font: font, color: titleColor.cgColor)
        title.draw(at: m.titleX, baseline: m.textBaseline, in: ctx)
        subtitle?.draw(at: m.titleX + ceil(title.width) + m.subtitleGap, baseline: m.textBaseline, in: ctx)
    }

    private func drawIcon(_ icon: CommandBarIcon, in ctx: CGContext) {
        let m = CommandBarMetrics.self
        let frame = m.iconFrame
        switch icon {
        case .favicon(let url, let fallback):
            if let image = favicons?.favicon(for: url, loaded: { [weak self] u in
                if case .favicon(let current, _)? = self?.row?.icon, current == u { self?.needsDisplay = true }
            }) {
                if isSelected { fillRounded(m.iconPlateFrame, radius: m.iconPlateRadius, color: .white(1), in: ctx) }
                image.drawFlipped(in: frame)
            } else {
                drawSymbol(fallback, plate: false, in: ctx)
            }
        case .symbol(let name, let plate):
            drawSymbol(name, plate: plate, in: ctx)
        case .emoji(let e):
            let font = NSFont.systemFont(ofSize: 14)
            let s = NSAttributedString(string: e, attributes: [.font: font])
            let b = s.size()
            NSGraphicsContext.saveGraphicsState()
            s.draw(at: NSPoint(x: frame.midX - b.width / 2, y: frame.midY - b.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawSymbol(_ name: String, plate: Bool, in ctx: CGContext) {
        let m = CommandBarMetrics.self
        var color = isSelected ? CommandBarRole.rowGlyphSelected : CommandBarRole.rowGlyph.withAlpha(BarGlyph.rowSymbolAlpha(name))
        var size = BarGlyph.rowSymbolSize(name)
        var c = CGPoint(x: m.iconFrame.midX, y: m.iconFrame.midY + BarGlyph.rowSymbolOffsetY(name))
        if plate {
            fillRounded(m.iconPlateFrame, radius: m.iconPlateRadius, color: isSelected ? .white(1) : CommandBarRole.plate, in: ctx)
            color = isSelected ? theme.focus : CommandBarRole.plateGlyph
            size = BarGlyph.plateSymbolSize
            c.y = m.iconFrame.midY + BarGlyph.plateSymbolOffsetY
        }
        guard let image = SymbolCache.image(name, size: size, weight: BarGlyph.rowSymbolWeight, color: color) else { return }
        let s = image.size
        image.drawFlipped(in: CGRect(x: (c.x - s.width / 2).rounded(), y: (c.y - s.height / 2).rounded(), width: s.width, height: s.height))
    }

    private func fillRounded(_ rect: CGRect, radius: CGFloat, color: RGBA, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
}
