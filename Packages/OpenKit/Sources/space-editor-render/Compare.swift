import AppKit
import ImageIO
import OpenDesign

/// Compares a render with an Arc capture, element by element.
///
/// Method (docs/design.md, "Comparison method"):
/// 1. Both PNGs are drawn into an sRGB bitmap. Core Graphics converts the
///    capture from its embedded display profile, as runtime-observations §0 asks.
/// 2. For each element, a background plane (a + b·x + c·y per channel) is fitted
///    to a 1 px ring around the element's region. "Ink" is every pixel whose
///    luminance differs from the plane by at least half of the element's peak
///    contrast. Position error = the largest edge difference of the two ink
///    boxes, in points.
/// 3. Color: fills compare the mean of a sample rectangle; text and glyphs
///    compare the mean of their core pixels (≥ 85 % of peak contrast). ΔE is
///    CIEDE2000 on sRGB → Lab (D65).
/// 4. Favicons, tile icons, and the web content panel are masked in the
///    side-by-side and diff images; no element covers them.
@MainActor
enum Compare {
    struct Element {
        enum Kind { case fill(sample: CGRect), ink, emoji, background([CGPoint]) }
        var name: String
        var region: CGRect
        var kind: Kind
    }

    struct Result {
        var name: String
        var arcBox: CGRect?
        var oursBox: CGRect?
        var positionError: Double?
        var arcColor: [Double]?
        var oursColor: [Double]?
        var deltaE: Double?
        var note = ""
    }

