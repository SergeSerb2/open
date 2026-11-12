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
    var extensionIcon: (@MainActor (String) -> NSImage?)?
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

    /// New Tab card or inline editor geometry.
    var layoutSpec = CommandCardLayout.newTab { didSet { if layoutSpec != oldValue { needsDisplay = true; updateSplitPlate() } } }

    /// Row content: the top `rowHeight` points of the 50 pt pitch (the 4 pt gap stays clear).
    private var contentHeight: CGFloat { layoutSpec.rowHeight }
    private var iconFrame: CGRect {
        let l = layoutSpec
        return CGRect(x: l.rowPaddingLeft, y: ((l.rowHeight - l.iconSize) / 2).rounded(), width: l.iconSize, height: l.iconSize)
    }
    private var tileFrame: CGRect {
        let l = layoutSpec, t = CommandCard.tileSize
        return CGRect(x: l.rowPaddingLeft - l.tileOffset, y: ((l.rowHeight - t) / 2).rounded(), width: t, height: t)
    }
    private func baseline(_ font: NSFont) -> CGFloat { ((contentHeight + font.capHeight) / 2).rounded() }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCount += 1
        let l = layoutSpec
        let w = bounds.width
        drawIcon(row.icon, in: ctx)

        // Accessory first: the text stops before it.
        var textMaxX = w - l.rowPaddingRight
        switch row.accessory {
        case .none:
            break
        case .switchTo(let label):
            // The named action shows on the selected row only: label + key cap (plan D3 §2.1).
            guard isSelected else { break }
            let k = CommandCard.keyCapSize
            let cap = CGRect(x: w - l.rowPaddingRight - k, y: ((contentHeight - k) / 2).rounded(), width: k, height: k)
            fillRounded(cap, radius: CommandCard.keyCapRadius, color: .white(1), in: ctx)
            if let arrow = SymbolCache.image(BarGlyph.arrowSymbol, size: BarGlyph.keyCapArrowSize, weight: .semibold, color: theme.keyCapGlyph) {
                let s = arrow.size
                arrow.drawFlipped(in: CGRect(x: (cap.midX - s.width / 2).rounded(), y: (cap.midY - s.height / 2).rounded(), width: s.width, height: s.height))
            }
            let font = BarFont.hintLabel
            let line = TextLine(label, font: font, color: CommandCard.selectedText.cgColor)
            let right = cap.minX - CommandCard.hintGap
            line.draw(at: right - line.width, baseline: baseline(font), in: ctx)
            textMaxX = right - line.width - l.rowGap
        case .keys(let keys):
            let h = CommandCard.keyCapSize
            var x = w - l.rowPaddingRight
            let y = ((contentHeight - h) / 2).rounded()
            let plate = isSelected ? RGBA.white(0.2) : theme.plate
            let text = isSelected ? RGBA.white(1) : theme.secondaryText
            for key in keys.reversed() {
                let kw = Keycap.width(key, height: h)
                x -= kw
                Keycap.draw(key, at: CGPoint(x: x, y: y), height: h, plate: plate, text: text, in: ctx)
                x -= CommandBarMetrics.rowKeycapGap
            }
            textMaxX = x - l.rowGap
        }

        if !row.titleParts.isEmpty, case .split(let panes, _) = row.icon {
            drawSplitTitle(row.titleParts, x: splitPlateRect(panes: panes.count, row.icon).maxX + CommandBarMetrics.splitTitleGap, maxX: textMaxX, in: ctx)
            return
        }

        // Title (medium; semibold when selected), then "— subtitle" in the secondary color, cut at the tail.
        let titleColor = isSelected ? CommandCard.selectedText : theme.text
        let subColor = isSelected ? CommandCard.selectedSubtitle : theme.secondaryText
        let font = isSelected ? BarFont.rowSelected(l.rowFontSize) : BarFont.row(l.rowFontSize)
        let subFont = BarFont.rowSubtitle(l.rowFontSize)
        let y = baseline(font)
        var title = TextLine(row.title, font: font, color: titleColor.cgColor, boldRanges: row.boldRanges)
        let available = textMaxX - l.titleX
        title = title.truncated(to: min(available, CommandBarMetrics.titleMaxWidth), font: font, color: titleColor.cgColor)
        title.draw(at: l.titleX, baseline: y, in: ctx)
        if !row.subtitle.isEmpty {
            let room = available - ceil(title.width) - l.rowGap
            if room >= 40 {
                let sub = TextLine(CommandBarMetrics.subtitlePrefix + row.subtitle, font: subFont, color: subColor.cgColor)
                    .truncated(to: room, font: subFont, color: subColor.cgColor)
                sub.draw(at: l.titleX + ceil(title.width) + l.rowGap, baseline: y, in: ctx)
            }
        }
    }

    private func drawIcon(_ icon: CommandBarIcon, in ctx: CGContext) {
        let frame = iconFrame
        let tile = tileFrame
        let inner = CGRect(x: tile.midX - CommandCard.tileFavicon / 2, y: tile.midY - CommandCard.tileFavicon / 2,
                           width: CommandCard.tileFavicon, height: CommandCard.tileFavicon)
        // The selected row's icon sits in a white 24 pt tile, radius 6 (plan D3 §2.1).
        if isSelected, !isSplit(icon) { fillRounded(tile, radius: CommandCard.tileRadius, color: .white(1), in: ctx) }
        switch icon {
        case .extension(let id):
            if let image = extensionIcon?(id) { image.drawFlipped(in: isSelected ? inner : frame) }
            else { drawSymbol("puzzlepiece.extension", plate: false, in: ctx) }
        case .favicon(let url, let fallback):
            if let image = favicons?.favicon(for: url, loaded: { [weak self] u in
                if case .favicon(let current, _)? = self?.row?.icon, current == u { self?.needsDisplay = true }
            }) {
                drawRounded(image, in: isSelected ? inner : frame, radius: isSelected ? CommandCard.faviconRadius * inner.width / frame.width : CommandCard.faviconRadius, ctx: ctx)
            } else {
                drawSymbol(fallback, plate: false, in: ctx)
            }
        case .symbol(let name, let plate):
            drawSymbol(name, plate: plate, in: ctx)
        case .split:
            break // sublayers (updateSplitPlate)
        case .emoji(let e):
            let font = NSFont.systemFont(ofSize: isSelected ? 13 : 15)
            let s = NSAttributedString(string: e, attributes: [.font: font])
            let b = s.size()
            let f = isSelected ? inner : frame
            NSGraphicsContext.saveGraphicsState()
            s.draw(at: NSPoint(x: f.midX - b.width / 2, y: f.midY - b.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func isSplit(_ icon: CommandBarIcon) -> Bool { if case .split = icon { true } else { false } }

    /// The favicon clipped to a continuous rounded square.
    private func drawRounded(_ image: NSImage, in rect: CGRect, radius: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        image.drawFlipped(in: rect)
        ctx.restoreGState()
    }

    // MARK: Split View row (CC-13, CC-14)

    /// The plate: 30×30 for two side-by-side panes or any stacked split, 15 pt per pane for 3–4 side by side.
    /// Vertically centred in the 46 pt row; it starts 1 pt before the icon column.
    func splitPlateRect(panes: Int, _ icon: CommandBarIcon) -> CGRect {
        let m = CommandBarMetrics.self
        var vertical = false
        if case .split(_, let v) = icon { vertical = v }
        let width = vertical ? m.splitPlateHeight : max(m.splitPlateHeight, m.splitCellWidth * CGFloat(max(2, panes)))
        return CGRect(x: layoutSpec.rowPaddingLeft - 1, y: ((layoutSpec.rowHeight - m.splitPlateHeight) / 2).rounded(), width: width, height: m.splitPlateHeight)
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
        let plate = splitPlateRect(panes: panes.count, .split(panes, vertical: vertical))
        let cells = Self.splitCells(plate, panes: panes.count, vertical: vertical)
        let scale = window?.backingScaleFactor ?? host.contentsScale
        let fill = (isSelected ? RGBA.white(1) : theme.plate).cgColor
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
        case .extension(let id): return extensionIcon?(id)
        case .favicon(let url, let fallback):
            if let image = favicons?.favicon(for: url, loaded: { [weak self] u in
                // Refresh only if this row still shows that pane (the view may hold another row by now).
                if case .split(let current, _)? = self?.row?.icon, current.contains(.favicon(u, fallback: fallback)) { self?.updateSplitPlate() }
            }) {
                return image
            }
            return SymbolCache.image(fallback, size: size, weight: BarGlyph.rowSymbolWeight, color: isSelected ? theme.focus : theme.secondaryText)
        case .symbol(let name, _):
            return SymbolCache.image(name, size: size, weight: BarGlyph.rowSymbolWeight, color: isSelected ? theme.focus : theme.secondaryText)
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
        let color = (isSelected ? CommandCard.selectedText : theme.text).cgColor
        let font = isSelected ? BarFont.rowSelected(layoutSpec.rowFontSize) : BarFont.row(layoutSpec.rowFontSize)
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
        let rule = (isSelected ? RGBA.white(0.5) : theme.text.withAlpha(0.17)).cgColor // guess on the selected row
        for (i, line) in lines.enumerated() {
            if i > 0 {
                ctx.setFillColor(rule)
                ctx.fill(CGRect(x: cursor + m.splitRuleGapBefore, y: ((contentHeight - m.splitRuleHeight) / 2).rounded(), width: m.splitRuleWidth, height: m.splitRuleHeight))
                cursor += separator
            }
            line.draw(at: cursor, baseline: baseline(font), in: ctx)
            cursor += line.width
        }
    }

    /// Glyph rows (search, globe) and action rows. Unselected: the secondary color; action glyphs on a plate.
    /// Selected: the glyph in the selection color on the white tile.
    private func drawSymbol(_ name: String, plate: Bool, in ctx: CGContext) {
        let f = iconFrame
        if plate, !isSelected { fillRounded(tileFrame, radius: CommandCard.tileRadius, color: theme.plate, in: ctx) }
        let color = isSelected ? theme.focus : theme.secondaryText
        let size = plate ? BarGlyph.plateSymbolSize : BarGlyph.rowSymbolSize(name)
        guard let image = SymbolCache.image(name, size: size, weight: BarGlyph.rowSymbolWeight, color: color) else { return }
        let s = image.size
        image.drawFlipped(in: CGRect(x: (f.midX - s.width / 2).rounded(), y: (f.midY - s.height / 2).rounded(), width: s.width, height: s.height))
    }

    private func fillRounded(_ rect: CGRect, radius: CGFloat, color: RGBA, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
}
