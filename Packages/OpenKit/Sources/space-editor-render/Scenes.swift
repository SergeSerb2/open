import AppKit
import OpenDesign
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

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Lays out, displays, and renders `view` at `scale`. Returns RGBA8 pixels
    /// in `colorSpace`, the space Core Animation composites in: sRGB by
    /// default, or a capture's display profile to stand in for that display.
    ///
    /// The view goes into a borderless window that is never ordered on screen, so
    /// AppKit builds and draws the layer tree normally. The window reports the
    /// requested backing scale, so 2x renders work on a 1x display.
    func render(_ view: NSView, scale: CGFloat, colorSpace: CGColorSpace = OffscreenRenderer.sRGB) -> CGImage {
        let window = Self.host(view, scale: scale)
        let image = snapshot(view, scale: scale, colorSpace: colorSpace)
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
        func prepare(_ v: NSView) {
            (v as? ThemeBackgroundView)?.prepareForSnapshot()
            v.subviews.forEach(prepare)
        }
        prepare(view)
        CATransaction.flush()
    }

    /// Renders a view that is already in a window. With `presentation`, layers use
    /// their in-flight animation values (to capture a frame of a transition).
    func snapshot(_ view: NSView, scale: CGFloat, presentation: Bool = false, colorSpace: CGColorSpace = OffscreenRenderer.sRGB) -> CGImage {
        let size = view.bounds.size
        guard let rootLayer = view.layer else { fatalError("view is not layer-backed") }
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        let texture = device.makeTexture(descriptor: desc)!
        // CARenderer otherwise uses a separate internal queue and only waits until
        // its work is scheduled. Readback must follow rendering on the same queue.
        // Contract: QuartzCore/CARenderer.h, kCARendererMetalCommandQueue.
        let queue = device.makeCommandQueue()!
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace as String: colorSpace,
            kCARendererMetalCommandQueue as String: queue,
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
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private typealias CreateFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    /// Real-window snapshot: the window server composites `view` on the main
    /// display, in that display's space, and returns the window's pixels at
    /// 1x geometry (2x displays are box-averaged). Callers hold the on-screen
    /// lock (`/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`). Our own window
    /// needs no Screen Recording permission (as the App's `snapshot`).
    static func onscreen(_ view: NSView) throws -> CGImage {
        guard let screen = NSScreen.main else { throw CLIError(description: "no main display") }
        let size = view.bounds.size
        let window = NSWindow(contentRect: CGRect(x: screen.frame.minX, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.setFrame(CGRect(x: screen.frame.minX, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(view, runLoop: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(lib, "CGWindowListCreateImageFromArray") else { throw CLIError(description: "no window capture") }
        defer { dlclose(lib) }
        let create = unsafeBitCast(symbol, to: CreateFromArray.self)
        var pointers = [UnsafeRawPointer(bitPattern: UInt(window.windowNumber))]
        guard let array = CFArrayCreate(nil, &pointers, 1, nil),
              let image = create(.null, array, (1 << 0) | (1 << 3))?.takeRetainedValue() else { throw CLIError(description: "window capture failed") }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard image.width >= w, image.height >= h, let space = image.colorSpace else { throw CLIError(description: "window capture is \(image.width)x\(image.height)") }
        guard image.width != w || image.height != h else { return image }
        // Box-average the integer backing scale to window points.
        let factor = image.width / w
        guard factor * w == image.width, factor * h == image.height,
              let source = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CLIError(description: "window capture scale is not an integer")
        }
        source.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let input = source.data!.assumingMemoryBound(to: UInt8.self)
        var output = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { for c in 0..<4 {
            var sum = 0
            for dy in 0..<factor { for dx in 0..<factor { sum += Int(input[((y * factor + dy) * image.width + x * factor + dx) * 4 + c]) } }
            output[(y * w + x) * 4 + c] = UInt8((Double(sum) / Double(factor * factor)).rounded())
        } } }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(output) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
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
        dst.allowsGroupOpacity = src.allowsGroupOpacity
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

import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Window-sized composition for renders: theme background, the web panel
/// chrome, stand-in traffic lights, and the real `SidebarView`.
@MainActor
final class RenderScene: NSView {
    struct Options {
        var size = CGSize(width: 1280, height: 900)
        var sidebarHidden = false
        var revealCard = false
        var trafficLights = true
        /// Panel without a page: white 10 % (Arc's empty state). Otherwise opaque white.
        var emptyPanel = true
    }

    let background: ThemeBackgroundView
    let sidebar: SidebarView
    let panelHost = NSView()
    let panel = WebPanelChromeLayer()
    let lights = TrafficLightsView()
    let options: Options
    let retainedDelegate: any SidebarDelegate

    init(context: SidebarContext, options: Options, delegate: any SidebarDelegate) {
        self.options = options
        self.retainedDelegate = delegate
        background = ThemeBackgroundView(frame: CGRect(origin: .zero, size: options.size))
        sidebar = SidebarView(context: context)
        super.init(frame: CGRect(origin: .zero, size: options.size))
        wantsLayer = true
        sidebar.delegate = delegate
        sidebar.themeBackground = background
        addSubview(background)
        panelHost.wantsLayer = true
        panelHost.layer?.addSublayer(panel)
        panel.showsEmptyState = options.emptyPanel
        addSubview(panelHost)
        if options.revealCard { sidebar.presentation = .floatingCard }
        if !options.sidebarHidden || options.revealCard { addSubview(sidebar) }
        if options.trafficLights && !(options.sidebarHidden && !options.revealCard) {
            if options.revealCard { sidebar.addSubview(lights) } else { addSubview(lights) }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = sidebar.context.sidebarWidth
        background.frame = bounds
        panelHost.frame = bounds
        let hidden = options.sidebarHidden
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel.frame = PanelMetrics.frame(windowSize: bounds.size, sidebarWidth: w, sidebarHidden: hidden)
        CATransaction.commit()
        if options.revealCard {
            let i = WindowMetrics.revealCardInset
            sidebar.frame = CGRect(x: i, y: i, width: w, height: bounds.height - 2 * i)
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        } else {
            sidebar.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        }
    }
}

/// Stand-in for the system traffic lights in renders: three 12 pt circles at the
/// measured centers. Inactive style only (black ≈ 0.11 over the theme, F0001).
@MainActor
final class TrafficLightsView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Inactive lights: black 0.11 on light content (F0001), white 0.31 on dark (F0079).
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.31) : NSColor.black.withAlphaComponent(0.11)).setFill()
        for f in ChromeMetrics.trafficLightFrames {
            let d = ChromeMetrics.trafficLightDiameter
            NSBezierPath(ovalIn: NSRect(x: f.midX - d / 2, y: f.midY - d / 2, width: d, height: d)).fill()
        }
    }
}

/// Delegate for renders and checks: applies model intents, records the rest.
@MainActor
final class RecordingDelegate: SidebarDelegate {
    var log: [SidebarIntent] = []
    var refuses = false
    @discardableResult
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        log.append(intent)
        return !refuses && ModelSidebarActions(context: sidebar.context).perform(intent)
    }
}