    static func run(_ args: [String]) throws {
        guard let arcPath = RenderCLI.value(args, "--arc"), let oursPath = RenderCLI.value(args, "--ours"),
              let out = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let scale = Double(RenderCLI.value(args, "--scale") ?? "1") ?? 1
        let arc = try Bitmap(path: arcPath), ours = try Bitmap(path: oursPath)
        guard arc.width == ours.width, arc.height == ours.height else {
            throw CLIError(description: "size mismatch: arc \(arc.width)x\(arc.height), ours \(ours.width)x\(ours.height)")
        }
        if RenderCLI.value(args, "--spec") == "theme-window" {
            guard out.contains("/.re/") || out.hasPrefix(".re/") else { throw CLIError(description: "capture comparisons must stay in .re") }
            let w = Double(arc.width), h = Double(arc.height)
            let regions: [(String, CGRect)] = [
                ("sidebar empty", CGRect(x: 60, y: 900, width: 380, height: 400)),
                ("sidebar left", CGRect(x: 3, y: 500, width: 4, height: 600)),
                ("sidebar foot", CGRect(x: 60, y: h - 80, width: 380, height: 24)),
                ("top strip", CGRect(x: 540, y: 2, width: w - 620, height: 4)),
                ("bottom strip", CGRect(x: 540, y: h - 6, width: w - 620, height: 4)),
                ("right strip", CGRect(x: w - 6, y: 80, width: 4, height: h - 160)),
            ]
            let results = regions.map { name, region -> Result in
                var result = Result(name: name); result.arcColor = arc.mean(region); result.oursColor = ours.mean(region)
                result.deltaE = ColorMath.deltaE2000(result.arcColor!, result.oursColor!); return result
            }
            let dir = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let table = markdown(results, title: "F0139 theme window — background-only regions")
            try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8); print(table)
            if results.contains(where: { ($0.deltaE ?? .infinity) > 2 }) { throw CLIError(description: "theme-window color comparison failed") }
            return
        }
        let layout = SpecLayout(args: args, windowHeight: Double(arc.height) / scale)
        let skip = RenderCLI.value(args, "--skip")?.split(separator: ",").map(String.init) ?? []
        let elements = layout.elements().filter { e in !skip.contains { e.name.contains($0) } }
        var results: [Result] = []
        for e in elements { results.append(measure(e, arc: arc, ours: ours, scale: scale)) }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let table = markdown(results, title: RenderCLI.value(args, "--title") ?? "comparison")
        try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        writeImages(arc: arc, ours: ours, layout: layout, scale: scale, dir: dir)
    }

    // MARK: Measurement

    static func measure(_ e: Element, arc: Bitmap, ours: Bitmap, scale: Double) -> Result {
        var r = Result(name: e.name)
        let px = CGRect(x: e.region.minX * scale, y: e.region.minY * scale, width: e.region.width * scale, height: e.region.height * scale).integral
        switch e.kind {
        case .background(let points):
            var des: [Double] = []
            var a = [0.0, 0, 0], o = [0.0, 0, 0]
            for p in points {
                let s = CGRect(x: p.x * scale - 2, y: p.y * scale - 2, width: 5, height: 5)
                let ca = arc.mean(s), co = ours.mean(s)
                des.append(ColorMath.deltaE2000(ca, co))
                for i in 0..<3 { a[i] += ca[i] / Double(points.count); o[i] += co[i] / Double(points.count) }
            }
            r.deltaE = des.reduce(0, +) / Double(des.count)
            r.arcColor = a; r.oursColor = o
            r.note = String(format: "%d points, max ΔE %.2f", des.count, des.max() ?? 0)
        case .fill(let sample):
            let s = CGRect(x: sample.minX * scale, y: sample.minY * scale, width: sample.width * scale, height: sample.height * scale).integral
            let ca = arc.mean(s), co = ours.mean(s)
            r.arcColor = ca; r.oursColor = co
            r.deltaE = ColorMath.deltaE2000(ca, co)
            r.arcBox = arc.inkBox(px, contrastFrom: s)
            r.oursBox = ours.inkBox(px, contrastFrom: s)
        case .emoji:
            // Multi-tone glyphs: compare contrast-weighted centroids, not threshold boxes.
            let ca = arc.centroid(px), co = ours.centroid(px)
            if let ca, let co {
                r.positionError = max(abs(ca.x - co.x), abs(ca.y - co.y)) / scale
                r.note = String(format: "centroid Δ %.1f, %.1f px", co.x - ca.x, co.y - ca.y)
            }
            return r
        case .ink:
            let (ba, ca) = arc.ink(px)
            let (bo, co) = ours.ink(px)
            r.arcBox = ba; r.oursBox = bo
            r.arcColor = ca; r.oursColor = co
            if let ca, let co { r.deltaE = ColorMath.deltaE2000(ca, co) }
        }
        if let a = r.arcBox, let o = r.oursBox {
            r.positionError = [abs(a.minX - o.minX), abs(a.minY - o.minY), abs(a.maxX - o.maxX), abs(a.maxY - o.maxY)].max()! / scale
        }
        return r
    }

    static func markdown(_ results: [Result], title: String) -> String {
        func hex(_ c: [Double]?) -> String {
            guard let c else { return "—" }
            return String(format: "#%02X%02X%02X", Int(c[0].rounded()), Int(c[1].rounded()), Int(c[2].rounded()))
        }
        func box(_ b: CGRect?) -> String {
            guard let b else { return "—" }
            return "\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))"
        }
        var s = "### \(title)\n\n| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |\n|---|---|---|---|---|---|---|\n"
        var worstPos = 0.0, worstDE = 0.0
        for r in results {
            let pos = r.positionError.map { String(format: "%.1f", $0) } ?? "—"
            let de = r.deltaE.map { String(format: "%.2f", $0) } ?? "—"
            worstPos = max(worstPos, r.positionError ?? 0); worstDE = max(worstDE, r.deltaE ?? 0)
            s += "| \(r.name)\(r.note.isEmpty ? "" : " (\(r.note))") | \(pos) | \(de) | \(hex(r.arcColor)) | \(hex(r.oursColor)) | \(box(r.arcBox)) | \(box(r.oursBox)) |\n"
        }
        s += String(format: "\nWorst position error %.1f pt, worst ΔE00 %.2f, %d elements.\n", worstPos, worstDE, results.count)
        return s
    }

    // MARK: Images

    static func writeImages(arc: Bitmap, ours: Bitmap, layout: SpecLayout, scale: Double, dir: URL) {
        let w = Int(layout.sidebarWidth * scale), h = arc.height
        let masks = layout.masks().map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        let gap = 4
        var sheet = Bitmap(width: 3 * w + 2 * gap, height: h, fill: 255)
        for y in 0..<h {
            for x in 0..<w {
                let masked = masks.contains { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }
                let a = arc.pixel(x, y), o = ours.pixel(x, y)
                sheet.set(x, y, masked ? [128, 128, 128] : a)
                sheet.set(w + gap + x, y, masked ? [128, 128, 128] : o)
                // Diff heat: |Δ| × 4, red where Open is darker, blue where lighter.
                if masked { sheet.set(2 * (w + gap) + x, y, [40, 40, 40]); continue }
                let la = 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]
                let lo = 0.2126 * o[0] + 0.7152 * o[1] + 0.0722 * o[2]
                let d = min(255, abs(la - lo) * 4)
                let c = max(abs(a[0] - o[0]), abs(a[1] - o[1]), abs(a[2] - o[2]))
                let v = max(d, min(255, c * 4))
                sheet.set(2 * (w + gap) + x, y, lo < la ? [255, 255 - v, 255 - v] : [255 - v, 255 - v, 255])
            }
        }
        sheet.write(to: dir.appendingPathComponent("side-by-side.png"))
    }
}

