import AppKit
import OpenCommandBar
import OpenDesign

/// Compares a render with an Arc capture, element by element (method of docs/design.md §7):
/// ink boxes against a fitted background plane give position errors in points; mean
/// colors of fills and of text cores give CIEDE2000. Elements come from the measured
/// metrics and the scene's rows. Favicons are masked. Text that may be personal (titles,
/// subtitles, Space names, the typed URL) is measured but blanked in the images.
@MainActor
enum Compare {
    struct Element {
        enum Kind { case fill(sample: CGRect), ink, points([CGPoint]), pixels([CGPoint]) }
        var name: String
        var region: CGRect
        var kind: Kind
        /// Position only: the core of a 1 px line mixes its neighbors, so its color is measured pixel by pixel elsewhere.
        var positionOnly = false
    }

    struct Result {
        var name: String
        var positionError: Double?
        var deltaE: Double?
        var arcColor: [Double]?
        var oursColor: [Double]?
        var note = ""
    }

    static func run(arcPath: String, oursPath: String, scene: SceneFile, out: String, title: String) throws -> [Result] {
        var arc = try Bitmap(path: arcPath)
        let oursLoaded = try Bitmap(path: oursPath)
        guard arc.width == oursLoaded.width, arc.height == oursLoaded.height else {
            throw CLIError(description: "size mismatch: arc \(arc.width)x\(arc.height), ours \(oursLoaded.width)x\(oursLoaded.height)")
        }
        let scale = Double(arc.width) / scene.size.width
        let spec = BarSpec(scene: scene)
        var oursCopy = oursLoaded
        removeCaret(&arc, region: spec.inputRow, scale: scale)
        removeCaret(&oursCopy, region: spec.inputRow, scale: scale)
        let ours = oursCopy
        let results = spec.elements().map { measure($0, arc: arc, ours: ours, scale: scale) }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let table = markdown(results, title: title)
        try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        writeImages(arc: arc, ours: ours, spec: spec, scale: scale, dir: dir)
        return results
    }

    /// The caret blinks and an offscreen render never draws it: paint Arc's caret pixels
    /// (system blue) with the pixel to their left.
    static func removeCaret(_ b: inout Bitmap, region: CGRect, scale: Double) {
        let r = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        for y in max(0, Int(r.minY))..<min(b.height, Int(r.maxY)) {
            for x in max(1, Int(r.minX))..<min(b.width, Int(r.maxX)) {
                let p = b.pixel(x, y)
                if p[2] > 150, p[2] > p[0] + 90, p[2] > p[1] + 40 {
                    var k = x - 1
                    while k > 0, b.pixel(k, y)[2] > b.pixel(k, y)[0] + 90 { k -= 1 }
                    b.set(x, y, b.pixel(k, y))
                }
            }
        }
    }

