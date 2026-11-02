import AppKit
import OpenDesign
import OpenSuggest

/// One result row: icon (and its plate), title, subtitle, and the accessory. The
/// selected fill is not drawn here: `ResultsView` moves one shared layer under the
/// rows, so a selection change redraws only the two rows whose text color changes.
@MainActor
final class ResultRowView: NSView {
    var row: CommandBarRow? { didSet { if row != oldValue { needsDisplay = true; updateSplitPlate() } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; updateSplitPlate() } } }
    var theme = CommandBarTheme.default { didSet { if theme != oldValue { needsDisplay = true; updateSplitPlate() } } }
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
    /// A Split View row reads its pane titles, comma-separated (plan §4.2.2).
    override func accessibilityLabel() -> String? { row.map { $0.titleParts.isEmpty ? $0.title : $0.titleParts.joined(separator: ", ") } }
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

        if !row.titleParts.isEmpty, case .split(let panes, _) = row.icon {
            drawSplitTitle(row.titleParts, x: Self.splitPlateRect(panes: panes.count, row.icon).maxX + m.splitTitleGap, maxX: textMaxX, in: ctx)
            return
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
        title = title.truncated(to: min(available - subtitleSpace, m.titleMaxWidth), font: font, color: titleColor.cgColor)
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
        case .split:
            break // sublayers (updateSplitPlate)
        case .emoji(let e):
            let font = NSFont.systemFont(ofSize: 14)
            let s = NSAttributedString(string: e, attributes: [.font: font])
            let b = s.size()
            NSGraphicsContext.saveGraphicsState()
            s.draw(at: NSPoint(x: frame.midX - b.width / 2, y: frame.midY - b.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Split View row (CC-13, CC-14)

    /// The plate: 30×30 for two side-by-side panes or any stacked split, 15 pt per pane for 3–4 side by side.
    static func splitPlateRect(panes: Int, _ icon: CommandBarIcon) -> CGRect {
        let m = CommandBarMetrics.self
        var vertical = false
        if case .split(_, let v) = icon { vertical = v }
        let width = vertical ? m.splitPlateHeight : max(m.splitPlateHeight, m.splitCellWidth * CGFloat(max(2, panes)))
        return CGRect(x: m.splitPlateOrigin.x, y: m.splitPlateOrigin.y, width: width, height: m.splitPlateHeight)
    }

    /// Cells of the plate in pane order, with the 1 pt gaps between them left out.
    static func splitCells(_ plate: CGRect, panes: Int, vertical: Bool) -> [CGRect] {
        let n = max(1, panes), gap = CommandBarMetrics.splitCellGap
        let length = ((vertical ? plate.height : plate.width) - gap * CGFloat(n - 1)) / CGFloat(n)
        return (0..<n).map { i in
            let start = CGFloat(i) * (length + gap)
            return vertical ? CGRect(x: plate.minX, y: plate.minY + start, width: plate.width, height: length)
                            : CGRect(x: plate.minX + start, y: plate.minY, width: length, height: plate.height)
        }
    }

    /// The Split View plate as Core Animation layers: one rounded cell per pane with a 1 pt gap
    /// between cells (the row background shows through, A0120), and one icon layer per cell. Layers
    /// rather than drawing: the cells need no clear-blend punch-out, and pane icons update alone.
    private var splitLayers: [CALayer] = []

    private func updateSplitPlate() {
        guard case .split(let panes, let vertical)? = row?.icon, let host = layer else {
            if !splitLayers.isEmpty { splitLayers.forEach { $0.removeFromSuperlayer() }; splitLayers = [] }
            return
        }
        let m = CommandBarMetrics.self
        let plate = Self.splitPlateRect(panes: panes.count, .split(panes, vertical: vertical))
        let cells = Self.splitCells(plate, panes: panes.count, vertical: vertical)
        let scale = window?.backingScaleFactor ?? host.contentsScale
        let fill = (isSelected ? RGBA.white(1) : CommandBarRole.plate).cgColor
        let size = vertical ? min(m.splitPaneIconSize, (cells.first?.height ?? 30) - 4) : m.splitPaneIconSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        splitLayers.forEach { $0.removeFromSuperlayer() }
        splitLayers = []
        for (i, (icon, cell)) in zip(panes, cells).enumerated() {
            let c = CALayer()
            // Flipped view: layer y grows down like the view's.
            c.frame = cell
            c.backgroundColor = fill
            c.cornerRadius = m.splitPlateRadius
            c.cornerCurve = .continuous
            // Only the plate's outer corners are round.
            let first = i == 0, last = i == cells.count - 1
            var corners: CACornerMask = []
            if vertical {
                if first { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
                if last { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            } else {
                if first { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
                if last { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
            }
            c.maskedCorners = corners
            let image = paneImage(icon, size: size)
            if let image {
                let iconLayer = CALayer()
                iconLayer.frame = CGRect(x: (cell.width - size) / 2, y: (cell.height - size) / 2, width: size, height: size)
                iconLayer.contents = image.layerContents(forContentsScale: scale)
                iconLayer.contentsScale = scale
                iconLayer.contentsGravity = .resizeAspect
                c.addSublayer(iconLayer)
            }
            host.addSublayer(c)
            splitLayers.append(c)
        }
        CATransaction.commit()
    }

    private func paneImage(_ icon: CommandBarIcon, size: CGFloat) -> NSImage? {
        switch icon {
        case .favicon(let url, let fallback):
            if let image = favicons?.favicon(for: url, loaded: { [weak self] u in
                // Refresh only if this row still shows that pane (the view may hold another row by now).
                if case .split(let current, _)? = self?.row?.icon, current.contains(.favicon(u, fallback: fallback)) { self?.updateSplitPlate() }
            }) {
                return image
            }
            return SymbolCache.image(fallback, size: size, weight: BarGlyph.rowSymbolWeight, color: isSelected ? theme.focus : CommandBarRole.plateGlyph)
        case .symbol(let name, _):
            return SymbolCache.image(name, size: size, weight: BarGlyph.rowSymbolWeight, color: isSelected ? theme.focus : CommandBarRole.plateGlyph)
        case .emoji(let e):
            let font = NSFont.systemFont(ofSize: size)
            let text = NSAttributedString(string: e, attributes: [.font: font])
            let b = text.size()
            return NSImage(size: NSSize(width: max(size, b.width), height: max(size, b.height)), flipped: false) { r in
                text.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2)); return true
            }
        case .split:
            return nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSplitPlate()
    }

    /// Pane titles with a 1 pt rule between them. Too long: the last part truncates first, then earlier ones. guess.
    private func drawSplitTitle(_ parts: [String], x: CGFloat, maxX: CGFloat, in ctx: CGContext) {
        let m = CommandBarMetrics.self
        let color = (isSelected ? CommandBarRole.rowTitleSelected : CommandBarRole.rowTitle).cgColor
        let font = BarFont.row
        var lines = parts.map { TextLine($0, font: font, color: color) }
        let separator = m.splitRuleGapBefore + m.splitRuleWidth + m.splitRuleGapAfter
        var excess = lines.reduce(0) { $0 + $1.width } + separator * CGFloat(max(0, lines.count - 1)) - (maxX - x)
        var k = lines.count - 1
        while excess > 0, k >= 0 {
            let w = lines[k].width
            let target = max(min(w, 24), w - excess)
            lines[k] = TextLine(parts[k], font: font, color: color).truncated(to: target, font: font, color: color)
            excess -= w - lines[k].width
            k -= 1
        }
        var cursor = x
        let rule = (isSelected ? RGBA.white(0.5) : CommandBarRole.splitTitleRule).cgColor // guess on the selected row
        for (i, line) in lines.enumerated() {
            if i > 0 {
                ctx.setFillColor(rule)
                ctx.fill(CGRect(x: cursor + m.splitRuleGapBefore, y: m.splitRuleTop, width: m.splitRuleWidth, height: m.splitRuleHeight))
                cursor += separator
            }
            line.draw(at: cursor, baseline: m.textBaseline, in: ctx)
            cursor += line.width
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