/// Element positions for a sidebar state, from the measured metrics. All values
/// are window points; the window's top-left corner is the origin.
@MainActor
struct SpecLayout {
    var sidebarWidth: Double = 228
    var windowHeight: Double
    var favorites = 6
    var pinnedRows = 10
    var todayRows = 0
    var hoverRow: Int?
    var selectedRow: Int?
    var newTabOpen = false
    var dark = false
    /// A page is loaded: the URL field shows the host and its two buttons, reload is enabled.
    var pageLoaded = false
    var selectedTile: Int?
    var hoverNewTab = false
    var hoverButton: String?
    /// Depth of each row in display order (folder children are indented 16 pt).
    var depths: [Int] = []
    /// Rows drawn as split rows (two cells).
    var splitRows: Set<Int> = []
    /// A selected split row: the card, one cell per pane, titles at the pane pitch (F0081).
    var selectedSplitRow: Int?
    var splitPanes = 2
    /// The source row of an open Peek: its badge plate; with `--peek-shown`, its lighter fill (F0090).
    var peekRow: Int?
    var peekShown = false
    /// Split-row titles measured at the pane pitch (x = icon + 26, width pitch − 38), not at the
    /// depth-1 offsets used for F0079. Opt-in, so earlier state tables stay comparable.
    var pitchSplitTitles = false

    init(args: [String], windowHeight: Double) {
        self.windowHeight = windowHeight
        if let v = RenderCLI.value(args, "--width").flatMap(Double.init) { sidebarWidth = v }
        if let v = RenderCLI.value(args, "--favorites").flatMap(Int.init) { favorites = v }
        if let v = RenderCLI.value(args, "--rows").flatMap(Int.init) { pinnedRows = v }
        if let v = RenderCLI.value(args, "--today").flatMap(Int.init) { todayRows = v }
        hoverRow = RenderCLI.value(args, "--hover-row").flatMap(Int.init)
        selectedRow = RenderCLI.value(args, "--selected-row").flatMap(Int.init)
        newTabOpen = args.contains("--new-tab-open")
        dark = args.contains("--dark")
        pageLoaded = args.contains("--page-loaded")
        selectedTile = RenderCLI.value(args, "--selected-tile").flatMap(Int.init)
        hoverNewTab = args.contains("--hover-newtab")
        hoverButton = RenderCLI.value(args, "--hover-button")
        depths = RenderCLI.value(args, "--depths")?.split(separator: ",").compactMap { Int($0) } ?? []
        splitRows = Set(RenderCLI.value(args, "--split-rows")?.split(separator: ",").compactMap { Int($0) } ?? [])
        selectedSplitRow = RenderCLI.value(args, "--selected-split-row").flatMap(Int.init)
        if let v = RenderCLI.value(args, "--split-panes").flatMap(Int.init) { splitPanes = v }
        peekRow = RenderCLI.value(args, "--peek-row").flatMap(Int.init)
        peekShown = args.contains("--peek-shown")
        pitchSplitTitles = args.contains("--pitch-split-titles")
    }

