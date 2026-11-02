// Offscreen rendering and bitmap tools. Same method as sidebar-render (docs/design.md §6–§7);
// copied rather than shared because sidebar-render is an executable target owned by M2.
// A later change can move both into one dev-only library.
import AppKit
import Metal
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

/// Renders an NSView tree offscreen, without a window, through Core Animation's
/// own renderer (`CARenderer` into a Metal texture). Unlike `cacheDisplay` or
/// `CALayer.render(in:)`, this path supports masks, shadows, replicators, and
/// layer contents exactly like the window server does.
@MainActor
final class OffscreenRenderer {
    let device: MTLDevice

    init() {
        guard let d = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        device = d
    }

    /// Lays out, displays, and renders `view` at `scale`. Returns sRGB RGBA8 pixels.
    ///
    /// The view goes into a borderless window that is never ordered on screen, so
    /// AppKit builds and draws the layer tree normally. The window reports the
    /// requested backing scale, so 2x renders work on a 1x display.
    func render(_ view: NSView, scale: CGFloat) -> CGImage {
        let window = Self.host(view, scale: scale)
        let image = snapshot(view, scale: scale)
        window.contentView = nil
        window.close()
        return image
    }

    /// Puts `view` in an offscreen window at `scale` and lays it out.
    static func host(_ view: NSView, scale: CGFloat) -> ScaledWindow {
        let size = view.bounds.size
        let window = ScaledWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.scale = scale
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        settle(view)
        return window
    }

    /// Layout and display passes until nothing is dirty (observation hops included).
    static func settle(_ view: NSView, runLoop: TimeInterval = 0) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            if runLoop > 0 { RunLoop.main.run(until: Date().addingTimeInterval(runLoop)) }
        }
        CATransaction.flush()
    }

    /// Renders a view that is already in a window. With `presentation`, layers use
    /// their in-flight animation values (to capture a frame of a transition).
    func snapshot(_ view: NSView, scale: CGFloat, presentation: Bool = false) -> CGImage {
        let size = view.bounds.size
        guard let rootLayer = view.layer else { fatalError("view is not layer-backed") }
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        let texture = device.makeTexture(descriptor: desc)!
        // CARenderer and the read-back fence must share a queue (as in sidebar-render). A fence on an
        // unrelated queue can finish before rendering does and return unwritten pixels: the 2x "black
        // band" (Section 2 item 13; 1 of 60 renders on main, the lower part of the texture never written).
        let queue = device.makeCommandQueue()!
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue as String: queue
        ])
        // The window's context owns the live layers, so render a plain deep copy.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let host = CALayer()
        host.bounds = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        host.anchorPoint = .zero
        host.position = .zero
        host.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        let copy = LayerCloner.clone(rootLayer, presentation: presentation)
        copy.anchorPoint = .zero
        copy.position = .zero
        host.addSublayer(copy)
        CATransaction.commit()
        CATransaction.flush()
        renderer.layer = host
        renderer.bounds = host.bounds
        CATransaction.flush() // the renderer reads committed state; assigning `layer` is transactional
        for _ in 0..<2 {
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
        }
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.synchronize(resource: texture)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        // BGRA → RGBA, and flip rows: CARenderer draws with Core Animation's
        // y-up convention, so texture row 0 is the bottom of the layer tree.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = (h - 1 - y) * w * 4, dst = y * w * 4
            for x in stride(from: 0, to: w * 4, by: 4) {
                rgba[dst + x] = bgra[src + x + 2]; rgba[dst + x + 1] = bgra[src + x + 1]
                rgba[dst + x + 2] = bgra[src + x]; rgba[dst + x + 3] = bgra[src + x + 3]
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// A window that reports a chosen backing scale, so AppKit rasterizes at 2x on a 1x display.
final class ScaledWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
    /// The bar runs in the key window of the app; text selection colors depend on it.
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Copies a layer tree into plain Core Animation layers with the same look.
@MainActor
enum LayerCloner {
    static func clone(_ model: CALayer, presentation: Bool = false) -> CALayer {
        let src = presentation ? (model.presentation() ?? model) : model
        let dst: CALayer
        switch src {
        case let s as CAShapeLayer:
            let d = CAShapeLayer()
            d.path = s.path; d.fillColor = s.fillColor; d.fillRule = s.fillRule; d.strokeColor = s.strokeColor
            d.lineWidth = s.lineWidth; d.lineCap = s.lineCap; d.lineJoin = s.lineJoin; d.strokeStart = s.strokeStart; d.strokeEnd = s.strokeEnd
            dst = d
        case let s as CAReplicatorLayer:
            let d = CAReplicatorLayer()
            d.instanceCount = s.instanceCount; d.instanceTransform = s.instanceTransform
            d.instanceDelay = s.instanceDelay; d.preservesDepth = s.preservesDepth
            dst = d
        case let s as CAGradientLayer:
            let d = CAGradientLayer()
            d.colors = s.colors; d.locations = s.locations; d.startPoint = s.startPoint; d.endPoint = s.endPoint; d.type = s.type
            dst = d
        default:
            dst = CALayer()
        }
        dst.bounds = src.bounds
        dst.position = src.position
        dst.anchorPoint = src.anchorPoint
        dst.zPosition = src.zPosition
        dst.transform = src.transform
        dst.sublayerTransform = src.sublayerTransform
        dst.isGeometryFlipped = src.isGeometryFlipped
        dst.isHidden = src.isHidden
        dst.opacity = src.opacity
        dst.contents = src.contents
        dst.contentsRect = src.contentsRect
        dst.contentsCenter = src.contentsCenter
        dst.contentsGravity = src.contentsGravity
        dst.contentsScale = src.contentsScale
        dst.minificationFilter = src.minificationFilter
        dst.magnificationFilter = src.magnificationFilter
        dst.backgroundColor = src.backgroundColor
        dst.cornerRadius = src.cornerRadius
        dst.cornerCurve = src.cornerCurve
        dst.maskedCorners = src.maskedCorners
        dst.masksToBounds = src.masksToBounds
        dst.borderWidth = src.borderWidth
        dst.borderColor = src.borderColor
        dst.shadowColor = src.shadowColor
        dst.shadowOpacity = src.shadowOpacity
        dst.shadowRadius = src.shadowRadius
        dst.shadowOffset = src.shadowOffset
        dst.shadowPath = src.shadowPath
        dst.allowsEdgeAntialiasing = src.allowsEdgeAntialiasing
        if let m = model.mask { dst.mask = clone(m, presentation: presentation) }
        for sub in model.sublayers ?? [] { dst.addSublayer(clone(sub, presentation: presentation)) }
        return dst
    }
}
