import AppKit
import OpenDesign

/// Media plan §13.8.6, using the same sRGB/plane/ink/CIEDE2000 method as Compare.
@MainActor enum MediaCompare {
    static func run(_ args: [String]) throws {
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
