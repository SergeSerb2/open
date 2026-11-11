import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
enum ChromeProbes {
    static func run(_ stage: Stage,appearance: ContentAppearance) -> [Flows.Check] {
        let image = stage.render(scale: stage.scale), body = stage.controller.view.panelFrame, tip = stage.controller.view.visibleArrowTip, scale = stage.scale
        let prefix = "\(stage.state) \(appearance.rawValue) \(Int(scale))x"
        func pixel(_ x: CGFloat,_ y: CGFloat) -> [UInt8] { CLI.pixel(image,x: Int(x*scale),y: Int(y*scale)) }
        func near(_ p: [UInt8],_ rgb: [Int],tolerance: Int = 3) -> Bool { zip(p.prefix(3),rgb).allSatisfy { abs(Int($0)-$1)<=tolerance } }
        var result: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { result.append(.init(name: prefix+" "+name,pass: pass)) }
        check("236 pt body; height fits content and window",body.width == 236 && body.height == min(stage.controller.view.panel.preferredHeight,640,stage.root.bounds.height-8-body.minY))
        check("complete opaque capture",CLI.fullyOpaque(image))
        // D3 §2.5: four equal tiles 47.75 × 32, 7 apart, inside 12 pt padding.
        let m = SiteControlMetrics.self
        check("four 47.75x32 tiles, gap 7, padding 12",stage.controller.view.panel.controls.prefix(4).enumerated().allSatisfy { i,b in
            b.frame == CGRect(x: m.padding+CGFloat(i)*(m.actionButton.width+m.actionGap),y: stage.controller.view.panel.bodyRect.minY+m.padding,width: m.actionButton.width,height: m.actionButton.height) })
        // Tile fill beside the glyph: Light white, Dark #4A4A47.
        let tile = pixel(body.minX+m.padding+4,body.minY+m.padding+16)
        check("tile fill \(tile.prefix(3)) ~= \(appearance == .dark ? "#4A4A47" : "white")",near(tile,appearance == .dark ? [74,74,71] : [255,255,255]))
        // Footer hairline: grey 25 % over the body, 10 pt above the 30 pt footer.
        for offset: CGFloat in [37,180] {
            let x = body.minX+offset,y = body.maxY-m.padding-m.footerHeight-m.gapAfterSeparator-0.5
            let line = pixel(x,y),above = pixel(x,y-2)
            let expected = above.prefix(3).map { Int((Double($0)*0.75+128*0.25).rounded()) }
            check("separator grey 25 % \(line.prefix(3)) ~= \(expected)",zip(line.prefix(3),expected).allSatisfy { abs(Int($0)-$1)<=4 })
        }
        // 0.5 pt black 20 % hairline: the top edge is darker than the body 3 pt inside.
        let rim = pixel(body.minX+37,body.minY), inside = pixel(body.minX+37,body.minY+3)
        if body.minX+37 < stage.root.sidebarWidth { check("hairline darker than the body \(rim.prefix(3)) < \(inside.prefix(3))",CLI.luminance(rim) < CLI.luminance(inside)) }
        let arrow = stage.controller.view.panel.arrowX != nil
        // The arrow's antialiased width is read against the hairline; the dark hairline over a dark
        // body has too little contrast at tip+1 for this probe, so it runs in Light only.
        if arrow && appearance == .light {
            let expected: [(CGFloat,CGFloat)] = [(1,9),(3,12.3),(5,16.3),(7,20.3)]
            for (y,width) in expected {
                let measured = arrowWidth(image,tip: tip,offset: y,scale: scale)
                check(String(format: "rendered arrow tip+%.0f width %.2f ~= %.1f",y,measured,width),abs(measured-width)<=1)
            }
        }
        if stage.state == "scc-no-boosts" && appearance == .dark {
            let p1 = pixel(88,215),p2 = pixel(300,140)
            let d1 = ColorMath.deltaE2000(p1.prefix(3).map(Double.init),[64,62,84]),d2 = ColorMath.deltaE2000(p2.prefix(3).map(Double.init),[123,123,123])
            check(String(format: "fallback formula regression only P1/P2 DE %.2f / %.2f",d1,d2),d1<=2 && d2<=2)
            let row = stage.controller.view.panel.control(id: "content.automaticPictureInPicture")!
            let origin = row.convert(row.bounds,to: stage.root).origin
            let center = CGPoint(x: origin.x+26,y: origin.y+16)
            // Pick the opaque core of the cut-out, not an antialiased tooth.
            // The calibrated glyph's core moves within this fixed 16 pt box.
            var core = pixel(center.x,center.y)
            for y in 0..<Int(16*scale) { for x in 0..<Int(16*scale) {
                let sample = pixel(center.x-8+CGFloat(x)/scale,center.y-8+CGFloat(y)/scale)
                if CLI.luminance(sample)<CLI.luminance(core) { core = sample }
            } }
            let outside = pixel(origin.x+8,center.y)
            let de = ColorMath.deltaE2000(core.prefix(3).map(Double.init),outside.prefix(3).map(Double.init))
            check(String(format: "real Settings gear knock-out equals nearby material DE %.2f",de),de<=3)
            // Arc 14c measured 254 pt for one setting row (D3 §2.5); each further row adds the 41 pt pitch.
            let rows = CGFloat(max(1,stage.controller.view.panel.snapshot?.tiles.count ?? 1))
            check("254 pt no-Boosts stack for one setting, +41 per row (\(body.height))",body.height == 254+(rows-1)*m.rowPitch)

        }
        if stage.state == "scc-boost" {
            let rows = CGFloat(max(1,stage.controller.view.panel.snapshot?.tiles.count ?? 1))
            let expected = 254+(rows-1)*SiteControlMetrics.rowPitch+SiteControlMetrics.sectionGap+SiteControlMetrics.rowIcon
            check("one-Boost stack adds a section and a row (\(body.height) vs \(expected))",min(body.height,stage.root.bounds.height-8-body.minY) == min(expected,640,stage.root.bounds.height-8-body.minY))
        }
        return result
    }
    static func arrowWidth(_ image: CGImage,tip: CGPoint,offset: CGFloat,scale: CGFloat) -> CGFloat {
        let y = Int((tip.y+offset)*scale), x0 = Int((tip.x-18)*scale), x1 = Int((tip.x+18)*scale)
        let left = CLI.pixel(image,x: x0,y: y),right = CLI.pixel(image,x: x1,y: y)
        var values: [(Int,Double)] = []
        for x in x0..<x1 {
            let p = CLI.pixel(image,x: x,y: y), t = Double(x-x0)/Double(x1-x0)
            let difference = (0..<3).map { abs(Double(p[$0])-Double(left[$0])*(1-t)-Double(right[$0])*t) }.max()!
            values.append((x,difference))
        }
        let peak = values.map(\.1).max() ?? 0, ink = values.filter { $0.1 > max(3,peak*0.5) }.map(\.0)
        guard let lo = ink.min(),let hi = ink.max() else { return 0 }; return CGFloat(hi-lo+1)/scale
    }
}