    /// Split cell pitch (cell width + 4 pt gap) for a row at this indent.
    func splitPitch(_ row: Int) -> Double { (sidebarWidth - 16 - indent(row) - 4) / Double(splitPanes) }

    var favHeight: Double { Double(FavoritesMetrics.sectionHeight(count: favorites, sidebarWidth: CGFloat(sidebarWidth))) }
    var headerTop: Double { Double(FavoritesMetrics.sectionTop) + favHeight }
    var firstRowTop: Double { headerTop + Double(SpaceListMetrics.headerHeight + SpaceListMetrics.spacerRowHeight) }
    /// Row tops in display order: pinned, [divider], New Tab, Today.
    func rowTop(_ i: Int) -> Double { firstRowTop + Double(i) * 41 }
    var dividerTop: Double? { todayRows > 0 ? rowTop(pinnedRows) : nil }
    var newTabTop: Double { rowTop(pinnedRows) + (todayRows > 0 ? 17 : 0) }
    func todayTop(_ i: Int) -> Double { newTabTop + 41 + Double(i) * 41 }
    var rowCount: Int { pinnedRows + todayRows }
    /// Display index → row top (pinned first, then Today).
    func top(ofRow i: Int) -> Double { i < pinnedRows ? rowTop(i) : todayTop(i - pinnedRows) }

    func tileFrames() -> [CGRect] {
        let cols = FavoritesMetrics.columns(count: favorites, sidebarWidth: CGFloat(sidebarWidth))
        let tw = Double(FavoritesMetrics.tileWidth(sidebarWidth: CGFloat(sidebarWidth), columns: cols))
        return (0..<favorites).map { i in
            CGRect(x: 8 + Double(i % cols) * (tw + 8), y: 90 + Double(i / cols) * 55, width: tw, height: 47)
        }
    }

    func masks() -> [CGRect] {
        var m = tileFrames().map { CGRect(x: $0.midX - 12, y: $0.midY - 12, width: 24, height: 24) }
        for i in 0..<rowCount {
            let x = 15 + indent(i)
            m.append(CGRect(x: x, y: top(ofRow: i) + 9, width: 22, height: 22))
            if i == selectedSplitRow {
                for c in 1..<splitPanes { m.append(CGRect(x: x + Double(c) * splitPitch(i), y: top(ofRow: i) + 9, width: 22, height: 22)) }
            } else if isSplit(i) { m.append(CGRect(x: x + 96, y: top(ofRow: i) + 9, width: 22, height: 22)) }
            if i == peekRow { m.append(CGRect(x: sidebarWidth - 36, y: top(ofRow: i) + 10, width: 20, height: 20)) }
        }
        m.append(CGRect(x: sidebarWidth, y: 0, width: 4000, height: windowHeight))
        // System-drawn parts: traffic lights and the window's rounded corners.
        m.append(CGRect(x: 8, y: 12, width: 70, height: 24))
        m.append(CGRect(x: 0, y: 0, width: 18, height: 18))
        m.append(CGRect(x: 0, y: windowHeight - 18, width: 18, height: 18))
        return m
    }

