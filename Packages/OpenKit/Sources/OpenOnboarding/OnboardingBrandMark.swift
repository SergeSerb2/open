import AppKit
import QuartzCore

/// Open's own doorway: a full-round crown, ten-point lower corners and a
/// five-point luminous edge at 168 × 248 pt. No asset or reference-app code.
@MainActor
public enum OnboardingBrandMark {
    public struct Components {
        public let doorway: CAShapeLayer
        public let sun: CALayer
        public let light: CAGradientLayer
        public let bloom: CALayer
    }
    public static func path(in rect: CGRect, flipped: Bool = true, bottomCornerRadius: CGFloat? = nil) -> CGPath {
        let w = rect.width, h = rect.height, radius = min(w / 2, h / 2)
        let bottom = min(bottomCornerRadius ?? min(w * 10 / 168, h / 8), w / 2, h / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: h - bottom)); p.addLine(to: CGPoint(x: 0, y: radius))
        // Two cubic quarter-circles make the full-round crown exact.
        let k: CGFloat = 0.5522847498
        p.addCurve(to: CGPoint(x: radius, y: 0), control1: CGPoint(x: 0, y: radius * (1-k)), control2: CGPoint(x: radius * (1-k), y: 0))
        p.addCurve(to: CGPoint(x: w, y: radius), control1: CGPoint(x: w-radius*(1-k), y: 0), control2: CGPoint(x: w, y: radius*(1-k)))
        p.addLine(to: CGPoint(x: w, y: h-bottom))
        p.addQuadCurve(to: CGPoint(x: w-bottom, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: bottom, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h-bottom), control: CGPoint(x: 0, y: h)); p.closeSubpath()
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: flipped ? 1 : -1, tx: rect.minX, ty: flipped ? rect.minY : rect.maxY)
        return p.copy(using: &t)!
    }
    public static func components(in rect: CGRect, flipped: Bool = true) -> Components {
        let scale = min(rect.width/168, rect.height/248), path = path(in: rect, flipped: flipped)
        let edge = CAShapeLayer(); edge.path = path; edge.fillColor = nil
        edge.strokeColor = OnboardingTokens.Room.white.withAlphaComponent(0.96).cgColor
        edge.lineWidth = max(0.8, 5*scale); edge.lineCap = .round; edge.lineJoin = .round
        edge.shadowColor = OnboardingTokens.Room.bloom.cgColor; edge.shadowOpacity = 0.55
        edge.shadowRadius = 30*scale; edge.shadowOffset = .zero
        edge.shadowPath = path.copy(strokingWithWidth: edge.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0)
        let light = CAGradientLayer(); light.frame = rect
        light.colors = [OnboardingTokens.Room.sunTop.cgColor, OnboardingTokens.Room.sunMiddle.cgColor, OnboardingTokens.Room.sunBottom.cgColor]
        light.locations = [0,0.46,1]; light.startPoint = CGPoint(x: 0.5,y: flipped ? 0:1); light.endPoint = CGPoint(x: 0.5,y: flipped ? 1:0)
        let mask = CAShapeLayer(); mask.path = self.path(in: CGRect(origin: .zero,size: rect.size),flipped: flipped); light.mask = mask
        let inside = CAShapeLayer(); inside.path = self.path(in: light.bounds.insetBy(dx: 3.5*scale,dy: 3.5*scale),flipped: flipped)
        inside.fillColor = nil; inside.strokeColor = OnboardingTokens.Room.sunMiddle.cgColor; inside.lineWidth = max(0.5,scale)
        light.addSublayer(inside)
        let reflected = CAGradientLayer(); reflected.frame = light.bounds
        reflected.colors = [OnboardingTokens.Room.sunTop.withAlphaComponent(0).cgColor,OnboardingTokens.Room.sunTop.withAlphaComponent(0).cgColor,OnboardingTokens.Room.sunTop.withAlphaComponent(0.22).cgColor]
        reflected.locations = [0,0.76,1]; reflected.startPoint = CGPoint(x: 0.5,y: flipped ? 0:1); reflected.endPoint = CGPoint(x: 0.5,y: flipped ? 1:0)
        light.addSublayer(reflected)
        let bloom = CAGradientLayer(); bloom.type = .radial
        let radius = rect.width*1.6
        bloom.frame = CGRect(x: rect.midX-radius,y: rect.midY-radius,width: radius*2,height: radius*2)
        bloom.colors = [OnboardingTokens.Room.bloom.withAlphaComponent(0.25).cgColor,OnboardingTokens.Room.bloom.withAlphaComponent(0).cgColor]
        // Radial endPoint sets both ellipse radii. A zero vertical radius
        // renders as a solid rectangle on the M5's native 1x compositor.
        bloom.startPoint = CGPoint(x: 0.5,y: 0.5); bloom.endPoint = CGPoint(x: 1,y: 1)
        let sun = CALayer(); sun.bounds = CGRect(x: 0,y: 0,width: 44*scale,height: 44*scale)
        sun.position = CGPoint(x: rect.maxX-48*scale,y: flipped ? rect.minY+74*scale:rect.maxY-74*scale)
        let halo = CAGradientLayer(); halo.type = .radial
        halo.frame = sun.bounds.insetBy(dx: -88*scale,dy: -88*scale)
        halo.colors = [OnboardingTokens.Room.white.withAlphaComponent(0.4).cgColor,OnboardingTokens.Room.sunTop.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5,y: 0.5); halo.endPoint = CGPoint(x: 1,y: 1)
        let disc = CAGradientLayer(); disc.type = .radial; disc.frame = sun.bounds; disc.cornerRadius = 22*scale
        disc.colors = [OnboardingTokens.Room.white.cgColor,OnboardingTokens.Room.sunTop.cgColor,OnboardingTokens.Room.sunMiddle.cgColor,OnboardingTokens.Room.sunMiddle.withAlphaComponent(0).cgColor]
        disc.locations = [0,0.38,0.70,0.73]; disc.startPoint = CGPoint(x: 0.4,y: 0.38); disc.endPoint = CGPoint(x: 1,y: 1)
        sun.addSublayer(halo); sun.addSublayer(disc)
        return Components(doorway: edge,sun: sun,light: light,bloom: bloom)
    }
    public static func draw(in rect: CGRect,opacity: CGFloat = 1,flipped: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext,rect.width > 0,rect.height > 0 else { return }
        // Draw into the caller's context at its actual backing scale. Rendering
        // a temporary CALayer tree here cached the small emblem at 1x before
        // the card's transform enlarged it, which softened the white edge.
        context.saveGState(); defer { context.restoreGState() }
        context.setAlpha(opacity)
        let scale = min(rect.width/168,rect.height/248)
        let outline = path(in: rect,flipped: flipped)
        let top = CGPoint(x: rect.midX,y: flipped ? rect.minY:rect.maxY)
        let bottom = CGPoint(x: rect.midX,y: flipped ? rect.maxY:rect.minY)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.saveGState(); context.addPath(outline); context.clip()
        if let gradient = CGGradient(colorsSpace: space,colors: [OnboardingTokens.Room.sunTop.cgColor,OnboardingTokens.Room.sunMiddle.cgColor,OnboardingTokens.Room.sunBottom.cgColor] as CFArray,locations: [0,0.46,1]) {
            context.drawLinearGradient(gradient,start: top,end: bottom,options: [])
        }
        let sun = CGPoint(x: rect.maxX-48*scale,y: flipped ? rect.minY+74*scale:rect.maxY-74*scale)
        if let halo = CGGradient(colorsSpace: space,colors: [OnboardingTokens.Room.white.withAlphaComponent(0.4).cgColor,OnboardingTokens.Room.sunTop.withAlphaComponent(0).cgColor] as CFArray,locations: [0,1]) {
            context.drawRadialGradient(halo,startCenter: sun,startRadius: 0,endCenter: sun,endRadius: 55*scale,options: [])
        }
        context.setFillColor(OnboardingTokens.Room.white.cgColor)
        context.fillEllipse(in: CGRect(x: sun.x-16*scale,y: sun.y-16*scale,width: 32*scale,height: 32*scale))
        context.restoreGState()
        context.addPath(path(in: rect.insetBy(dx: 3.5*scale,dy: 3.5*scale),flipped: flipped))
        context.setStrokeColor(OnboardingTokens.Room.sunMiddle.cgColor); context.setLineWidth(max(0.5,scale)); context.strokePath()
        context.addPath(outline); context.setStrokeColor(OnboardingTokens.Room.white.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(max(0.8,5*scale)); context.setLineJoin(.round); context.strokePath()
    }
}
