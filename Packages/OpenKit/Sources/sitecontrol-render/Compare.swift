import AppKit
import OpenDesign

/// Full-window, profile-converted element comparison. Capture-derived pixels
/// and composites stay in .re; only numeric tables may be published.
@MainActor
enum SiteControlCompare {
    enum Kind { case ink, text, arrow, ring(CGRect), fill(CGRect) }
    struct Element { let name: String; let region: CGRect; let kind: Kind }
    static func run(_ args: [String]) throws {
        guard let arcPath = CLI.value(args,"--arc"),let backdropPath = CLI.value(args,"--backdrop"),let out = CLI.value(args,"--out") else { throw CLIError(description: "compare requires --arc --backdrop --out (.re only)") }
        let directory = URL(fileURLWithPath: out).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.pathComponents.contains(".re") else { throw CLIError(description: "private comparisons must stay in .re") }
        let arc = try Bitmap(path: arcPath),backdrop = try Bitmap(path: backdropPath)
        let state = CLI.value(args,"--state") ?? "scc-no-boosts"
        let stage = Stage(state: state,appearance: .dark,size: CGSize(width: arc.width,height: arc.height),privateBackdrop: backdrop.cgImage())
        let ours = Bitmap(image: stage.render(scale: 1)), body = stage.controller.view.panelFrame
        var elements: [Element] = []
        let tip = stage.controller.view.visibleArrowTip
        for row in 0..<10 {
            elements.append(Element(name: "arrow row " + String(Int(tip.y)+row),region: CGRect(x: tip.x-18,y: tip.y+CGFloat(row),width: 36,height: 1),kind: .arrow))
        }
        for (i,name) in ["Share","New Boost","Capture portion","Capture full page"].enumerated() {
            let b = CGRect(x: body.minX+10+CGFloat(i)*56,y: body.minY+10,width: 48,height: 32)
            elements.append(Element(name: name+" button",region: b.insetBy(dx: -4,dy: -4),kind: .fill(CGRect(x: b.minX+3,y: b.midY-2,width: 2,height: 4))))
            elements.append(Element(name: name+" glyph",region: b.insetBy(dx: 10,dy: 4),kind: .ink))
            elements.append(Element(name: name+" ring",region: b,kind: .ring(b)))
            elements.append(Element(name: name+" highlight",region: b,kind: .fill(CGRect(x: b.minX+12,y: b.minY,width: 24,height: 1))))
            elements.append(Element(name: name+" gradient top",region: b,kind: .fill(CGRect(x: b.minX+3,y: b.minY+2,width: 1,height: 1))))
            elements.append(Element(name: name+" gradient bottom",region: b,kind: .fill(CGRect(x: b.minX+3,y: b.maxY-2,width: 1,height: 1))))
        }
        let footer = body.maxY-42
        elements += [Element(name: "Secure pill",region: CGRect(x: body.minX+9,y: footer-1,width: 84,height: 34),kind: .fill(CGRect(x: body.minX+16,y: footer+26,width: 25,height: 2))),
                     Element(name: "Secure lock",region: CGRect(x: body.minX+18,y: footer+6,width: 14,height: 20),kind: .ink),
                     Element(name: "Secure text",region: CGRect(x: body.minX+34,y: footer+6,width: 50,height: 20),kind: .text),
                     Element(name: "More circle",region: CGRect(x: body.minX+192,y: footer-2,width: 36,height: 36),kind: .fill(CGRect(x: body.minX+206,y: footer+24,width: 8,height: 2))),
                     Element(name: "More glyph",region: CGRect(x: body.minX+202,y: footer+9,width: 16,height: 14),kind: .ink),
                     Element(name: "top rim",region: body,kind: .fill(CGRect(x: body.minX+37,y: body.minY,width: 1,height: 1))),
                     Element(name: "bottom rim",region: body,kind: .fill(CGRect(x: body.minX+37,y: body.maxY-1,width: 1,height: 1)))]
        var table = "| Element | Arc ink box | Open ink box | Max edge error (pt) | DE00 | Result |\n|---|---|---|---|---|---|\n", failed = 0
        for element in elements {
            let ab: CGRect?,ob: CGRect?,ac: [Double]?,oc: [Double]?
            switch element.kind {
            case .ring(let b):
                var points: [CGPoint] = []
                for x in stride(from: b.minX+8,to: b.maxX-8,by: 1) { points += [CGPoint(x: x,y: b.minY-1),CGPoint(x: x,y: b.maxY)] }
                for y in stride(from: b.minY+8,to: b.maxY-8,by: 1) { points += [CGPoint(x: b.minX-1,y: y),CGPoint(x: b.maxX,y: y)] }
                func mean(_ bitmap: Bitmap) -> [Double] { (0..<3).map { channel in points.reduce(0) { $0+bitmap.pixel(Int($1.x),Int($1.y))[channel] }/Double(points.count) } }
                ab = nil; ob = nil; ac = mean(arc); oc = mean(ours)
            case .arrow: (ab,ac) = arc.arrowInk(element.region); (ob,oc) = ours.arrowInk(element.region)
            case .ink,.text: (ab,ac) = arc.ink(element.region); (ob,oc) = ours.ink(element.region)
            case .fill(let sample): ac = arc.mean(sample); oc = ours.mean(sample)
                // Sample-only gradient/rim rows have no separate positional gate.
                if element.name.contains("gradient") || element.name.contains("highlight") || element.name.contains("rim") || element.name.hasSuffix(" ring") { ab = nil; ob = nil }
                else { ab = arc.inkBox(element.region,contrastFrom: sample); ob = ours.inkBox(element.region,contrastFrom: sample) }
            }
            let error = ab.flatMap { a in ob.map { o in [abs(a.minX-o.minX),abs(a.minY-o.minY),abs(a.maxX-o.maxX),abs(a.maxY-o.maxY)].max()! } }
            let de = ac.flatMap { a in oc.map { ColorMath.deltaE2000(a,$0) } }
            let textOnly: Bool; if case .text = element.kind { textOnly = true } else { textOnly = false }
            let requiresBox: Bool
            switch element.kind { case .ink,.text,.arrow: requiresBox = true; case .ring: requiresBox = false; case .fill: requiresBox = !element.name.contains("gradient") && !element.name.contains("highlight") && !element.name.contains("rim") && !element.name.hasSuffix(" ring") }
            let pass = (!requiresBox || (ab != nil && ob != nil)) && (error ?? 0)<=1 && (textOnly || (de ?? .infinity)<=2)
            if !pass { failed += 1 }
            func box(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "—" }
            table += "| \(element.name) | \(box(ab)) | \(box(ob)) | \(error.map { String(format: "%.2f",$0) } ?? "—") | \(de.map { String(format: "%.2f",$0) } ?? "—") | \(pass ? "PASS" : "FAIL") |\n"
        }
        table += "\n| Material probe | Arc sRGB | Open sRGB | DE00 | Result |\n|---|---|---|---|---|\n"
        for (x,y,gated) in [(150,330,true),(180,240,true),(240,330,true),(260,250,true),(235,180,false),(300,330,false)] {
            let a = arc.pixel(x,y),o = ours.pixel(x,y),de = ColorMath.deltaE2000(a,o)
            let pass = de<=3
            if gated && !pass { failed += 1 }
            func rgb(_ p: [Double]) -> String { p.map { String(format: "%02X",Int($0.rounded())) }.joined() }
            table += "| (\(x), \(y)) | #\(rgb(a)) | #\(rgb(o)) | \(String(format: "%.2f",de)) | \(gated ? (pass ? "PASS" : "FAIL") : "reported, not gated") |\n"
        }
        table += "\n| Offscreen glow edge | Set | Arc sRGB | Open sRGB | DE00 | Result |\n|---|---|---|---|---|---|\n"
        for (x,y,fit) in [(120,91,true),(140,91,false),(160,91,false),(180,91,false),(120,387,true),(140,387,false),(160,387,false),(180,387,false)] {
            let a = arc.pixel(x,y),o = ours.pixel(x,y),de = ColorMath.deltaE2000(a,o)
            if !fit && de>2 { failed += 1 }
            func rgb(_ p: [Double]) -> String { p.map { String(format: "%02X",Int($0.rounded())) }.joined() }
            table += "| (\(x), \(y)) | \(fit ? "fit" : "held out") | #\(rgb(a)) | #\(rgb(o)) | \(String(format: "%.2f",de)) | \(de<=2 ? "PASS" : "FAIL") |\n"
        }
        table += "\nStep 1 chrome only. Section labels, extension tile, row titles and row behavior are Step 2. Developer Mode is masked per Q14. Real-app material/S11-S13 are deferred to Step 3 per plan §12/§11.\n"
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try table.write(to: directory.appendingPathComponent("table.md"),atomically: true,encoding: .utf8)
        // No Arc pixels outside this private directory, including underlying sidebar data.
        ours.write(to: directory.appendingPathComponent("open-private-backdrop.png"))
        var sheet = Bitmap(width: arc.width*2,height: arc.height,fill: 128)
        for y in 0..<arc.height { for x in 0..<arc.width { if body.insetBy(dx: -12,dy: -12).contains(CGPoint(x: x,y: y)) { sheet.set(x,y,arc.pixel(x,y)); sheet.set(arc.width+x,y,ours.pixel(x,y)) } } }
        sheet.write(to: directory.appendingPathComponent("side-by-side.png")); print(table)
        if failed > 0 { throw CLIError(description: "element comparison: \(failed) failed") }
    }
}
