import AppKit
import QuartzCore

/// Shared system-popover choice. The on-engine material calibration is Step 3.
public enum PopoverMaterial {
    public static let material: NSVisualEffectView.Material = .hudWindow
    public static let blending: NSVisualEffectView.BlendingMode = .withinWindow
    public static let shadowOpacity = SiteControlMetrics.shadowOpacity
    public static let shadowRadius = SiteControlMetrics.shadowRadius
    public static let shadowOffsetY = SiteControlMetrics.shadowOffsetY
}

/// Own continuous corners and rounded 90-degree popover arrow. No asset pixels.
public enum PopoverShape {
    public static func path(body rect: CGRect, arrowTip: CGPoint?, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width/2.56, rect.height/2.56), extent = 1.28*r
        let path = CGMutablePath()
        let centers = [CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.minY)]
        let controls = [CGPoint(x: -extent,y: 0),CGPoint(x: -0.75*r,y: 0),CGPoint(x: -0.436*r,y: 0),CGPoint(x: 0,y: 0.436*r),CGPoint(x: 0,y: 0.75*r),CGPoint(x: 0,y: extent)]
        let coefficients: [CGFloat] = [1,5,10,10,5,1]
        for (corner,center) in centers.enumerated() {
            for step in 0...40 {
                let t = CGFloat(step)/40
                var p = CGPoint.zero
                for i in 0...5 { let w = coefficients[i]*pow(1-t,CGFloat(5-i))*pow(t,CGFloat(i)); p.x += controls[i].x*w; p.y += controls[i].y*w }
                let angle = CGFloat(corner) * .pi/2
                let point = CGPoint(x: center.x+p.x*cos(angle)-p.y*sin(angle),y: center.y+p.x*sin(angle)+p.y*cos(angle))
                if corner == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        if let tip = arrowTip {
            let cap = SiteControlMetrics.arrowTipRadius, fillet = SiteControlMetrics.arrowBaseFillet
            let root = rect.minY-tip.y + cap*(sqrt(2)-1)
            let d = fillet*tan(.pi/8), diagonal = d/sqrt(2)
            let left = tip.x-root, right = tip.x+root
            path.addLine(to: CGPoint(x: left-d,y: rect.minY))
            path.addArc(center: CGPoint(x: left-d,y: rect.minY-fillet),radius: fillet,startAngle: .pi/2,endAngle: .pi/4,clockwise: true)
            path.addLine(to: CGPoint(x: tip.x-cap/sqrt(2),y: tip.y+cap-cap/sqrt(2)))
            path.addArc(center: CGPoint(x: tip.x,y: tip.y+cap),radius: cap,startAngle: .pi*1.25,endAngle: .pi*1.75,clockwise: false)
            path.addLine(to: CGPoint(x: right-diagonal,y: rect.minY-diagonal))
            path.addArc(center: CGPoint(x: right+d,y: rect.minY-fillet),radius: fillet,startAngle: .pi*0.75,endAngle: .pi/2,clockwise: true)
        }
        path.closeSubpath(); return path
    }
}

public enum SiteControlShape {
    public static func path(in rect: CGRect, radius: CGFloat) -> CGPath { PopoverShape.path(body: rect,arrowTip: nil,radius: radius) }
}
