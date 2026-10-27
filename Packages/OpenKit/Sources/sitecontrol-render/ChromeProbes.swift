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
        check("four 48x32 actions at measured positions",stage.controller.view.panel.controls.prefix(4).enumerated().allSatisfy { i,b in b.frame == CGRect(x: 10+CGFloat(i)*56,y: stage.controller.view.panel.bodyRect.minY+10,width: 48,height: 32) })
        if appearance == .dark {
            let top = pixel(body.minX+13,body.minY+12), bottom = pixel(body.minX+13,body.minY+40)
            check("action gradient top \(top.prefix(3)) ~= #272727",near(top,[39,39,39]))
            check("action gradient bottom \(bottom.prefix(3)) ~= #161616",near(bottom,[22,22,22]))
            check("action outer ring is darker than material",CLI.luminance(pixel(body.minX+34,body.minY+9)) < CLI.luminance(pixel(body.minX+34,body.minY+7)))
            let rim = pixel(body.minX+37,body.minY)
            if body.minX+37 < stage.root.sidebarWidth { check("white 0.20 rim \(rim.prefix(3)) ~= #75738F",near(rim,[117,115,143])) }
        }
        let arrow = stage.controller.view.panel.arrowX != nil
        if arrow {
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
            let core = pixel(center.x+4,center.y),outside = pixel(origin.x+8,center.y)
            let de = ColorMath.deltaE2000(core.prefix(3).map(Double.init),outside.prefix(3).map(Double.init))
            check(String(format: "real Settings gear knock-out equals nearby material DE %.2f",de),de<=3)
            check("297 pt no-Boosts stack",body.height == 297)

        }
        if stage.state == "scc-boost" { check("372 pt one-Boost stack",body.height == 372) }
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