    static func measure(_ e: Element, arc: Bitmap, ours: Bitmap, scale: Double) -> Result {
        var r = Result(name: e.name)
        let px = CGRect(x: e.region.minX * scale, y: e.region.minY * scale, width: e.region.width * scale, height: e.region.height * scale).integral
        switch e.kind {
        case .points(let points), .pixels(let points):
            var des: [Double] = []
            var a = [0.0, 0, 0], o = [0.0, 0, 0]
            let single: Bool
            if case .pixels = e.kind { single = true } else { single = false }
            for p in points {
                let s = single ? CGRect(x: floor(p.x * scale), y: floor(p.y * scale), width: 1, height: 1)
                               : CGRect(x: p.x * scale - 1, y: p.y * scale - 1, width: 3, height: 3)
                let ca = arc.mean(s), co = ours.mean(s)
                des.append(ColorMath.deltaE2000(ca, co))
                for i in 0..<3 { a[i] += ca[i] / Double(points.count); o[i] += co[i] / Double(points.count) }
            }
            r.deltaE = des.reduce(0, +) / Double(max(1, des.count))
            r.arcColor = a; r.oursColor = o
            r.note = String(format: "%d points, max ΔE %.2f", des.count, des.max() ?? 0)
        case .fill(let sample):
            let s = CGRect(x: sample.minX * scale, y: sample.minY * scale, width: sample.width * scale, height: sample.height * scale).integral
            let ca = arc.mean(s), co = ours.mean(s)
            r.arcColor = ca; r.oursColor = co
            r.deltaE = ColorMath.deltaE2000(ca, co)
            if let a = arc.inkBox(px, contrastFrom: s), let o = ours.inkBox(px, contrastFrom: s) {
                r.positionError = [abs(a.minX - o.minX), abs(a.minY - o.minY), abs(a.maxX - o.maxX), abs(a.maxY - o.maxY)].max()! / scale
            }
        case .ink:
            let (ba, ca) = arc.ink(px)
            let (bo, co) = ours.ink(px)
            if !e.positionOnly {
                r.arcColor = ca; r.oursColor = co
                if let ca, let co { r.deltaE = ColorMath.deltaE2000(ca, co) }
            }
            if let a = ba, let o = bo {
                r.positionError = [abs(a.minX - o.minX), abs(a.minY - o.minY), abs(a.maxX - o.maxX), abs(a.maxY - o.maxY)].max()! / scale
                r.note = String(format: "Arc %d,%d %d×%d; Open %+d,%+d %d×%d", Int(a.minX), Int(a.minY), Int(a.width), Int(a.height),
                                Int(o.minX - a.minX), Int(o.minY - a.minY), Int(o.width), Int(o.height))
            } else {
                r.note = ba == nil ? "no Arc ink" : "no Open ink"
            }
        }
        return r
    }

    static func markdown(_ results: [Result], title: String) -> String {
        func hex(_ c: [Double]?) -> String {
            guard let c else { return "—" }
            return String(format: "#%02X%02X%02X", Int(c[0].rounded()), Int(c[1].rounded()), Int(c[2].rounded()))
        }
        var s = "### \(title)\n\n| Element | Position error (pt) | ΔE00 | Arc | Open | Note |\n|---|---|---|---|---|---|\n"
        var worstPos = 0.0, worstDE = 0.0, sumPos = 0.0, sumDE = 0.0, nPos = 0, nDE = 0
        for r in results {
            let pos = r.positionError.map { String(format: "%.1f", $0) } ?? "—"
            let de = r.deltaE.map { String(format: "%.2f", $0) } ?? "—"
            if let p = r.positionError { worstPos = max(worstPos, p); sumPos += p; nPos += 1 }
            if let d = r.deltaE { worstDE = max(worstDE, d); sumDE += d; nDE += 1 }
            s += "| \(r.name) | \(pos) | \(de) | \(hex(r.arcColor)) | \(hex(r.oursColor)) | \(r.note) |\n"
        }
        s += String(format: "\nWorst position %.1f pt (mean %.2f), worst ΔE00 %.2f (mean %.2f), %d elements.\n",
                    worstPos, nPos > 0 ? sumPos / Double(nPos) : 0, worstDE, nDE > 0 ? sumDE / Double(nDE) : 0, results.count)
        return s
    }

    /// Side-by-side crop of the panel area: Arc | Open | diff × 4. Masks: favicons and personal text.
    static func writeImages(arc: Bitmap, ours: Bitmap, spec: BarSpec, scale: Double, dir: URL) {
        let crop = spec.panel.insetBy(dx: -60, dy: -40)
        let x0 = max(0, Int(crop.minX * scale)), y0 = max(0, Int(crop.minY * scale))
        let x1 = min(arc.width, Int(crop.maxX * scale)), y1 = min(arc.height, Int(crop.maxY * scale))
        let w = x1 - x0, h = y1 - y0, gap = 4
        let masks = spec.masks().map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        var sheet = Bitmap(width: 3 * w + 2 * gap, height: h, fill: 255)
        for y in 0..<h {
            for x in 0..<w {
                let gx = x0 + x, gy = y0 + y
                let masked = masks.contains { $0.contains(CGPoint(x: Double(gx) + 0.5, y: Double(gy) + 0.5)) }
                let a = arc.pixel(gx, gy), o = ours.pixel(gx, gy)
                sheet.set(x, y, masked ? [128, 128, 128] : a)
                sheet.set(w + gap + x, y, masked ? [128, 128, 128] : o)
                if masked { sheet.set(2 * (w + gap) + x, y, [40, 40, 40]); continue }
                let c = max(abs(a[0] - o[0]), abs(a[1] - o[1]), abs(a[2] - o[2]))
                let v = min(255, c * 4)
                let la = 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2], lo = 0.2126 * o[0] + 0.7152 * o[1] + 0.0722 * o[2]
                sheet.set(2 * (w + gap) + x, y, lo < la ? [255, 255 - v, 255 - v] : [255 - v, 255 - v, 255])
            }
        }
        sheet.write(to: dir.appendingPathComponent("side-by-side.png"))
    }
}