    func indent(_ row: Int) -> Double { Double(row < depths.count ? max(depths[row], 0) : 0) * 16 }
    func isSplit(_ row: Int) -> Bool { splitRows.contains(row) }

    func elements() -> [Compare.Element] {
        typealias E = Compare.Element
        let W = sidebarWidth, H = windowHeight
        var e: [E] = []
        // Background: empty sidebar areas, rows of samples between elements.
        var bg: [CGPoint] = []
        let listEnd = (todayRows > 0 ? todayTop(todayRows - 1) : newTabTop) + 41
        for y in stride(from: listEnd + 20, to: H - 60, by: 40) { for x in stride(from: 20.0, to: W - 10, by: 40) { bg.append(CGPoint(x: x, y: y)) } }
        for y in stride(from: 100.0, to: H - 60, by: 60) { bg.append(CGPoint(x: 4, y: y)) }
        e.append(E(name: "background (sidebar column)", region: .zero, kind: .background(bg)))
        if !pageLoaded {
            e.append(E(name: "panel fill (empty state)", region: .zero, kind: .background(stride(from: 60.0, to: H - 60, by: 120).map { CGPoint(x: W + 300, y: $0) })))
        }
        // Toolbar glyphs.
        e.append(E(name: "toolbar: sidebar toggle", region: CGRect(x: 77, y: 7, width: 32, height: 32), kind: .ink))
        let navX = Double(ChromeMetrics.backX(sidebarWidth: CGFloat(W)))
        for (i, n) in ["back", "forward", "reload"].enumerated() {
            e.append(E(name: "toolbar: \(n)", region: CGRect(x: navX + Double(i) * 34, y: 7, width: 32, height: 32), kind: .ink))
        }
        // URL field.
        e.append(E(name: "URL field fill", region: CGRect(x: 8, y: 46, width: W - 16, height: 36), kind: .fill(sample: CGRect(x: 60, y: 48, width: 120, height: 4))))
        if pageLoaded {
            e.append(E(name: "URL field host", region: CGRect(x: 18, y: 54, width: W - 92, height: 21), kind: .ink))
            e.append(E(name: "URL field copy button", region: CGRect(x: W - 70, y: 49, width: 30, height: 30), kind: .ink))
            e.append(E(name: "URL field site controls", region: CGRect(x: W - 42, y: 49, width: 30, height: 30), kind: .ink))
        } else {
            e.append(E(name: "URL field magnifier", region: CGRect(x: 15, y: 53, width: 22, height: 22), kind: .ink))
            e.append(E(name: "URL field placeholder", region: CGRect(x: 40, y: 54, width: W - 50, height: 21), kind: .ink))
        }
        // Favorites.
        for (i, t) in tileFrames().enumerated() {
            let name = i == selectedTile ? "favorite tile \(i + 1) selected" : "favorite tile \(i + 1)"
            e.append(E(name: name, region: t, kind: .fill(sample: CGRect(x: t.minX + 6, y: t.minY + 4, width: t.width - 12, height: 6))))
        }
        // Space header.
        e.append(E(name: "Space icon", region: CGRect(x: 13, y: headerTop + 5, width: 26, height: 26), kind: .emoji))
        e.append(E(name: "Space title", region: CGRect(x: 40, y: headerTop + 8, width: W - 56, height: 21), kind: .ink))
        // Rows.
        for i in 0..<rowCount {
            let y = top(ofRow: i)
            let titleRight = (i == hoverRow || i == selectedRow) ? 186.0 : (i == peekRow ? W - 40 : W - 12)
            let tx = 41 + indent(i)
            if i == selectedSplitRow {
                let ind = indent(i), pitch = splitPitch(i)
                e.append(E(name: "row \(i + 1) split card fill", region: CGRect(x: 8 + ind, y: y + 2, width: W - 16 - ind, height: 36),
                           kind: .fill(sample: CGRect(x: 30 + ind, y: y + 3, width: 60, height: 2))))
                for c in 0..<splitPanes {
                    let cx = 12 + ind + Double(c) * pitch
                    e.append(E(name: "row \(i + 1) split cell \(c + 1) fill", region: CGRect(x: cx, y: y + 6, width: pitch - 4, height: 28),
                               kind: .fill(sample: CGRect(x: cx + 12, y: y + 7, width: pitch - 28, height: 2))))
                    e.append(E(name: "row \(i + 1) split cell \(c + 1) title", region: CGRect(x: cx + 31, y: y + 8, width: pitch - 36, height: 25), kind: .ink))
                }
            } else if isSplit(i) && pitchSplitTitles {
                for c in 0..<splitPanes {
                    e.append(E(name: "row \(i + 1) split title \(c + 1)", region: CGRect(x: 43 + indent(i) + Double(c) * splitPitch(i), y: y + 8, width: splitPitch(i) - 38, height: 25), kind: .ink))
                }
            } else if isSplit(i) {
                e.append(E(name: "row \(i + 1) split title 1", region: CGRect(x: tx + 18, y: y + 8, width: 60, height: 25), kind: .ink))
                e.append(E(name: "row \(i + 1) split title 2", region: CGRect(x: tx + 114, y: y + 8, width: 60, height: 25), kind: .ink))
            } else {
                e.append(E(name: "row \(i + 1) title", region: CGRect(x: tx, y: y + 8, width: titleRight - tx, height: 25), kind: .ink))
            }
            if i == peekRow {
                if peekShown {
                    e.append(E(name: "row \(i + 1) Peek source fill", region: CGRect(x: 8 + indent(i), y: y + 2, width: W - 16 - indent(i), height: 36),
                               kind: .fill(sample: CGRect(x: 150, y: y + 5, width: 30, height: 4))))
                }
                e.append(E(name: "row \(i + 1) Peek badge plate", region: CGRect(x: W - 38, y: y + 8, width: 24, height: 24),
                           kind: .fill(sample: CGRect(x: W - 33, y: y + 9, width: 14, height: 2))))
            }
            if i == hoverRow || i == selectedRow {
                let name = i == selectedRow ? "row \(i + 1) selected fill" : "row \(i + 1) hover fill"
                e.append(E(name: name, region: CGRect(x: 8 + indent(i), y: y + 2, width: W - 16 - indent(i), height: 36),
                           kind: .fill(sample: CGRect(x: 150, y: y + 5, width: 30, height: 4))))
                e.append(E(name: "row \(i + 1) close button", region: CGRect(x: W - 39, y: y + 7, width: 26, height: 26), kind: .ink))
            }
        }
        if let d = dividerTop {
            e.append(E(name: "Pinned/Today divider", region: CGRect(x: 10, y: d + 3, width: W - 20, height: 9), kind: .ink))
        }
        let nt = newTabTop
        e.append(E(name: "New Tab plus", region: CGRect(x: 17, y: nt + 11, width: 18, height: 18), kind: .ink))
        e.append(E(name: "New Tab label", region: CGRect(x: 41, y: nt + 8, width: 80, height: 25), kind: .ink))
        if newTabOpen || hoverNewTab {
            e.append(E(name: newTabOpen ? "New Tab selected fill" : "New Tab hover fill", region: CGRect(x: 8, y: nt + 2, width: W - 16, height: 36),
                       kind: .fill(sample: CGRect(x: 150, y: nt + 5, width: 30, height: 4))))
        }
        // Button hover plates: sample a strip inside the plate below the glyph.
        let plates: [String: CGRect] = [
            "toggle": CGRect(x: 77, y: 7, width: 32, height: 32),
            "home": CGRect(x: 8, y: H - 41, width: 32, height: 32),
            "switcher": CGRect(x: 46, y: H - 41, width: 34, height: 32),
            "plus": CGRect(x: W - 40, y: H - 41, width: 32, height: 32),
        ]
        if let b = hoverButton, let p = plates[b] {
            e.append(E(name: "\(b) hover plate", region: p, kind: .fill(sample: CGRect(x: p.minX + 8, y: p.maxY - 4, width: p.width - 16, height: 2))))
        }
        // Bottom bar.
        e.append(E(name: "bottom: Home", region: CGRect(x: 8, y: H - 41, width: 32, height: 32), kind: .ink))
        e.append(E(name: "bottom: plus", region: CGRect(x: W - 40, y: H - 41, width: 32, height: 32), kind: .ink))
        return e
    }
}

