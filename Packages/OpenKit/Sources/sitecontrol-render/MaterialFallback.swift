import AppKit
import CoreImage
import OpenDesign

/// Renderer-only approximation. It is never a production material implementation.
@MainActor
enum MaterialFallback {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(),.outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    static func image(_ backdrop: CGImage,scale: CGFloat,appearance: ContentAppearance) -> CGImage {
        let input = CIImage(cgImage: backdrop), extent = input.extent
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: SiteControlColors.fallbackBlurSigma*scale]).cropped(to: extent)
        let weights = appearance == .dark ? SiteControlColors.fallbackBackdropWeight : [0.2,0.2,0.2]
        let tint = appearance == .dark ? SiteControlColors.fallbackTint : RGBA(hex: 0xFFFFFF)
        let image = blurred.applyingFilter("CIColorMatrix",parameters: [
            "inputRVector": CIVector(x: weights[0],y: 0,z: 0,w: 0),
            "inputGVector": CIVector(x: 0,y: weights[1],z: 0,w: 0),
            "inputBVector": CIVector(x: 0,y: 0,z: weights[2],w: 0),
            "inputAVector": CIVector(x: 0,y: 0,z: 0,w: 1),
            "inputBiasVector": CIVector(x: CGFloat(tint.red)*(1-weights[0]),y: CGFloat(tint.green)*(1-weights[1]),z: CGFloat(tint.blue)*(1-weights[2]),w: 0)
        ])
        return context.createCGImage(image,from: extent)!
    }
    // Fitted offscreen constants, S2 09/0010, 2026-10-26. The live effect view
    // never reads them. The first physical pixel has a separate chromatic glow.
    static let glowExtent: CGFloat = 12
    static var glowInner: [CGFloat] = [25,26,24]
    static var glowRim: [CGFloat] = [17,16,31]

    static var phases: [String: CGPoint] = [:]
    static func configure(_ args: [String]) throws {
        func values(_ flag: String) throws -> [CGFloat]? {
            guard let value = CLI.value(args,flag) else { return nil }
            let numbers = value.split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 3,numbers.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { throw CLIError(description: flag+" requires three RGB levels") }
            return numbers.map { CGFloat($0) }
        }
        if let values = try values("--glow-rim") { glowRim = values }
        if let values = try values("--glow-inner") { glowInner = values }
        for id in ["share","newBoost","capture","captureFull","more","gear"] {
            if let raw = CLI.value(args,"--phase-"+id) {
                let xy = raw.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2,xy.allSatisfy({ $0.isFinite && abs($0)<=1 }) else { throw CLIError(description: "phase requires x,y within one point") }
                phases[id] = CGPoint(x: xy[0],y: xy[1])
            }
        }
    }

    static func surface(_ interior: CGImage,panelFrame: CGRect,body: CGRect,shape: CGPath,scale: CGFloat,appearance: ContentAppearance) -> CGImage {
        let crop = CGRect(x: panelFrame.minX*scale,y: panelFrame.minY*scale,width: panelFrame.width*scale,height: panelFrame.height*scale)
        let base = interior.cropping(to: crop)!
        guard appearance == .dark else { return base }
        let c = CGContext(data: nil,width: base.width,height: base.height,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0,y: CGFloat(base.height)); c.scaleBy(x: scale,y: -scale)
        c.setFillColor(NSColor.black.cgColor); c.fill(CGRect(origin: .zero,size: panelFrame.size))
        let arrowHeight = body.minY
        for row in 0..<base.height {
            let y = (CGFloat(row)+0.5)/scale
            var levels: [CGFloat] = [0,0,0]
            if y>=body.minY {
                let top = y-body.minY,bottom = body.maxY-y
                if top<glowExtent { levels = glowInner.map { $0*(1-top/glowExtent) } }
                if top<1/scale { levels = glowRim }
                if bottom<1/scale { levels = [13,11,24] }
            }
            c.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: levels.map { $0/255 }+[1])!)
            c.fill(CGRect(x: 0,y: CGFloat(row)/scale,width: panelFrame.width,height: 1/scale))
        }
        if arrowHeight>0 {
            let near: [(CGFloat,[CGFloat])] = [(0.5,[5,2,7]),(1.5,[12,12,13]),(2.5,[25,25,19]),(8.5,[29,29,23]),(9.5,[22,21,17])]
            let flat: [(CGFloat,[CGFloat])] = [(0.5,[0,0,0]),(1.5,[20,20,21]),(3.5,[17,17,16]),(9.5,[14,16,14])]
            func at(_ y: CGFloat,_ knots: [(CGFloat,[CGFloat])]) -> [CGFloat] {
                if y<=knots[0].0 { return knots[0].1 }
                for i in 1..<knots.count where y<=knots[i].0 {
                    let t = (y-knots[i-1].0)/(knots[i].0-knots[i-1].0)
                    return zip(knots[i-1].1,knots[i].1).map { pair in pair.0*(1-t)+pair.1*t }
                }
                return knots.last!.1
            }
            for row in 0..<Int(arrowHeight*scale) {
                let y = (CGFloat(row)+0.5)/scale
                c.saveGState(); c.clip(to: CGRect(x: 0,y: CGFloat(row)/scale,width: panelFrame.width,height: 1/scale))
                c.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: at(y,flat).map { $0/255 }+[1])!); c.fill(CGRect(origin: .zero,size: panelFrame.size))
                c.setStrokeColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: at(y,near).map { $0/255 }+[1])!)
                c.setLineWidth(2/scale); c.addPath(shape); c.strokePath(); c.restoreGState()
            }
        }
        let baseImage = CIImage(cgImage: base)
        let strength = baseImage.applyingFilter("CIColorMatrix",parameters: ["inputRVector": CIVector(x: -1/60.0,y: 0,z: 0,w: 0),"inputGVector": CIVector(x: -1/60.0,y: 0,z: 0,w: 0),"inputBVector": CIVector(x: -1/60.0,y: 0,z: 0,w: 0),"inputBiasVector": CIVector(x: 123/60.0,y: 123/60.0,z: 123/60.0,w: 0)]).applyingFilter("CIColorClamp")
        var addition = CIImage(cgImage: c.makeImage()!).applyingFilter("CIMultiplyCompositing",parameters: [kCIInputBackgroundImageKey: strength])
        // Fitted top-edge light bleed, from bare material at (215,99) and
        // (229,99), outside the action rings. Interior sigma remains 5.
        let basePixels = Bitmap(image: base)
        var bleed = Bitmap(width: base.width,height: base.height,fill: 0)
        for row in Int(body.minY*scale)..<min(base.height,Int((body.minY+52)*scale)) {
            let d = (CGFloat(row)+0.5)/scale-body.minY,weight = min(1,max(0,(52-d)/10))*0.6
            for x in 0..<base.width {
                let pixel = basePixels.pixel(x,row),right = basePixels.pixel(min(base.width-1,x+Int(16*scale)),row)
                bleed.set(x,row,zip(pixel,right).map { pair in max(0,pair.1-pair.0)*Double(weight) })
            }
        }
        addition = addition.applyingFilter("CIAdditionCompositing",parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: bleed.cgImage())])
        let darkTail = CIVector(x: 2,y: 2,z: 3),pageTail = CIVector(x: 3,y: 7,z: 9)
        var tailPixels = Bitmap(width: base.width,height: base.height,fill: 0)
        // The page-side tail differs spectrally; fit columns 115 and 285, never
        // the held-out rim points at x140/160/180. Only the bottom 32 pt use it.
        for row in max(0,base.height-Int(32*scale))..<base.height {
            let d = (CGFloat(base.height-row)-0.5)/scale
            for x in 0..<base.width {
                let weight = min(1,max(0,(CGFloat(basePixels.pixel(x,row)[0])-63)/60))
                let tail = (0..<3).map { channel in
                    let floor = darkTail.value(at: channel)*(1-weight)+pageTail.value(at: channel)*weight
                    return Double(20*exp(-d/2)+floor*max(0,1-d/40))
                }
                let color = d<1/scale ? [13.0,11,24] : tail
                tailPixels.set(x,row,color)
            }
        }
        addition = CIImage(cgImage: tailPixels.cgImage()).composited(over: addition)
        let result = baseImage.applyingFilter("CIAdditionCompositing",parameters: [kCIInputBackgroundImageKey: addition])
        return context.createCGImage(result,from: result.extent)!
    }

}