/// Element geometry for one command bar state, from `CommandBarMetrics` and the rows.
@MainActor
struct BarSpec {
    let scene: SceneFile
    let preview: CommandBarPreview
    let panel: CGRect

    init(scene: SceneFile) {
        self.scene = scene
        preview = scene.preview
        panel = CommandBarMetrics.panelFrame(windowSize: scene.size, rows: min(preview.rows.count, CommandBarMetrics.maxVisibleRows))
    }

    var inputRow: CGRect { CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: CommandBarMetrics.inputRowHeight) }
    var visibleRows: Int { min(preview.rows.count, CommandBarMetrics.maxVisibleRows) }

    func rowFrame(_ i: Int) -> CGRect {
        let m = CommandBarMetrics.self
        return CGRect(x: panel.minX + m.rowInsetX, y: panel.minY + m.listTop + CGFloat(i) * m.rowHeight, width: panel.width - 2 * m.rowInsetX, height: m.rowHeight)
    }

    func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    var rowFont: NSFont { Typography.commandBarRow.font }

    func elements() -> [Compare.Element] {
        typealias E = Compare.Element
        let m = CommandBarMetrics.self
        let p = panel
        var e: [E] = []

        // Shadow: background points around the panel at growing distances.
        for (side, pts) in [
            ("left", [6.0, 20, 40, 70].map { CGPoint(x: p.minX - $0, y: p.midY) }),
            ("right", [6.0, 20, 40, 70].map { CGPoint(x: p.maxX + $0, y: p.midY) }),
            ("top", [4.0, 15, 30].map { CGPoint(x: p.midX + 150, y: p.minY - $0) }),
            ("bottom", [8.0, 30, 60, 100].map { CGPoint(x: p.midX + 150, y: p.maxY + $0) }),
        ] { e.append(E(name: "shadow \(side)", region: .zero, kind: .points(pts))) }

        // Panel edges: the outer line's position (a tight region, so the shadow ramp stays out),
        // then the outer and inner line colors pixel by pixel.
        e.append(E(name: "panel edge top (position)", region: CGRect(x: p.midX + 100, y: p.minY - 2, width: 100, height: 5), kind: .ink, positionOnly: true))
        e.append(E(name: "panel edge bottom (position)", region: CGRect(x: p.midX + 100, y: p.maxY - 3, width: 100, height: 5), kind: .ink, positionOnly: true))
        e.append(E(name: "panel edge left (position)", region: CGRect(x: p.minX - 2, y: p.minY + 30, width: 5, height: 20), kind: .ink, positionOnly: true))
        e.append(E(name: "panel edge right (position)", region: CGRect(x: p.maxX - 3, y: p.minY + 30, width: 5, height: 20), kind: .ink, positionOnly: true))
        let edgeXs = Array(stride(from: p.minX + 60, to: p.maxX - 60, by: 80))
        e.append(E(name: "panel outer line color", region: .zero,
                   kind: .pixels(edgeXs.map { CGPoint(x: $0, y: p.minY) } + edgeXs.map { CGPoint(x: $0, y: p.maxY - 1) })))
        e.append(E(name: "panel inner line color", region: .zero,
                   kind: .pixels(edgeXs.map { CGPoint(x: $0, y: p.minY + 1) } + edgeXs.map { CGPoint(x: $0, y: p.maxY - 2) })))

        // Fill: empty spots of the input row and the bottom padding.
        var fill = [CGPoint(x: p.minX + 420, y: p.minY + 8), CGPoint(x: p.minX + 600, y: p.minY + 56), CGPoint(x: p.minX + 300, y: p.minY + 58)]
        if visibleRows > 0 { fill += [CGPoint(x: p.minX + 200, y: p.maxY - 5), CGPoint(x: p.minX + 560, y: p.maxY - 5)] }
        e.append(E(name: "panel fill", region: .zero, kind: .points(fill)))

        if visibleRows > 0 {
            e.append(E(name: "separator", region: CGRect(x: p.minX + 300, y: p.minY + m.inputRowHeight - 3, width: 200, height: 7), kind: .ink))
        }

        // Input row.
        let icon = m.leadingIconFrame.offsetBy(dx: p.minX, dy: p.minY)
        if case .symbol = preview.input.leadingIcon {
            e.append(E(name: "input leading icon", region: icon.insetBy(dx: -2, dy: -2), kind: .ink))
        }
        let inputFont = Typography.commandBarInput.font
        let shown = preview.text.isEmpty ? preview.input.placeholder : preview.text
        let tw = textWidth(shown, font: inputFont)
        let textName = preview.text.isEmpty ? "input placeholder" : (preview.selectAllText ? "input text (selected)" : "input text")
        e.append(E(name: textName, region: CGRect(x: p.minX + m.textFieldX + 1, y: p.minY + 15, width: tw + 3, height: 32), kind: .ink))
        if preview.selectAllText {
            e.append(E(name: "input selection", region: CGRect(x: p.minX + m.textFieldX - 3, y: p.minY + 17, width: tw + 8, height: 28),
                       kind: .fill(sample: CGRect(x: p.minX + m.textFieldX + 2, y: p.minY + m.textFieldY + 1, width: tw - 6, height: 2))))
        }
        switch preview.input.trailing {
        case .info:
            let b = CGRect(x: p.maxX - m.infoButtonTrailing - m.infoButtonSize, y: p.minY + m.infoButtonY, width: m.infoButtonSize, height: m.infoButtonSize)
            let c = CGPoint(x: b.midX, y: b.midY)
            e.append(E(name: "info circle", region: b.insetBy(dx: -3, dy: -3), kind: .fill(sample: CGRect(x: c.x - 3, y: b.minY + 2, width: 6, height: 2))))
            e.append(E(name: "info glyph", region: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18), kind: .ink))
        case .siteSearchHint(let name, let space):
            let right = p.maxX - m.hintTrailing
            let hintFont = FontToken(12.75, .regular).font
            let label = CommandBarText.searchSite(name)
            let total = hintTotalWidth(name: name, space: space)
            let x0 = right - total
            e.append(E(name: "hint label", region: CGRect(x: x0 - 3, y: p.minY + m.hintY, width: textWidth(label, font: hintFont) + 3, height: 24), kind: .ink))
            let tabW = keyWidth(CommandBarText.tabKey)
            let tabX = x0 + textWidth(label, font: hintFont) + m.hintLabelGap
            let tab = CGRect(x: tabX, y: p.minY + m.hintY, width: tabW, height: m.keycapHeight)
            e.append(E(name: "hint keycap Tab", region: tab.insetBy(dx: -3, dy: -3), kind: .fill(sample: CGRect(x: tab.minX + 3, y: tab.minY + 2, width: tab.width - 6, height: 2))))
            e.append(E(name: "hint keycap Tab label", region: tab.insetBy(dx: 2, dy: 2), kind: .ink))
        case .none:
            break
        }

        // Rows.
        for i in 0..<visibleRows {
            let row = preview.rows[i], f = rowFrame(i)
            let selected = i == preview.selectedIndex
            let tag = "row \(i + 1)"
            if selected {
                e.append(E(name: "\(tag) selection", region: f.insetBy(dx: -3, dy: -3),
                           kind: .fill(sample: CGRect(x: f.minX + 100, y: f.minY + 4, width: 300, height: 3))))
            }
            let iconFrame = m.iconFrame.offsetBy(dx: f.minX, dy: f.minY)
            let plate = m.iconPlateFrame.offsetBy(dx: f.minX, dy: f.minY)
            switch row.icon {
            case .symbol(_, let hasPlate):
                if hasPlate {
                    e.append(E(name: "\(tag) icon plate", region: plate.insetBy(dx: -3, dy: -3), kind: .fill(sample: CGRect(x: plate.minX + 4, y: plate.minY + 1, width: 16, height: 2))))
                }
                e.append(E(name: "\(tag) icon", region: hasPlate ? iconFrame.insetBy(dx: -1, dy: -1) : iconFrame.insetBy(dx: -3, dy: -3), kind: .ink))
            case .favicon:
                if selected {
                    e.append(E(name: "\(tag) favicon plate", region: plate.insetBy(dx: -3, dy: -3), kind: .fill(sample: CGRect(x: plate.minX + 4, y: plate.minY + 1, width: 16, height: 2))))
                }
            case .emoji:
                break
            }
            let titleW = textWidth(row.title, font: rowFont)
            e.append(E(name: "\(tag) title", region: CGRect(x: f.minX + m.titleX - 2, y: f.minY + 12, width: titleW + 3, height: 26), kind: .ink))
            if !row.subtitle.isEmpty {
                let subW = min(textWidth(m.subtitlePrefix + row.subtitle, font: rowFont), m.subtitleMaxWidth) + 3
                e.append(E(name: "\(tag) subtitle", region: CGRect(x: f.minX + m.titleX + titleW + m.subtitleGap - 2, y: f.minY + 12, width: subW, height: 26), kind: .ink))
            }
            if case .switchTo(let label) = row.accessory {
                let plateRect = CGRect(x: f.maxX - m.accessoryPlateTrailing - m.accessoryPlateSize, y: f.minY + m.accessoryPlateY, width: m.accessoryPlateSize, height: m.accessoryPlateSize)
                e.append(E(name: "\(tag) arrow plate", region: plateRect.insetBy(dx: -3, dy: -3), kind: .fill(sample: CGRect(x: plateRect.minX + 4, y: plateRect.minY + 1, width: 16, height: 2))))
                e.append(E(name: "\(tag) arrow", region: plateRect.insetBy(dx: 3, dy: 3), kind: .ink))
                let lw = textWidth(label, font: rowFont)
                e.append(E(name: "\(tag) accessory label", region: CGRect(x: plateRect.minX - m.accessoryLabelGap - lw - 2, y: f.minY + 12, width: lw + 3, height: 26), kind: .ink))
            }
        }
        return e
    }

    func keyWidth(_ key: String) -> CGFloat {
        let w = (key as NSString).size(withAttributes: [.font: FontToken(13, .semibold).font]).width
        return max(CommandBarMetrics.keycapHeight, (w + 2 * CommandBarMetrics.keycapPadding).rounded())
    }

    func hintTotalWidth(name: String, space: Bool) -> CGFloat {
        let m = CommandBarMetrics.self
        let hintFont = FontToken(12.75, .regular).font
        var w = textWidth(CommandBarText.searchSite(name), font: hintFont) + m.hintLabelGap + keyWidth(CommandBarText.tabKey)
        if space { w += 2 * m.hintKeyGap + textWidth(CommandBarText.or, font: hintFont) + keyWidth(CommandBarText.spaceKey) }
        return w
    }

    /// Favicons and text that may be personal.
    func masks() -> [CGRect] {
        let m = CommandBarMetrics.self
        var r: [CGRect] = []
        if case .favicon = preview.input.leadingIcon { r.append(m.leadingIconFrame.offsetBy(dx: panel.minX, dy: panel.minY).insetBy(dx: -3, dy: -3)) }
        if !preview.text.isEmpty {
            r.append(CGRect(x: panel.minX + m.textFieldX - 4, y: panel.minY + 14, width: panel.width - 300, height: 36))
        }
        for i in 0..<visibleRows {
            let f = rowFrame(i), row = preview.rows[i]
            if case .favicon = row.icon { r.append(m.iconPlateFrame.offsetBy(dx: f.minX, dy: f.minY).insetBy(dx: -2, dy: -2)) }
            r.append(CGRect(x: f.minX + m.titleX - 3, y: f.minY + 8, width: 560, height: 34))
        }
        return r
    }
}