/// RGBA8 pixels: sRGB by default, or Display P3 for the §17 capture corpus.
@MainActor
struct Bitmap {
    let width: Int, height: Int
    var data: [UInt8]

    init(width: Int, height: Int, fill: UInt8) {
        self.width = width; self.height = height
        data = [UInt8](repeating: fill, count: width * height * 4)
    }

    /// Loads a PNG through its embedded profile into the requested color space.
    init(path: String, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CLIError(description: "cannot read \(path)") }
        self.init(image: img, colorSpace: colorSpace)
    }

    init(image img: CGImage, colorSpace: CGColorSpace) {
        width = img.width; height = img.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func pixel(_ x: Int, _ y: Int) -> [Double] {
        let i = (y * width + x) * 4
        return [Double(data[i]), Double(data[i + 1]), Double(data[i + 2])]
    }

    mutating func set(_ x: Int, _ y: Int, _ c: [Double]) {
        let i = (y * width + x) * 4
        data[i] = UInt8(max(0, min(255, c[0].rounded()))); data[i + 1] = UInt8(max(0, min(255, c[1].rounded())))
        data[i + 2] = UInt8(max(0, min(255, c[2].rounded()))); data[i + 3] = 255
    }

    func lum(_ x: Int, _ y: Int) -> Double { let p = pixel(x, y); return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] }

    func clamp(_ r: CGRect) -> (Int, Int, Int, Int) {
        (max(0, Int(r.minX)), max(0, Int(r.minY)), min(width, Int(r.maxX)), min(height, Int(r.maxY)))
    }

    func mean(_ r: CGRect) -> [Double] {
        let (x0, y0, x1, y1) = clamp(r)
        var s = [0.0, 0, 0], n = 0.0
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) { let p = pixel(x, y); s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n += 1 } }
        return n > 0 ? s.map { $0 / n } : s
    }

    /// Least-squares plane through the luminance of the 1 px ring just outside `r`.
    func plane(_ r: CGRect) -> (Double, Double, Double) {
        let (x0, y0, x1, y1) = clamp(r.insetBy(dx: -1, dy: -1))
        var pts: [(Double, Double, Double)] = []
        for x in x0..<x1 { pts.append((Double(x), Double(y0), lum(x, y0))); pts.append((Double(x), Double(y1 - 1), lum(x, y1 - 1))) }
        for y in y0..<y1 { pts.append((Double(x0), Double(y), lum(x0, y))); pts.append((Double(x1 - 1), Double(y), lum(x1 - 1, y))) }
        // Normal equations for z = a + b·x + c·y.
        var m = [[Double]](repeating: [0, 0, 0], count: 3), v = [0.0, 0, 0]
        for (x, y, z) in pts {
            let row = [1, x, y]
            for i in 0..<3 { for j in 0..<3 { m[i][j] += row[i] * row[j] }; v[i] += row[i] * z }
        }
        let s = ColorMath.solve3(m, v) ?? [pts.map(\.2).reduce(0, +) / Double(max(pts.count, 1)), 0, 0]
        return (s[0], s[1], s[2])
    }

    /// Ink box and core color of a text or glyph region.
    func ink(_ r: CGRect) -> (CGRect?, [Double]?) {
        let (a, b, c) = plane(r)
        let (x0, y0, x1, y1) = clamp(r)
        var peak = 0.0
        for y in y0..<y1 { for x in x0..<x1 { peak = max(peak, abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))) } }
        guard peak > 6 else { return (nil, nil) }
        var box: CGRect?
        var s = [0.0, 0, 0], n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let d = abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))
                if d >= 0.5 * peak { box = (box ?? CGRect(x: x, y: y, width: 0, height: 0)).union(CGRect(x: x, y: y, width: 1, height: 1)) }
                if d >= 0.85 * peak { let p = pixel(x, y); s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n += 1 }
            }
        }
        return (box, n > 0 ? s.map { $0 / n } : nil)
    }

    /// Contrast-weighted centroid of a region (against the ring plane).
    func centroid(_ r: CGRect) -> CGPoint? {
        let (a, b, c) = plane(r)
        let (x0, y0, x1, y1) = clamp(r)
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in y0..<y1 { for x in x0..<x1 {
            let d = abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))
            guard d > 3 else { continue }
            sx += d * Double(x); sy += d * Double(y); sw += d
        } }
        return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : nil
    }

    /// Box of a fill: pixels at least half-way from the ring plane to the sample's level.
    func inkBox(_ r: CGRect, contrastFrom sample: CGRect) -> CGRect? {
        let (a, b, c) = plane(r)
        let m = mean(sample)
        let sl = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]
        let cx = Double(sample.midX), cy = Double(sample.midY)
        let contrast = sl - (a + b * cx + c * cy)
        guard abs(contrast) > 1.5 else { return nil }
        let (x0, y0, x1, y1) = clamp(r)
        var box: CGRect?
        // Scan the middle row and middle column only: text inside the fill must not count.
        let midY = Int(Double(y0 + y1) / 2), midX = Int(Double(x0 + x1) / 2)
        for x in x0..<x1 where (lum(x, midY) - (a + b * Double(x) + c * Double(midY))) / contrast >= 0.5 {
            box = (box ?? CGRect(x: x, y: midY, width: 0, height: 0)).union(CGRect(x: x, y: midY, width: 1, height: 1))
        }
        for y in y0..<y1 where (lum(midX, y) - (a + b * Double(midX) + c * Double(y))) / contrast >= 0.5 {
            box = (box ?? CGRect(x: midX, y: y, width: 0, height: 0)).union(CGRect(x: midX, y: y, width: 1, height: 1))
        }
        return box
    }

    func write(to url: URL) {
        var copy = data
        let w = width, h = height
        let image: CGImage? = copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        if let image { OffscreenRenderer.writePNG(image, to: url) }
    }
}

enum ColorMath {
    static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { k in
            var mk = m
            for i in 0..<3 { mk[i][k] = v[i] }
            return det(mk) / d
        }
    }

    /// sRGB (0…255) → CIE Lab (D65).
    static func lab(_ c: [Double]) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c[0]), g = lin(c[1]), b = lin(c[2])
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > pow(6.0 / 29, 3) ? cbrt(t) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func deltaE2000(_ c1: [Double], _ c2: [Double]) -> Double {
        let (L1, a1, b1) = lab(c1), (L2, a2, b2) = lab(c2)
        let rad = Double.pi / 180
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) / rad; return h < 0 ? h + 360 : h }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp = h2p - h1p
        if C1p * C2p == 0 { dhp = 0 } else if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * rad)
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp = h1p + h2p
        if C1p * C2p != 0 { hbp = abs(h1p - h2p) > 180 ? (hbp + (hbp < 360 ? 360 : -360)) / 2 : hbp / 2 }
        let T = 1 - 0.17 * cos((hbp - 30) * rad) + 0.24 * cos(2 * hbp * rad) + 0.32 * cos((3 * hbp + 6) * rad) - 0.20 * cos((4 * hbp - 63) * rad)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * rad) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }
}
