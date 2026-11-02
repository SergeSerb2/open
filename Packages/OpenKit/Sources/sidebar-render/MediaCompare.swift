import AppKit
import ImageIO
import OpenDesign
import OpenSidebar

/// Media plan §13.8.6, using the same sRGB/plane/ink/CIEDE2000 method as Compare.
@MainActor enum MediaCompare {
    static func run(_ args: [String]) throws {
        if RenderCLI.value(args, "--state")?.hasPrefix("row-") == true { try RowMediaCompare.run(args); return }
        guard let a = RenderCLI.value(args, "--arc"), let o = RenderCLI.value(args, "--ours"),
              let out = RenderCLI.value(args, "--out"), let state = RenderCLI.value(args, "--state"),
              ["rest", "expanded", "stack", "stack-expanded"].contains(state) else { throw CLIError(description: RenderCLI.usage) }
        // The output contains capture pixels. Keep it inside the ignored evidence tree.
        let dir = URL(fileURLWithPath: out).standardizedFileURL
        guard dir.pathComponents.contains(".re") else { throw CLIError(description: "compare-media output must be under .re") }
        var arc = try Bitmap(path: a)
        let ours = try Bitmap(path: o)
        // E3 has one extra trailing capture row; AX and card pixels use the same top-left origin.
        let hadTrailingRow = arc.width == 1728 && arc.height == 1085
        if hadTrailingRow {
            var normalized = Bitmap(width: 1728, height: 1084, fill: 0)
            normalized.data = Array(arc.data.prefix(1728 * 1084 * 4)); arc = normalized
        }
        guard arc.width == 1728, arc.height == 1084, arc.width == ours.width, arc.height == ours.height else {
            throw CLIError(description: "compare-media requires matching 1728x1084 images at 1x")
        }
        let expanded = state.contains("expanded"), stack = state.hasPrefix("stack"), n = stack ? 3 : 1
        var elements: [Compare.Element] = [], masks: [CGRect] = [CGRect(x: 0, y: 1034, width: 228, height: 50)]
        for i in args.indices where args[i] == "--mask" {
            guard i + 1 < args.count else { throw CLIError(description: "missing media mask") }
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { throw CLIError(description: "invalid media mask") }
            masks.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        for i in 0..<n {
            let h: CGFloat = expanded ? 66 : 33, x: CGFloat = 8 + (expanded ? 0 : CGFloat(i) * 5)
            let w: CGFloat = 228 - 2 * x, y: CGFloat = 1034 - h - CGFloat(i) * (expanded ? 71 : 7)
            let card = CGRect(x: x, y: y, width: w, height: h)
            let cy = y + h - 33
            masks.append(CGRect(x: x + 10, y: cy + 5, width: 24, height: 24))
            if !expanded && i > 0 {
                elements.append(.init(name: "Back card \(i) visible edges", region: CGRect(x: x - 2, y: y - 2, width: w + 4, height: 11), kind: .fill(sample: CGRect(x: 40, y: y + 2, width: 150, height: 3))))
                elements.append(.init(name: "Back strip \(i)", region: CGRect(x: 40, y: y + 2, width: 150, height: 3), kind: .fill(sample: CGRect(x: 40, y: y + 2, width: 150, height: 3))))
                continue
            }
            // Fill scans run through the gap between slots, away from the title and glyphs.
            let sample = CGRect(x: x + MiniPlayerMetrics.slotX(2, cardWidth: w, scale: 1) + 27, y: cy + 14, width: 6, height: 4)
            elements.append(.init(name: "Card \(i) edges and fill", region: card.insetBy(dx: -2, dy: -2), kind: .fill(sample: sample)))
            for (slot, name) in [(1,"Previous"), (2,"Pause"), (3,"Next"), (4,"Volume")] {
                let sx = x + MiniPlayerMetrics.slotX(slot, cardWidth: w, scale: 1)
                elements.append(.init(name: "Card \(i) \(name)", region: CGRect(x: sx + 2, y: cy + 6, width: 20, height: 22), kind: .ink))
            }
            if expanded {
                elements.append(.init(name: "Card \(i) title", region: CGRect(x: x + 14, y: y + 7, width: w - 82, height: 19), kind: .ink))
                elements.append(.init(name: "Card \(i) title fill", region: CGRect(x: x + w - 79, y: y + 3, width: 6, height: 4), kind: .fill(sample: CGRect(x: x + w - 79, y: y + 3, width: 6, height: 4))))
                for (trailing, name) in [(58,"PiP"), (34,"Close")] {
                    elements.append(.init(name: "Card \(i) \(name)", region: CGRect(x: x + w - CGFloat(trailing) + 2, y: y + 6, width: 20, height: 22), kind: .ink))
                }
                if i > 0 {
                    let gap = CGRect(x: 40, y: y + 68, width: 150, height: 1)
                    elements.append(.init(name: "Expanded gap \(i)", region: gap, kind: .fill(sample: gap)))
                }
            }
        }
        // Hover plate samples exclude glyph ink. Its box uses a scan near the plate edge.
        if expanded {
            let x: CGFloat = stack ? 102 : 186, y: CGFloat = 1006
            let region = CGRect(x: x, y: y, width: 24, height: 24)
            elements.append(.init(name: "Hover plate", region: region.insetBy(dx: -1, dy: -1), kind: .fill(sample: CGRect(x: x + 3, y: y + 3, width: 3, height: 3))))
        }
        // Masks exclude fill/background samples and the diff only. Ink boxes and
        // glyph/title core colors are measured from the original image pixels.
        func sample(_ bitmap: Bitmap, _ rect: CGRect) throws -> [Double] {
            let (x0,y0,x1,y1)=bitmap.clamp(rect)
            var sum=[0.0,0,0], count=0.0
            for y in y0..<y1 { for x in x0..<x1 where !masks.contains(where: { $0.contains(CGPoint(x:x,y:y)) }) {
                let pixel=bitmap.pixel(x,y); for channel in 0..<3 { sum[channel] += pixel[channel] }; count += 1
            } }
            guard count > 0 else { throw CLIError(description:"media fill sample is fully masked") }
            return sum.map { $0/count }
        }
        var results: [Compare.Result] = []
        for element in elements {
            var result=Compare.measure(element,arc:arc,ours:ours,scale:1)
            if case .fill(let rect)=element.kind {
                let ac=try sample(arc,rect), oc=try sample(ours,rect)
                result.arcColor=ac;result.oursColor=oc;result.deltaE=ColorMath.deltaE2000(ac,oc)
            }
            results.append(result)
        }
        for i in results.indices where results[i].name.contains("visible edges") {
            if let a = results[i].arcBox, let o = results[i].oursBox {
                results[i].positionError = max(abs(a.minX-o.minX),abs(a.maxX-o.maxX),abs(a.minY-o.minY))
                results[i].deltaE = nil; results[i].note = "top/left/right; bottom occluded"
            }
        }
        // Stack titles differ. Do not compare their right edges (§13.8.6).
        for i in results.indices where stack && results[i].name.hasSuffix(" title") {
            if let a = results[i].arcBox, let o = results[i].oursBox {
                results[i].positionError = max(abs(a.minX-o.minX), abs(a.minY-o.minY), abs(a.maxY-o.maxY))
                results[i].note = "left/top/bottom"
            }
        }
        // Sample-only rows have no position gate.
        for i in results.indices where results[i].name.contains("strip") || results[i].name.contains("gap") || results[i].name.contains("title fill") {
            results[i].positionError = nil; results[i].arcBox = nil; results[i].oursBox = nil
        }
        var table = Compare.markdown(results, title: "Media \(state)")
        if hadTrailingRow { table += "\nE3 capture: excluded the extra trailing row (1085 → 1084); top-left origin unchanged.\n" }
        table += "\nTargets: each box edge ≤ 1 pt; each color ΔE00 ≤ 2.\n"
        if let ar = RenderCLI.value(args, "--arc-reference"), let or = RenderCLI.value(args, "--ours-reference") {
            let ab = try Bitmap(path: ar), ob = try Bitmap(path: or)
            guard ab.width == arc.width, ab.height == arc.height, ob.width == ours.width, ob.height == ours.height else { throw CLIError(description: "media reference size mismatch") }
            table += "\n| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |\n|---|---|---|---|\n"
            for d in [0,2,4] {
                let rect = CGRect(x: 45, y: 1034+d, width: 140, height: 1)
                func darkening(_ image: Bitmap, _ ref: Bitmap) -> Double {
                    let p = image.mean(rect), b = ref.mean(rect)
                    return 100 * (1 - zip(p,b).map(*).reduce(0,+) / max(1, b.map { $0*$0 }.reduce(0,+)))
                }
                let ad = darkening(arc,ab), od = darkening(ours,ob)
                table += String(format: "| %.1f | %.2f | %.2f | %.2f |\n", Double(d)+0.5, ad, od, abs(ad-od))
            }
            table += "\nShadow target: difference ≤ 1.5 percentage points. Samples below the front card, against the same scene without media; exempt from the bottom-bar mask.\n"
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        // Capture panes remain intact locally. Masks affect only the diff pane.
        var sheet = Bitmap(width: 692, height: 1084, fill: 255)
        for y in 0..<1084 { for x in 0..<228 {
            let masked = masks.contains { $0.contains(CGPoint(x: x, y: y)) }
            let ac = arc.pixel(x,y), oc = ours.pixel(x,y)
            sheet.set(x,y,ac); sheet.set(x+232,y,oc)
            sheet.set(x+464,y,masked ? [128,128,128] : zip(ac,oc).map { min(255, abs($0-$1)*4) })
        } }
        sheet.write(to: dir.appendingPathComponent("side-by-side.png"))
    }
}

/// Step 2b, RI5 (media plan §8.2): the leading row speaker against S2 12/0022
/// (audible) and 12/0027 (muted). Rows are aligned by their own row frames (Arc: the
/// AX row around `sidebarTabCellMuteButton`; Open: `--media-frames-out`), so every
/// value is row-relative. Geometry uses the docs/design.md §7 ink method on the 8-bit
/// sRGB bitmaps. Colors use an unclipped float path: embedded ICC → extended linear
/// sRGB (Float32, no gamut clipping) → XYZ D65 → Lab → CIEDE2000.
@MainActor enum RowMediaCompare {
    struct Frames: Codable { var row: [Double]; var button: [Double]; var title: [Double] }
    struct ArcRow { var row: CGRect; var button: CGRect; var titleFrame: CGRect; var title: String }

    /// The row speaker spec frame, row-relative (fact, S2 12/0022, 0027).
    static let glyphRegion = CGRect(x: 41, y: 7, width: 26, height: 26)
    /// Title ink region, row-relative: from right of the speaker to the row's end.
    static let titleRegion = CGRect(x: 65, y: 8, width: 148, height: 24)
    static let favicon = CGRect(x: 17, y: 11, width: 18, height: 18)
    static let plateSample = CGRect(x: 100, y: 3, width: 40, height: 3)

    /// Reads only a local capture. The title stays in memory; errors never include it.
    static func arcRow(axPath: String) throws -> ArcRow {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: axPath)))
        func rect(_ d: [String: Any]) -> CGRect? {
            guard let r = d["rel"] as? [Double], r.count == 4 else { return nil }
            return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        var found: ArcRow?
        func walk(_ value: Any, row: [String: Any]?) {
            guard found == nil else { return }
            if let a = value as? [Any] { a.forEach { walk($0, row: row) }; return }
            guard let d = value as? [String: Any] else { return }
            let current = d["role"] as? String == "AXRow" ? d : row
            if d["id"] as? String == "sidebarTabCellMuteButton", let row = current, let rowRect = rect(row), let button = rect(d) {
                var title: (CGRect, String)?
                func text(_ value: Any) {
                    if let a = value as? [Any] { a.forEach(text); return }
                    guard let d = value as? [String: Any], title == nil else { return }
                    if d["role"] as? String == "AXStaticText", let s = d["value"] as? String, !s.isEmpty, let r = rect(d) { title = (r, s) }
                    if let children = d["children"] as? [Any] { text(children) }
                }
                text(row)
                if let title { found = ArcRow(row: rowRect, button: button, titleFrame: title.0, title: title.1) }
                return
            }
            if let children = d["children"] as? [Any] { walk(children, row: current) }
        }
        walk(root, row: nil)
        guard let found else { throw CLIError(description: "AX row with sidebarTabCellMuteButton unavailable") }
        return found
    }

