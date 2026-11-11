import AppKit
import QuartzCore

/// Four composited depth planes. Created only with intro/setup/Welcome.
/// No image decoding, blur filter, display link or repeating timer.
@MainActor
public final class OnboardingRoomLayer: CALayer {
    private let wall = CAGradientLayer()
    private let floor = CAGradientLayer()
    public let haze = CAGradientLayer()
    public let spill = CAGradientLayer()
    private let spillMask = CALayer()
    private var spillKey: [CGFloat] = []
    private let vignette = CAGradientLayer()
    private let grain = CALayer()
    private let grainRows = CAReplicatorLayer()
    private let grainColumns = CAReplicatorLayer()
    private static let noiseTile = noise()
    public init(artwork: Bool) {
        super.init(); backgroundColor = OnboardingTokens.Room.far.cgColor
        wall.type = .radial; wall.locations = [0,0.38,0.78]
        wall.startPoint = CGPoint(x: 0.5,y: 0.46); wall.endPoint = CGPoint(x: 1.7,y: 1.36)
        wall.colors = [OnboardingTokens.Room.lit.cgColor,OnboardingTokens.Room.wall.cgColor,OnboardingTokens.Room.far.cgColor]
        floor.colors = [OnboardingTokens.Room.floor.withAlphaComponent(0).cgColor,OnboardingTokens.Room.floor.withAlphaComponent(0).cgColor,OnboardingTokens.Room.floor.withAlphaComponent(0.55).cgColor,OnboardingTokens.Room.floor.withAlphaComponent(0.85).cgColor]
        floor.locations = [0,0.60,0.64,1]; floor.startPoint = CGPoint(x: 0.5,y: 0); floor.endPoint = CGPoint(x: 0.5,y: 1)
        haze.type = .radial; haze.colors = [OnboardingTokens.Room.bloom.withAlphaComponent(0.22).cgColor,OnboardingTokens.Room.bloom.withAlphaComponent(0).cgColor]
        haze.startPoint = CGPoint(x: 0.5,y: 0.5); haze.endPoint = CGPoint(x: 1,y: 1)
        spill.colors = [OnboardingTokens.Room.spill.withAlphaComponent(0.55).cgColor,OnboardingTokens.Room.sunBottom.withAlphaComponent(0.12).cgColor,OnboardingTokens.Room.sunBottom.withAlphaComponent(0).cgColor]
        spill.locations = [0,0.55,1]; spill.startPoint = CGPoint(x: 0.5,y: 0); spill.endPoint = CGPoint(x: 0.5,y: 1); spill.mask = spillMask
        vignette.type = .radial; vignette.colors = [OnboardingTokens.Room.shadow.withAlphaComponent(0).cgColor,OnboardingTokens.Room.shadow.withAlphaComponent(0).cgColor,OnboardingTokens.Room.shadow.withAlphaComponent(0.45).cgColor]
        vignette.locations = [0,0.55,1]; vignette.startPoint = CGPoint(x: 0.5,y: 0.45); vignette.endPoint = CGPoint(x: 1.4,y: 1.25)
        // 128 × 128 RGBA = 64 KiB. One image is shared by every tile.
        if let noise = Self.noiseTile {
            let tile = CALayer()
            grainRows.instanceTransform = CATransform3DMakeTranslation(0,128,0)
            grainColumns.instanceTransform = CATransform3DMakeTranslation(128,0,0)
            tile.frame = CGRect(x: 0,y: 0,width: 128,height: 128); tile.contents = noise
            grainColumns.addSublayer(tile); grainRows.addSublayer(grainColumns); grain.addSublayer(grainRows)
        }
        grain.masksToBounds = true
        grain.opacity = OnboardingTokens.Room.grainOpacity; grain.compositingFilter = "overlayBlendMode"
        for item in [wall,floor,haze,spill,grain,vignette] { addSublayer(item) }; masksToBounds = true
    }
    public override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
    public func configure(size: CGSize,doorway: CGRect,tint: NSColor? = nil,floor visible: Bool = true,leadingSpill: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero,size: size)
        // Do not composite a fixed 2560-point square for a small content pane.
        // The same tile covers only this room, including a partial last tile.
        grainColumns.instanceCount = max(1,Int(ceil(size.width/128)))
        grainRows.instanceCount = max(1,Int(ceil(size.height/128)))
        for item in [wall,floor,vignette,grain] { item.frame = bounds }; floor.isHidden = !visible
        if visible {
            wall.colors = [(tint ?? OnboardingTokens.Room.lit).cgColor,OnboardingTokens.Room.wall.cgColor,OnboardingTokens.Room.far.cgColor]
        } else {
            wall.startPoint = CGPoint(x: 0.82,y: 0); wall.endPoint = CGPoint(x: 1.52,y: 0.6)
            let light = (tint ?? OnboardingTokens.Room.space).blended(withFraction: 0.3,of: OnboardingTokens.Room.lit) ?? OnboardingTokens.Room.lit
            wall.colors = [light.cgColor,OnboardingTokens.Room.welcomeWall.cgColor,OnboardingTokens.Room.welcomeFar.cgColor]
            wall.locations = [0,0.4,0.8]
        }
        haze.frame = CGRect(x: doorway.midX-size.width*0.42,y: doorway.midY-size.height*0.46,width: size.width*0.84,height: size.height*0.92)
        let length: CGFloat = visible ? (leadingSpill ? 480:380):200
        spill.setAffineTransform(.identity)
        spill.frame = CGRect(x: 0,y: doorway.maxY+2,width: size.width,height: length)
        spillMask.frame = spill.bounds
        let key = [size.width,length,doorway.midX,doorway.width,leadingSpill ? 1:0]
        if key != spillKey {
            spillKey = key
            spillMask.contents = Self.softSpill(width: size.width,height: length,center: doorway.midX,doorWidth: doorway.width,leading: leadingSpill)
        }
        spill.opacity = visible ? 1:0.21 // Welcome peak is <= 0.12 alpha, above the captions.
        CATransaction.commit()
    }
    public func parallax(x: CGFloat,y: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wall.transform = CATransform3DMakeTranslation(x*0.3,y*0.3,0)
        haze.transform = CATransform3DMakeTranslation(x*0.65,y*0.65,0)
        spill.transform = CATransform3DMakeTranslation(x,y,0); CATransaction.commit()
    }
    /// A 256 KiB static alpha field, rebuilt only after geometry changes.
    /// The penumbra widens from 6% to 18%; vertical intensity lives in spill.
    private static func softSpill(width: CGFloat,height: CGFloat,center: CGFloat,doorWidth: CGFloat,leading: Bool) -> CGImage? {
        let side = 256
        var bytes = [UInt8](repeating: 0,count: side*side*4)
        for y in 0..<side {
            let t = CGFloat(y)/CGFloat(side-1)
            let spread = doorWidth*(1+4.6*t), half = spread/2
            let feather = spread*(0.06+0.12*t)
            let mid = center-(leading ? width*0.48*t:0)
            for x in 0..<side {
                let distance = abs(CGFloat(x)/CGFloat(side-1)*width-mid)
                let u = max(0,min(1,(half+feather-distance)/(2*feather)))
                let a = UInt8((u*u*(3-2*u)*255).rounded())
                let i = (y*side+x)*4
                bytes[i] = a; bytes[i+1] = a; bytes[i+2] = a; bytes[i+3] = a
            }
        }
        return CGDataProvider(data: Data(bytes) as CFData).flatMap {
            CGImage(width: side,height: side,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: side*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: $0,decode: nil,shouldInterpolate: true,intent: .defaultIntent)
        }
    }
    private static func noise() -> CGImage? {
        var bytes = [UInt8](repeating: 0,count: 128*128*4)
        for i in 0..<(128*128) {
            var h = UInt32(i) &* 0x9E3779B9; h ^= h >> 13; h = h &* 0x5BD1E995; h ^= h >> 15
            let v = UInt8(truncatingIfNeeded: h)
            let alpha = UInt8(90+Int(v)/3)
            bytes[i*4] = alpha; bytes[i*4+1] = alpha; bytes[i*4+2] = alpha; bytes[i*4+3] = alpha
        }
        return CGDataProvider(data: Data(bytes) as CFData).flatMap {
            CGImage(width: 128,height: 128,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 512,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: $0,decode: nil,shouldInterpolate: false,intent: .defaultIntent)
        }
    }
}

@MainActor
public final class OnboardingRoomView: NSView {
    public override var isFlipped: Bool { true }
    public let room = OnboardingRoomLayer(artwork: true)
    private let doorway = CALayer()
    private var doorwayRect = CGRect.null
    public var tint: NSColor? { didSet { needsLayout = true } }
    public var isWelcome = false { didSet { needsLayout = true } }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(room); layer?.addSublayer(doorway); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        room.frame = bounds
        let rect = isWelcome ? CGRect(x: bounds.width*0.88-32,y: 44,width: 64,height: 94):CGRect(x: bounds.width*0.80-51,y: bounds.height*0.22-75,width: 102,height: 150)
        room.configure(size: bounds.size,doorway: rect,tint: tint,floor: !isWelcome,leadingSpill: true)
        doorway.frame = bounds
        if doorwayRect != rect {
            doorwayRect = rect; doorway.sublayers?.forEach { $0.removeFromSuperlayer() }
            let mark = OnboardingBrandMark.components(in: rect)
            for item in [mark.bloom,mark.light,mark.doorway,mark.sun] { doorway.addSublayer(item) }
        }
        CATransaction.commit()
    }
}
