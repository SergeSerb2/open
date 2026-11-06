import AppKit
import OpenDesign
import OpenWeb
import OpenExtensionsUI

@MainActor final class SceneCanvas: NSView {
    override var isFlipped: Bool { true }
    init(_ size: CGSize, appearance: ContentAppearance) {
        super.init(frame: CGRect(origin: .zero, size: size)); wantsLayer = true
        self.appearance = appearance.nsAppearance; layer?.backgroundColor = Core.popoverBackground.cgColor(appearance)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func label(_ text: String, x: CGFloat, y: CGFloat) {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 12); l.textColor = Core.foregroundPrimary.nsColor
        l.frame = CGRect(x: x, y: y, width: 1000, height: 20); addSubview(l)
    }
}
@MainActor enum Scenes {
    static let names = ["url-strip", "url-strip-overflow", "pane-strip", "toolbar-strip", "little-open", "scc-rows", "scc-grid", "prompt-install", "prompt-permissions", "prompt-remove", "popup-frame"]
    static func make(_ name: String, appearance: ContentAppearance) -> NSView {
        switch name {
        case "url-strip", "url-strip-overflow":
            let widths: [CGFloat] = name == "url-strip" ? [228, 300, 500] : [228]
            let canvas = SceneCanvas(CGSize(width: widths.reduce(0, +) + CGFloat(widths.count + 1) * 16, height: name == "url-strip" ? 900 : 150), appearance: appearance)
            var x: CGFloat = 16
            for width in widths {
                let counts = name == "url-strip" ? [0, 1, 3, 6] : [6]
                var row = 0
                for count in counts {
                    for hover in name == "url-strip" ? [false, true] : [true] {
                        let y = CGFloat(row) * 110 + 8
                        canvas.label("W \(Int(width)), pinned \(count), hover \(hover)", x: x, y: y)
                        let strip = ExtensionStripView(style: .urlField); strip.frame = CGRect(x: x, y: y + 20, width: width, height: 82)
                        strip.hovered = hover; _ = strip.setActions(Synthetic.actions(count))
                        // Popup flag only in the hover scene; hover-off rows must prove hidden buttons.
                        if !hover { strip.context.popupOpenID = nil }
                        let field = NSView(frame: CGRect(x: 8, y: 46, width: width - 16, height: 36))
                        field.wantsLayer = true; field.layer?.backgroundColor = SidebarRole.fieldFill.cgColor(appearance)
                        field.layer?.cornerRadius = URLFieldMetrics.cornerRadius; strip.addSubview(field, positioned: .below, relativeTo: nil)
                        strip.layoutSubtreeIfNeeded()
                        let host = NSTextField(labelWithString: "example.com"); host.font = Typography.urlHost.font
                        host.textColor = Core.foregroundPrimary.nsColor; host.lineBreakMode = .byTruncatingTail
                        host.frame = CGRect(x: 20, y: 56, width: max(0, (strip.geometry.frames.first?.minX ?? width - 70) - 22), height: 18)
                        strip.addSubview(host)
                        for (glyph, buttonX) in [(Glyph.copyLink, width - 70), (.siteControls, width - 42)] {
                            let button = NSImageView(frame: CGRect(x: buttonX + 7, y: 56, width: 16, height: 16))
                            button.image = glyph.image; button.contentTintColor = SidebarRole.toolbarGlyph.nsColor; button.isHidden = !hover
                            strip.addSubview(button)
                        }
                        canvas.addSubview(strip); row += 1
                    }
                }
                x += width + 16
            }
            return canvas
        case "pane-strip", "toolbar-strip":
            let canvas = SceneCanvas(CGSize(width: 1016, height: 980), appearance: appearance)
            var row = 0
            for width: CGFloat in [984, 600, 400, 250] {
                for host: CGFloat in [40, 160] {
                    for focused in [true, false] {
                        let y = CGFloat(row) * 60
                        canvas.label("w \(Int(width)), host \(Int(host)), focused \(focused)", x: 16, y: y)
                        let strip = ExtensionStripView(style: name == "toolbar-strip" ? .toolbar : .paneBar)
                        strip.frame = CGRect(x: 16, y: y + 19, width: width, height: 32); strip.hostTextWidth = host; strip.isFocused = focused
                        _ = strip.setActions(Synthetic.actions(26)); canvas.addSubview(strip)
                        strip.layoutSubtreeIfNeeded()
                        let scc = NSView(frame: name == "toolbar-strip" ? ToolbarMetrics.siteControls(width: width, stripWidth: strip.geometry.stripWidth) : CGRect(x: width - 105, y: 2, width: 32, height: 28))
                        scc.wantsLayer = true; scc.layer?.backgroundColor = SidebarRole.buttonHover.cgColor(appearance); scc.layer?.cornerRadius = 6
                        let icon = NSImageView(frame: scc.bounds.insetBy(dx: 7, dy: 5)); icon.image = Glyph.siteControls.image; icon.contentTintColor = SidebarRole.toolbarGlyph.nsColor; scc.addSubview(icon); strip.addSubview(scc)
                        let hostLabel = NSTextField(labelWithString: host == 40 ? "site" : "long.example.com")
                        hostLabel.font = Typography.urlHost.font; hostLabel.textColor = Core.foregroundPrimary.nsColor
                        hostLabel.lineBreakMode = .byTruncatingTail
                        scc.isHidden = !focused && name == "pane-strip"
                        let hostRight = (name == "toolbar-strip" ? scc.frame.minX : strip.geometry.frames.first?.minX ?? scc.frame.minX) - 4
                        let hostWidth = min(host, max(0, hostRight - 115 - 50))
                        hostLabel.frame = CGRect(x: min(max(140, (width - hostWidth) / 2), hostRight - 25 - hostWidth), y: 8, width: hostWidth, height: 18)
                        hostLabel.isHidden = hostWidth < SplitMetrics.hostMinimumWidth
                        strip.addSubview(hostLabel)
                        for (glyph, rect) in [(Glyph.back, SplitMetrics.back), (.forward, SplitMetrics.forward), (.reload, SplitMetrics.reload)] {
                            if !focused && name == "pane-strip" && glyph == .reload { continue }
                            let v = NSImageView(frame: rect.insetBy(dx: 8, dy: 4)); v.image = glyph.image
                            v.contentTintColor = SidebarRole.toolbarGlyph.nsColor; strip.addSubview(v)
                        }
                        row += 1
                    }
                }
            }
            return canvas
        case "little-open":
            let canvas = SceneCanvas(CGSize(width: 752, height: 160), appearance: appearance)
            for (i, shown) in [false, true].enumerated() {
                let y = CGFloat(i) * 72
                canvas.label("720 pt — extensions \(shown), URL width \(ExtensionsMetrics.littleOpenURLWidth(width: 720, hasExtensions: shown))", x: 16, y: y)
                if shown {
                    let button = ExtensionsPlateButton(frame: ExtensionsMetrics.littleOpenButton(width: 720).offsetBy(dx: 16, dy: y + 20))
                    button.glyph = .extensions; button.tooltipTitle = "Extensions"; button.setAccessibilityLabel("Extensions")
                    canvas.addSubview(button)
                }
            }
            return canvas
        case "scc-rows", "scc-grid":
            let counts = name == "scc-rows" ? [0, 3, 4] : [5, 12]
            let canvas = SceneCanvas(CGSize(width: CGFloat(counts.count) * 290, height: 270), appearance: appearance)
            for (i, count) in counts.enumerated() {
                let x = CGFloat(i) * 290 + 16
                canvas.label("\(count) extensions", x: x, y: 8)
                let body = ExtensionsSectionBody(frame: .zero); _ = body.setActions(Synthetic.actions(count, pinned: count / 2)); body.pickerMode = true
                body.frame = CGRect(origin: CGPoint(x: x, y: 40), size: body.intrinsicContentSize); canvas.addSubview(body)
                body.layoutSubtreeIfNeeded()
                if body.items.count > 1 {
                    body.items[1].setHovered(true)
                    body.items[1].subviews.compactMap { $0 as? ExtensionsPlateButton }.first?.setHovered(true, animated: false)
                }
                if body.items.count > 1 { body.keyDown(with: key(body.isGrid ? 124 : 125)) }
            }
            return canvas
        case "prompt-install", "prompt-permissions", "prompt-remove":
            let counts = name == "prompt-install" ? [0, 3, 12] : [3]
            let canvas = SceneCanvas(CGSize(width: CGFloat(counts.count) * 444, height: 500), appearance: appearance)
            for (i, count) in counts.enumerated() {
                let prompt = SyntheticPrompt(name == "prompt-remove" ? .uninstall : name == "prompt-permissions" ? .permissions : .install,
                    permissions: count, name: "A long extension name for a useful browsing tool")
                let view = ExtensionPromptView(model: prompt)
                view.frame.origin = CGPoint(x: CGFloat(i) * 444 + 12, y: 12); canvas.addSubview(view)
            }
            return canvas
        default:
            let canvas = SceneCanvas(CGSize(width: 1209, height: 660), appearance: appearance)
            var x: CGFloat = 16
            for size in [CGSize(width: 25, height: 25), CGSize(width: 320, height: 480), CGSize(width: 800, height: 600)] {
                canvas.label("\(Int(size.width))×\(Int(size.height))", x: x, y: 8)
                let panel = ExtensionPopupPanel(); panel.appearance = appearance.nsAppearance; panel.setFrame(CGRect(origin: .zero, size: size), display: false)
                let solid = NSView(); solid.wantsLayer = true; solid.layer?.backgroundColor = Core.backgroundPrimary.cgColor(appearance)
                panel.host(view: solid)
                let view = panel.contentView!; panel.contentView = nil; view.frame = CGRect(origin: CGPoint(x: x, y: 36), size: size)
                canvas.addSubview(view); panel.close(); x += size.width + 16
            }
            return canvas
        }
    }
    static func key(_ code: UInt16, text: String = "", time: TimeInterval = 0, window: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}

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
final class ExtensionsRenderer {
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
        func prepare(_ v: NSView) {
            (v as? ThemeBackgroundView)?.prepareForSnapshot()
            v.subviews.forEach(prepare)
        }
        prepare(view)
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
        let queue = device.makeCommandQueue()!
        // CARenderer and the read-back fence must share a queue. A fence on an
        // unrelated queue can finish before rendering and return uninitialized pixels.
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

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CLIError(description: "cannot create PNG destination") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError(description: "cannot finalize PNG") }
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
        case let s as CATextLayer:
            let d = CATextLayer()
            d.string = s.string; d.font = s.font; d.fontSize = s.fontSize
            d.foregroundColor = s.foregroundColor; d.alignmentMode = s.alignmentMode
            d.truncationMode = s.truncationMode; d.isWrapped = s.isWrapped
            d.allowsFontSubpixelQuantization = s.allowsFontSubpixelQuantization
            dst = d
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
        if !(src is CATextLayer) { dst.contents = src.contents }
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
        dst.allowsGroupOpacity = src.allowsGroupOpacity
        dst.allowsEdgeAntialiasing = src.allowsEdgeAntialiasing
        if let m = model.mask { dst.mask = clone(m, presentation: presentation) }
        for sub in model.sublayers ?? [] { dst.addSublayer(clone(sub, presentation: presentation)) }
        return dst
    }
}