    /// Open's actual frames of the first visible speaker row, in scene points (top-left origin).
    static func writeOursFrames(scene: RenderScene, context: SidebarContext, to path: String) throws {
        let views = MediaChecks.descendants(scene)
        guard let button = views.first(where: { !$0.isHidden && $0.accessibilityIdentifier() == "sidebarTabCellMuteButton" }),
              let cell = button.superview, let row = cell.superview,
              let title = cell.subviews.first(where: { String(describing: type(of: $0)) == "TextLabel" }) else {
            throw CLIError(description: "no visible row speaker to record")
        }
        func r(_ v: NSView) -> [Double] { let f = v.convert(v.bounds, to: scene); return [f.minX, f.minY, f.width, f.height].map(Double.init) }
        try JSONEncoder().encode(Frames(row: r(row), button: r(button), title: r(title))).write(to: URL(fileURLWithPath: path))
    }

    /// Linear extended-sRGB Float32 pixels; values outside 0…1 stay as they are.
    struct LinearImage {
        let width: Int, height: Int
        var data: [Float]
        init(path: String) throws {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CLIError(description: "cannot read \(path)") }
            try self.init(image: img)
        }
        init(image img: CGImage) throws {
            width = img.width; height = img.height
            data = [Float](repeating: 0, count: img.width * img.height * 4)
            let w = width, h = height
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                    space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw CLIError(description: "float context failed") }
        }
        func linear(_ x: Int, _ y: Int) -> [Double] { let i = (y * width + x) * 4; return [Double(data[i]), Double(data[i + 1]), Double(data[i + 2])] }
        static func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        /// Sign-preserving sRGB encoding on a 0…255 scale (ColorMath inverts it exactly).
        static func srgb255(_ c: [Double]) -> [Double] { c.map { 255 * encode($0) } }
        static func p3Hex(_ c: [Double]) -> String {
            let p = [0.8224621 * c[0] + 0.1775380 * c[1], 0.0331941 * c[0] + 0.9668058 * c[1], 0.0170827 * c[0] + 0.0723974 * c[1] + 0.9105199 * c[2]]
            return hex(srgb255(p))
        }
        static func hex(_ c: [Double]) -> String {
            String(format: "#%02X%02X%02X", Int(max(0, min(255, c[0].rounded()))), Int(max(0, min(255, c[1].rounded()))), Int(max(0, min(255, c[2].rounded()))))
        }
        func mean(_ pixels: [(Int, Int)]) -> [Double] {
            var s = [0.0, 0, 0]
            for (x, y) in pixels { let p = linear(x, y); for k in 0..<3 { s[k] += p[k] } }
            return s.map { $0 / Double(max(1, pixels.count)) }
        }
        func outOfGamut(_ pixels: [(Int, Int)]) -> Int { pixels.filter { linear($0.0, $0.1).contains { $0 < -1e-4 || $0 > 1 + 1e-4 } }.count }
    }

    struct Ink { var box: CGRect; var core: [(Int, Int)]; var peak: (Int, Int) }
    /// docs/design.md §7 steps 4–5: ring plane, ink ≥ 50 % of peak contrast, core ≥ 85 %.
    static func ink(_ b: Bitmap, _ r: CGRect) -> Ink? {
        let (a, bx, cy) = b.plane(r)
        let (x0, y0, x1, y1) = b.clamp(r)
        var peak = 0.0, at = (x0, y0)
        for y in y0..<y1 { for x in x0..<x1 {
            let d = abs(b.lum(x, y) - (a + bx * Double(x) + cy * Double(y)))
            if d > peak { peak = d; at = (x, y) }
        } }
        guard peak > 6 else { return nil }
        var box: CGRect?, core: [(Int, Int)] = []
        for y in y0..<y1 { for x in x0..<x1 {
            let d = abs(b.lum(x, y) - (a + bx * Double(x) + cy * Double(y)))
            if d >= 0.5 * peak { box = (box ?? CGRect(x: x, y: y, width: 0, height: 0)).union(CGRect(x: x, y: y, width: 1, height: 1)) }
            if d >= 0.85 * peak { core.append((x, y)) }
        } }
        return box.map { Ink(box: $0, core: core, peak: at) }
    }

    static func run(_ args: [String]) throws {
        guard let state = RenderCLI.value(args, "--state"), ["row-audible", "row-muted"].contains(state),
              let arcPath = RenderCLI.value(args, "--arc"), let axPath = RenderCLI.value(args, "--arc-ax"),
              let oursPath = RenderCLI.value(args, "--ours"), let framesPath = RenderCLI.value(args, "--ours-frames"),
              let out = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let dir = URL(fileURLWithPath: out).standardizedFileURL
        guard dir.pathComponents.contains(".re") else { throw CLIError(description: "compare-media output must be under .re") }
        let arcRow = try arcRow(axPath: axPath)
        let frames = try JSONDecoder().decode(Frames.self, from: Data(contentsOf: URL(fileURLWithPath: framesPath)))
        func cg(_ v: [Double]) -> CGRect { CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        let arc8 = try Bitmap(path: arcPath), ours8 = try Bitmap(path: oursPath)
        let arcF = try LinearImage(path: arcPath), oursF = try LinearImage(path: oursPath)
        guard arc8.width == 1728, arc8.height == 1084, ours8.width == arc8.width, ours8.height == arc8.height else {
            throw CLIError(description: "row compare requires matching 1728x1084 images at 1x")
        }
        let ay = arcRow.row.minY, oy = cg(frames.row).minY
        func rel(_ r: CGRect, _ y: CGFloat) -> CGRect { r.offsetBy(dx: 0, dy: -y) }
        func edges(_ a: CGRect, _ o: CGRect) -> Double { Double([abs(a.minX - o.minX), abs(a.minY - o.minY), abs(a.maxX - o.maxX), abs(a.maxY - o.maxY)].max()!) }
        func box(_ r: CGRect) -> String { String(format: "[%.0f, %.0f, %.0f, %.0f]", r.minX, r.minY, r.width, r.height) }
        func hex(_ c: [Double]) -> String { LinearImage.hex(LinearImage.srgb255(c)) }
        func de(_ a: [Double], _ o: [Double]) -> Double { ColorMath.deltaE2000(LinearImage.srgb255(a), LinearImage.srgb255(o)) }
        var lines: [String] = [], failures: [String] = []
        func gate(_ name: String, _ value: Double, _ limit: Double) -> String {
            if value > limit + 1e-9 { failures.append(name); return "FAIL" }
            return "PASS"
        }
        lines.append("### RI5 \(state): Arc S2 12 frame vs Open (row-relative points; Arc row y \(Int(ay)), Open row y \(Int(oy)))\n")
        lines.append("| Element | Arc | Open | Error | Target | Result |\n|---|---|---|---|---|---|")
        // Button frame: Arc AX vs Open's view frame.
        let ab = rel(arcRow.button, ay), ob = rel(cg(frames.button), oy), be = edges(ab, ob)
        lines.append("| Speaker button frame (AX) | \(box(ab)) | \(box(ob)) | \(String(format: "%.1f pt", be)) | ≤ 1 pt | \(gate("button frame", be, 1)) |")
        // Glyph ink box, core and peak colors.
        guard let ai = ink(arc8, rel(glyphRegion, -ay)), let oi = ink(ours8, rel(glyphRegion, -oy)) else { throw CLIError(description: "speaker glyph ink not found") }
        let aib = rel(ai.box, ay), oib = rel(oi.box, oy), ie = edges(aib, oib)
        lines.append("| Speaker glyph ink box | \(box(aib)) | \(box(oib)) | \(String(format: "%.1f pt", ie)) | ≤ 1 pt | \(gate("glyph ink box", ie, 1)) |")
        let ac = arcF.mean(ai.core), oc = oursF.mean(oi.core), coreDE = de(ac, oc)
        lines.append("| Speaker glyph core color, ≥ 85 % of peak (sRGB / P3) | \(hex(ac)) / \(LinearImage.p3Hex(ac)) | \(hex(oc)) / \(LinearImage.p3Hex(oc)) | \(String(format: "ΔE00 %.2f", coreDE)) | ≤ 2 | \(gate("glyph core color", coreDE, 2)) |")
        let ap = arcF.linear(ai.peak.0, ai.peak.1), op = oursF.linear(oi.peak.0, oi.peak.1), peakDE = de(ap, op)
        lines.append("| Speaker glyph peak pixel (sRGB / P3) | \(hex(ap)) / \(LinearImage.p3Hex(ap)) | \(hex(op)) / \(LinearImage.p3Hex(op)) | \(String(format: "ΔE00 %.2f", peakDE)) | ≤ 2 | \(gate("glyph peak", peakDE, 2)) |")
        // Title start: ink left, top, bottom (the strings truncate differently at the right).
        guard let at = ink(arc8, rel(titleRegion, -ay)), let ot = ink(ours8, rel(titleRegion, -oy)) else { throw CLIError(description: "title ink not found") }
        let atb = rel(at.box, ay), otb = rel(ot.box, oy)
        let te = Double(max(abs(atb.minX - otb.minX), abs(atb.minY - otb.minY), abs(atb.maxY - otb.maxY)))
        lines.append("| Title start (ink left, top, bottom) | x \(Int(atb.minX)), y \(Int(atb.minY))…\(Int(atb.maxY)) | x \(Int(otb.minX)), y \(Int(otb.minY))…\(Int(otb.maxY)) | \(String(format: "%.1f pt", te)) | ≤ 1 pt | \(gate("title start", te, 1)) |")
        let ata = rel(arcRow.titleFrame, ay), ota = rel(cg(frames.title), oy), tae = Double(abs(ata.minX - ota.minX))
        lines.append("| Title frame x (AX) | \(Int(ata.minX)) | \(Int(ota.minX)) | \(String(format: "%.1f pt", tae)) | ≤ 1 pt | \(gate("title AX x", tae, 1)) |")
        // Context rows, not gates: the plate the glyph sits on, and the title color.
        func pixels(_ r: CGRect) -> [(Int, Int)] { var p: [(Int, Int)] = []; for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { p.append((x, y)) } }; return p }
        let aps = pixels(rel(plateSample, -ay)), ops = pixels(rel(plateSample, -oy))
        let apc = arcF.mean(aps), opc = oursF.mean(ops)
        lines.append("| Selected-row plate (context) | \(hex(apc)) | \(hex(opc)) | \(String(format: "ΔE00 %.2f", de(apc, opc))) | — | info |")
        let atc = arcF.mean(at.core), otc = oursF.mean(ot.core)
        lines.append("| Title core color (context) | \(hex(atc)) | \(hex(otc)) | \(String(format: "ΔE00 %.2f", de(atc, otc))) | — | info |")
        // Clipping proof: measured pixels outside sRGB, and the same core ΔE on the 8-bit sRGB path.
        func mean8(_ b: Bitmap, _ p: [(Int, Int)]) -> [Double] { p.reduce([0.0, 0, 0]) { s, q in zip(s, b.pixel(q.0, q.1)).map(+) }.map { $0 / Double(max(1, p.count)) } }
        let core8 = ColorMath.deltaE2000(mean8(arc8, ai.core), mean8(ours8, oi.core))
        let favMin = pixels(rel(favicon, -ay)).map { arcF.linear($0.0, $0.1).min()! }.min() ?? 0
        // Self-test: a Display P3 pure green pixel must come out of the float path outside sRGB.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let green = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        green?.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!); green?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let probe = try green?.makeImage().map { try LinearImage(image: $0).linear(0, 0) } ?? []
        let selfTest = (String(format: "Clipping self-test: Display P3 (0, 1, 0) → linear sRGB (%.3f, %.3f, %.3f); negative channels prove the float path does not clip to sRGB.",
                            probe.first ?? .nan, probe.dropFirst().first ?? .nan, probe.last ?? .nan))
        lines.append("")
        lines.append("Color pipeline: embedded ICC → extended linear sRGB Float32 (no clipping) → XYZ D65 → Lab → CIEDE2000; the P3 hex shows the same pixels in Display P3.")
        lines.append(String(format: "Measured pixels outside the sRGB gamut: Arc %d, Open %d. The float path keeps out-of-gamut values (Arc favicon minimum linear channel %.3f, not clamped at 0). The 8-bit sRGB path gives glyph core ΔE00 %.2f.",
                            arcF.outOfGamut(ai.core + [ai.peak] + aps), oursF.outOfGamut(oi.core + [oi.peak] + ops), favMin, core8))
        lines.append(selfTest)
        lines.append("Masks (diff pane only): favicon \(box(favicon)) and title text \(box(titleRegion)), row-relative.")
        lines.append("\nRI5 compare \(state): \(failures.isEmpty ? "PASS" : "FAIL (\(failures.joined(separator: ", ")))")")
        let table = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        // Arc | Open | diff × 4 of the row only, 4x nearest. It holds capture pixels: .re only.
        let k = 4, h = 53, w = 228
        var sheet = Bitmap(width: (3 * w + 8) * k, height: h * k, fill: 255)
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: x, y: y - 6), masked = favicon.contains(p) || titleRegion.contains(p)
            let ayy = Int(ay) - 6 + y, oyy = Int(oy) - 6 + y
            guard ayy >= 0, oyy >= 0, ayy < arc8.height, oyy < ours8.height else { continue }
            let a = arc8.pixel(x, ayy), o = ours8.pixel(x, oyy)
            let d = masked ? [128.0, 128, 128] : zip(a, o).map { min(255, abs($0 - $1) * 4) }
            for dy in 0..<k { for dx in 0..<k {
                sheet.set(x * k + dx, y * k + dy, a); sheet.set((x + w + 4) * k + dx, y * k + dy, o); sheet.set((x + 2 * w + 8) * k + dx, y * k + dy, d)
            } }
        } }
        sheet.write(to: dir.appendingPathComponent("side-by-side.png"))
        if !failures.isEmpty { throw CLIError(description: "RI5 compare \(state) FAIL: \(failures.joined(separator: ", "))") }
    }
}
