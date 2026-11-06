import AppKit
import OpenDesign
import OpenSiteControl

/// Capture pixels and comparison sheets remain in the private .re directory.
@MainActor
enum EditorCompare {
    enum Kind { case text,ink,blue,arrow,fill(CGRect),box(CGRect) }
    struct Element { let name: String,rect: CGRect,kind: Kind }
    static func run(_ args: [String]) throws {
        guard let path = CLI.value(args,"--arc"),let out = CLI.value(args,"--out") else { throw CLIError(description: "editor compare requires --arc --out (.re only)") }
        let directory = URL(fileURLWithPath: out).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.pathComponents.contains(".re") else { throw CLIError(description: "private comparisons must stay in .re") }
        let state = CLI.value(args,"--state") ?? "editor-no-color",stage = EditorStage(state: state)
        var arc = try Bitmap(path: path)
        let advanced = state == "editor-advanced"
        let image = advanced ? OffscreenRenderer().snapshot(stage.view.advancedPopover!.panel.contentView!,scale: 1) : stage.editorImage(),ours = Bitmap(image: image)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!,arcP3 = try Bitmap(path: path,space: p3),openP3 = Bitmap(image: image,space: p3)
        // The native popover capture includes the editor and child in one 250x588
        // backing image, despite the child's 250x232 window frame in windows.tsv.
        if advanced && arc.width == 250 && arc.height == 588 {
            var child = Bitmap(width: 250,height: 232,fill: 255)
            for y in 0..<232 { for x in 0..<250 { child.set(x,y,arc.pixel(x,y+258)) } };arc = child
        }
        guard advanced ? (arc.width == 250 && arc.height == 232) : (arc.width == (state == "editor-code-css" ? 480 : 183) && arc.height == 588) else { throw CLIError(description: "editor capture dimensions do not match the complete native window") }
        var elements: [Element] = []
        func text(_ name: String,_ r: CGRect) { elements.append(.init(name: name,rect: r,kind: .text)) }
        func ink(_ name: String,_ r: CGRect) { elements.append(.init(name: name,rect: r,kind: .ink)) }
        func fill(_ name: String,_ r: CGRect) { elements.append(.init(name: name,rect: r,kind: .fill(r))) }
        func box(_ name: String,_ r: CGRect,_ sample: CGRect) { elements.append(.init(name: name,rect: r,kind: .box(sample))) }
        if state == "editor-code-css" {
            fill("code header",CGRect(x:4,y:30,width:5,height:5))
            ink("Back arrow",CGRect(x:11,y:12,width:18,height:17));text("Back label",CGRect(x:33,y:9,width:39,height:23))
            text("CSS segment label",CGRect(x:199,y:9,width:34,height:23));text("JS segment label",CGRect(x:252,y:9,width:27,height:23))
            fill("CSS selected segment",CGRect(x:198,y:12,width:4,height:3));fill("JS idle segment",CGRect(x:277,y:12,width:4,height:3))
            fill("code bottom bar",CGRect(x:110,y:540,width:5,height:5))
            for (i,title) in ["Pick Selector","Developer Tools"].enumerated() {
                let x = 15+i*48
                fill(title+" button",CGRect(x:x+4,y:540,width:3,height:3))
            }
            // Pick Selector remains disabled until Step 8, so its glyph differs by design.
            ink("Developer Tools glyph",CGRect(x:70,y:542,width:24,height:24))
        } else if advanced {
            for y in 2..<13 { elements.append(.init(name: "advanced arrow row \(y)",rect: CGRect(x: 104,y: y,width: 43,height: 1),kind: .arrow)) }
            for (i,title) in ["Contrast","Brightness","Original Saturation"].enumerated() {
                text(title,CGRect(x: 30,y: 39+i*62,width: 190,height: 23))
                fill(title+" track filled",CGRect(x: 50,y: 66+i*62,width: 12,height: 2))
                fill(title+" track unfilled",CGRect(x: 195,y: 66+i*62,width: 12,height: 2))
                box(title+" knob",CGRect(x: 112,y: 57+i*62,width: 26,height: 22),CGRect(x: 122,y: 64+i*62,width: 4,height: 3))
            }
            fill("advanced material over editor",CGRect(x: 125,y: 42,width: 1,height: 1))
            fill("advanced material over button",CGRect(x: 60,y: 212,width: 1,height: 1))
        } else if state == "editor-font-selected" {
            box("selected Charter circle",CGRect(x: 132,y: 305,width: 30,height: 30),CGRect(x: 145,y: 328,width: 3,height: 2))
            text("selected Charter ink",CGRect(x: 134,y: 307,width: 26,height: 22))
        } else if state == "editor-dragging" {
            let center = stage.view.pad.primaryKnobCenter!,p = CGPoint(x: center.x+18,y: center.y+58),r = hypot(center.x-73.5,center.y-73.5)
            ink("dragging primary disc",CGRect(x: p.x-20,y: p.y-20,width: 40,height: 40))
            for degrees in [0,45,90,135,180,225] { let a = Double(degrees) * .pi/180;fill("guide circle \(degrees) degrees",CGRect(x: floor(91.5+cos(a)*r),y: floor(131.5+sin(a)*r),width: 1,height: 1)) }
        } else if state == "editor-first-run" {
            fill("top dim",CGRect(x: 5,y: 100,width: 6,height: 10));fill("card",CGRect(x: 5,y: 400,width: 5,height: 10))
            elements.append(.init(name: "own badge saturated-blue ink box",rect: CGRect(x: 40,y: 230,width: 105,height: 94),kind: .blue))
            for (i,y) in [347,370,393].enumerated() { text("title line \(i+1)",CGRect(x: 8,y: y-22,width: 167,height: 24)) }
            // The host line contains personal data; only its fixed companion line
            // is compared in the public synthetic fixture. The capture stays private.
            text("body your own",CGRect(x: 20,y: 428,width: 143,height: 17))
            for x in [7,24,41,58,75,92,109,126,143,160] { fill("wave crest x\(x)",CGRect(x: x,y: 464,width: 1,height: 1)) }
            text("Make a Boost",CGRect(x: 20,y: 500,width: 143,height: 24));text("Maybe Later",CGRect(x: 43,y: 545,width: 97,height: 22))
            for (name,y) in [("top",495),("middle",502),("bottom",528)] { fill("Make button gradient "+name,CGRect(x: 20,y: y,width: 4,height: 1)) }
        } else {
            fill("header",CGRect(x: 4,y: 30,width: 5,height: 5));fill("body",CGRect(x: 4,y: 210,width: 5,height: 5))
            ink("Done",CGRect(x: 8,y: 9,width: 24,height: 24));text("Boost name",CGRect(x: 45,y: 8,width: 66,height: 24));ink("Name chevron",CGRect(x: 115,y: 12,width: 20,height: 16));ink("Undo",CGRect(x: 151,y: 9,width: 24,height: 24))
            let pad = stage.view.pad
            let centers = [pad.primaryKnobCenter!]+pad.secondaryKnobFrames.map { CGPoint(x: $0.midX,y: $0.midY) }
            for (i,p) in centers.enumerated() {
                let center = CGPoint(x: p.x+18,y: p.y+58),radius: CGFloat = i == 0 ? 18 : 14
                ink("knob \(i+1) disc",CGRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2))
                for (name,dy) in [("top",i == 0 ? -12 : -7),("center",0),("bottom",i == 0 ? 12 : 7)] { fill("knob \(i+1) gradient "+name,CGRect(x: center.x,y: center.y+CGFloat(dy),width: 1,height: 1)) }
            }
            for i in 0..<12 {
                let a = Double(i)*30 * .pi/180
                // Midline of the square ring, not a circular radius.
                let k = 70/max(abs(cos(a)),abs(sin(a))),x = 91.5+cos(a)*k,y = 131.5+sin(a)*k
                fill("ring angle \(i*30)",CGRect(x: floor(x),y: floor(y),width: 1,height: 1))
            }
            for (i,x) in [18,70,123].enumerated() {
                let b = CGRect(x: x,y: 220,width: i == 1 ? 43 : 42,height: 38)
                box("color button \(i+1)",b.insetBy(dx: -2,dy: -2),CGRect(x: x+4,y: 237,width: 2,height: 2))
                ink("color glyph \(i+1)",b.insetBy(dx: 12,dy: 7))
            }
            for (i,f) in BoostEditorFonts.available.enumerated() where f.enabled {
                text("font cell \(i+1)",CGRect(x: BoostEditorMetrics.fontColumns[i%5],y: BoostEditorMetrics.fontRows[i/5],width: 26,height: 26))
            }
            for (title,b) in [("Size",BoostEditorMetrics.size),("Case",BoostEditorMetrics.textCase),("Zap",BoostEditorMetrics.zap),("Code",BoostEditorMetrics.code)] {
                box(title+" button",b.insetBy(dx: -2,dy: -2),CGRect(x: b.minX+4,y: b.midY,width: 2,height: 2))
                text(title+" label",CGRect(x: b.minX+(title == "Size" || title == "Case" ? 3 : 10),y: b.minY+8,width: title == "Size" || title == "Case" ? b.width-6 : 50,height: 23))
                // The captured Zap/Code controls were available. Their disabled
                // glyph color is intentionally different before P7/Step 7.
            }
        }
        var table = "| Element | Capture ink box | Open ink box | Max edge error (pt) | DE00 | Result |\n|---|---|---|---|---|---|\n",failed = 0
        func description(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "—" }
        for e in elements {
            let a: CGRect?,o: CGRect?,ac: [Double]?,oc: [Double]?,position: Bool,color: Bool
            switch e.kind {
            case .blue:
                func blue(_ bitmap: Bitmap) -> CGRect? { var box: CGRect?;let (x0,y0,x1,y1) = bitmap.clamp(e.rect);for y in y0..<y1 { for x in x0..<x1 { let p = bitmap.pixel(x,y);if p[2]>160 && p[2]-max(p[0],p[1])>80 { box = (box ?? CGRect(x: x,y: y,width: 0,height: 0)).union(CGRect(x: x,y: y,width: 1,height: 1)) } } };return box }
                a = blue(arcP3);o = blue(openP3);ac = nil;oc = nil;position = true;color = false
            case .arrow: (a,ac) = arc.arrowInk(e.rect);(o,oc) = ours.arrowInk(e.rect);position = true;color = true
            case .text: (a,ac) = arc.ink(e.rect);(o,oc) = ours.ink(e.rect);position = true;color = false
            case .ink: (a,ac) = arc.ink(e.rect);(o,oc) = ours.ink(e.rect);position = true;color = true
            case .fill(let r):a = nil;o = nil;ac = arc.mean(r);oc = ours.mean(r);position = false;color = true
            case .box(let r):a = arc.inkBox(e.rect,contrastFrom: r);o = ours.inkBox(e.rect,contrastFrom: r);ac = arc.mean(r);oc = ours.mean(r);position = true;color = true
            }
            let error = a.flatMap { a in o.map { b in [abs(a.minX-b.minX),abs(a.minY-b.minY),abs(a.maxX-b.maxX),abs(a.maxY-b.maxY)].max()! } },de = ac.flatMap { a in oc.map { ColorMath.deltaE2000(a,$0) } }
            let pass = (!position || (error ?? .infinity)<=1) && (!color || (de ?? .infinity)<=2)
            if !pass { failed += 1 }
            table += "| \(e.name) | \(description(a)) | \(description(o)) | \(error.map { String(format: "%.2f",$0) } ?? "—") | \(de.map { String(format: "%.2f",$0) } ?? "—") | \(pass ? "PASS" : "FAIL") |\n"
        }
        table += "\n\(elements.count-failed)/\(elements.count) passed. Text uses ink boxes; every non-text core/fill uses DE00 <= 2. Personal host-line text, unavailable Zap/Code glyph colors, and system menu/alert styling are excluded explicitly. S11–S13 and real-app snapshots are deferred to Step 3 per plan §12/§11.\n"
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try table.write(to: directory.appendingPathComponent("table.md"),atomically: true,encoding: .utf8)
        ours.write(to: directory.appendingPathComponent("open.png"));print(table)
        if failed>0 { throw CLIError(description: "editor comparison: \(failed) failed") }
    }
}
