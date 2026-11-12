import AppKit
import ImageIO
import UniformTypeIdentifiers
import OpenDesign
import OpenFeatures
import OpenWeb

/// Capture tool offscreen checks and renders (page-platform §8.1 R-C1–R-C3): the area overlay,
/// the result card, the portrait composer, and the real `CaptureController` flow over a fake
/// page (`CapturePage`) whose snapshot is a known PNG. The App's `capture` suite covers the
/// engine paths.
@MainActor
enum CaptureChecks {
    // MARK: Fixtures

    /// A page image: vertical bands of known colors, `bands` tall each, at `scale`.
    static func pagePNG(size: CGSize, scale: CGFloat, band: CGFloat = 100) -> Data {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.30, 0.30), (0.30, 0.75, 0.35), (0.25, 0.45, 0.95), (0.95, 0.85, 0.25)]
        var y: CGFloat = 0, i = 0
        while y < size.height {
            let c = colors[i % colors.count]
            context.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            // Core Graphics is bottom-up: band i starts `y` points from the top.
            context.fill(CGRect(x: 0, y: CGFloat(h) - (y + band) * scale, width: CGFloat(w), height: band * scale))
            y += band; i += 1
        }
        return CaptureComposer.encodePNG(context.makeImage()!)!
    }

    struct Pixels {
        let width: Int, height: Int, data: [UInt8]
        init(_ image: CGImage) {
            width = image.width; height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            data = bytes
        }
        /// RGB at (x, y) from the top-left.
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x) * 4; return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])] }
        func close(_ x: Int, _ y: Int, _ expected: [Int], _ tolerance: Int = 3) -> Bool {
            zip(rgb(x, y), expected).allSatisfy { abs($0 - $1) <= tolerance }
        }
    }

    /// A fake page view: the band image drawn in a layer, flipped like the engine's view.
    final class FakePage: NSView {
        override var isFlipped: Bool { true }
        init(size: CGSize, png: Data) {
            super.init(frame: CGRect(origin: .zero, size: size)); wantsLayer = true
            layer?.contents = CaptureComposer.decode(png); layer?.contentsGravity = .resize
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// `OpenWeb.WebContent` over the fixture image (capture needs only the snapshots).
    final class CapturePage: WebContent {
        var png: Data, fullPage: FullPagePNG?
        var snapshots = 0
        init(png: Data) { self.png = png }
        var url: URL? { URL(string: "https://capture.example.com/page") }
        var title: String { "Capture: Fixture/Page" }
        var faviconPNG: Data? { nil }
        var isLoading: Bool { false }
        var estimatedProgress: Double { 1 }
        var canGoBack: Bool { false }
        var canGoForward: Bool { false }
        var isAudible: Bool { false }
        var isMuted = false
        var isCrashed: Bool { false }
        var zoomLevel: Double = 0
        func load(_ url: URL) {}
        func goBack() {}
        func goForward() {}
        func reload() {}
        func stopLoading() {}
        func evaluateJavaScript(_ script: String) async throws -> Any { 0 }
        func snapshotPNG() async throws -> Data { snapshots += 1; return png }
        func fullPagePNG(maxDevicePixels: Int) async throws -> FullPagePNG { fullPage ?? FullPagePNG(data: png, truncated: false) }
        func find(_ text: String, forward: Bool, caseSensitive: Bool) {}
        func stopFinding(clearSelection: Bool) {}
    }

    final class MemoryLibrary: CaptureLibrary {
        var rows: [UUID: (Data, CaptureComposer.Kind, String)] = [:], shown: [UUID] = []
        func save(png: Data, kind: CaptureComposer.Kind, sourceHost: String, title: String) async throws -> UUID { let id = UUID(); rows[id] = (png, kind, sourceHost); return id }
        func delete(id: UUID) throws { rows[id] = nil }
        func showInLibrary(id: UUID) { shown.append(id) }
        func fileURL(id: UUID) -> URL? { nil }
    }

    static func overlay(size: CGSize, selection: CGRect?, startDrag: Bool = true) -> (NSView, CaptureOverlayView) {
        let root = NSView(frame: CGRect(origin: .zero, size: size)); root.wantsLayer = true
        root.addSubview(FakePage(size: size, png: pagePNG(size: size, scale: 2)))
        let fill = SpaceThemeStyle.defaultTheme(system: .dark).toastFillTop.nsColor
        let view = CaptureOverlayView(frame: root.bounds, hintFill: fill)
        root.addSubview(view)
        if let selection, startDrag { view.begin(at: selection.origin); view.drag(to: CGPoint(x: selection.maxX, y: selection.maxY)) }
        return (root, view)
    }

    static func card(saved: Bool, area: Bool = true, note: String? = nil) -> (NSView, CaptureResultView) {
        let png = pagePNG(size: CGSize(width: 400, height: 300), scale: 1)
        let view = CaptureResultView(image: NSImage(data: png)!, imageSize: CGSize(width: 800, height: 600),
                                     actions: CaptureResultView.actions(area: area, saved: saved), savedToLibrary: saved, note: note)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: view.frame.width + 64, height: view.frame.height + 64)); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.9, alpha: 1).cgColor
        view.setFrameOrigin(CGPoint(x: 32, y: 32)); root.addSubview(view)
        return (root, view)
    }

    // MARK: Renders (`features-render capture --scene … --out FILE [--scale 1|2]`)

    static func render(_ args: [String]) throws {
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out required") }
        let scene = RenderCLI.value(args, "--scene") ?? "overlay"
        NSApp.appearance = NSAppearance(named: RenderCLI.value(args, "--appearance") == "light" ? .aqua : .darkAqua)
        let size = CGSize(width: 900, height: 600)
        let image: CGImage
        switch scene {
        case "overlay-rest": image = OffscreenRenderer().render(overlay(size: size, selection: nil).0, scale: scale)
        case "overlay": image = OffscreenRenderer().render(overlay(size: size, selection: CGRect(x: 180, y: 140, width: 360, height: 220)).0, scale: scale)
        case "overlay-above": image = OffscreenRenderer().render(overlay(size: size, selection: CGRect(x: 420, y: 380, width: 300, height: 210)).0, scale: scale)
        case "card": image = OffscreenRenderer().render(card(saved: true).0, scale: scale)
        case "card-private": image = OffscreenRenderer().render(card(saved: false).0, scale: scale)
        case "card-full-page": image = OffscreenRenderer().render(card(saved: true, area: false, note: "Page cut at 32,768 px.").0, scale: scale)
        case "portrait-color", "portrait-website", "portrait-wallpaper":
            let source = PortraitStyle.Source(rawValue: String(scene.dropFirst("portrait-".count)))!
            let job = CaptureComposer.Job(kind: .portrait, png: pagePNG(size: CGSize(width: 640, height: 480), scale: scale), viewSize: CGSize(width: 640, height: 480),
                                          portrait: PortraitStyle(source: source, colorPercentage: 0.88, hidesWatermark: false),
                                          wallpaper: source == .wallpaper ? pagePNG(size: CGSize(width: 400, height: 250), scale: 1, band: 25) : nil)
            image = CaptureComposer.decode(try CaptureComposer.compose(job).png)!
        case "portrait-popover":
            let view = PortraitCaptureView(style: .standard)
            let page = CaptureComposer.decode(pagePNG(size: CGSize(width: 640, height: 480), scale: 1))!
            view.preview = CaptureComposer.portrait(page, style: .standard)
            let root = NSView(frame: CGRect(x: 0, y: 0, width: view.frame.width + 48, height: view.frame.height + 48)); root.wantsLayer = true
            root.layer?.backgroundColor = (NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)).cgColor
            view.setFrameOrigin(CGPoint(x: 24, y: 24)); root.addSubview(view); root.layoutSubtreeIfNeeded()
            image = OffscreenRenderer().render(root, scale: scale)
        default: throw CLIError(description: "unknown capture scene \(scene)")
        }
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out)); print("rendered \(out)")
    }

    // MARK: Checks

    static func run(_ check: (Bool, String) -> Void) async throws {
        try overlayChecks(check)
        try cardChecks(check)
        try composerChecks(check)
        try await controllerChecks(check)
    }

    /// R-C1: dim, selection edge, size label below and above, hint capsule.
    static func overlayChecks(_ check: (Bool, String) -> Void) throws {
        let size = CGSize(width: 900, height: 600)
        let (restRoot, rest) = overlay(size: size, selection: nil)
        let restImage = Pixels(OffscreenRenderer().render(restRoot, scale: 1))
        let hint = rest.hint.frame
        check(hint.minY == CaptureMetrics.hintTop && hint.height == CaptureMetrics.hintHeight && abs(hint.midX - size.width / 2) <= 0.5
              && !rest.hint.isHidden && rest.hint.text == "Click or drag to capture a portion of this page",
              "R-C1 hint capsule centered 16 pt from the page top, 28 tall: \(hint)")
        // Band 2 (blue 0.25, 0.45, 0.95; y 200–300) under the 0.35 dim at y 250.
        let dimmed = [0.25, 0.45, 0.95].map { Int(($0 * 255 * 0.65).rounded()) }
        check(restImage.close(40, 250, dimmed), "R-C1 at rest the whole page dims black 0.35: \(restImage.rgb(40, 250)) vs \(dimmed)")
        let selection = CGRect(x: 180, y: 140, width: 360, height: 220)
        let (root, view) = overlay(size: size, selection: selection)
        let px = Pixels(OffscreenRenderer().render(root, scale: 1))
        check(view.selection == selection && view.anchor == selection.origin, "R-C1 drag selection from the press corner: \(String(describing: view.selection))")
        check(px.close(300, 250, [64, 115, 242]) && px.close(100, 250, dimmed),
              "R-C1 inside the selection is undimmed, outside dimmed: in \(px.rgb(300, 250)) out \(px.rgb(100, 250))")
        let inner = px.rgb(300, 140), outer = px.rgb(300, 139)
        check(inner.allSatisfy { $0 >= 235 } && outer.allSatisfy { $0 <= 120 },
              "R-C1 edge: 1 pt white 0.95 inside (\(inner)), 1 pt black 0.25 outside (\(outer))")
        let label = view.sizeLabelFrame ?? .zero
        check(label.minY == selection.maxY + 6 && label.height == 20 && abs(label.midX - selection.midX) <= 1 && CaptureOverlayView.sizeText(selection) == "360 × 220",
              "R-C1 size label 6 pt below the selection, 20 tall, centered, \"360 × 220\": \(label)")
        check(view.hint.isHidden || view.hint.alphaValue == 0, "R-C1 the hint fades out when the drag starts")
        let low = CGRect(x: 420, y: 380, width: 300, height: 210)
        let (_, above) = overlay(size: size, selection: low)
        let aboveLabel = above.sizeLabelFrame ?? .zero
        check(aboveLabel.maxY == low.minY - 6, "R-C1 size label moves above the selection when there is no room below: \(aboveLabel)")
        // Outcomes: a small drag cancels; Return takes the whole visible page; Esc cancels.
        var outcomes: [CaptureOverlayView.Outcome] = []
        let (_, small) = overlay(size: size, selection: nil)
        small.onFinish = { outcomes.append($0) }
        small.begin(at: CGPoint(x: 10, y: 10)); small.drag(to: CGPoint(x: 17.9, y: 40)); small.end()
        let (_, exact) = overlay(size: size, selection: nil)
        exact.onFinish = { outcomes.append($0) }
        exact.begin(at: CGPoint(x: 10, y: 10)); exact.drag(to: CGPoint(x: 18, y: 18)); exact.end()
        let (_, whole) = overlay(size: size, selection: nil)
        whole.onFinish = { outcomes.append($0) }; whole.captureWholePage(); whole.cancel()
        check(outcomes == [.cancelled, .selected(CGRect(x: 10, y: 10, width: 8, height: 8)), .selected(CGRect(origin: .zero, size: size))],
              "R-C1 7.9 pt drag cancels, 8 × 8 is accepted, Return selects the page once: \(outcomes)")
        let (_, clamp) = overlay(size: size, selection: nil)
        clamp.begin(at: CGPoint(x: 850, y: 550)); clamp.drag(to: CGPoint(x: 2000, y: -50))
        check(clamp.selection == CGRect(x: 850, y: 0, width: 50, height: 550), "R-C1 the selection stays inside the page: \(String(describing: clamp.selection))")
        let draws = view.drawCount
        OffscreenRenderer.settle(root, runLoop: 0.1)
        check(view.drawCount == draws, "R-C1 an idle overlay does not redraw (\(draws) → \(view.drawCount))")
    }

    /// R-C2: thumbnail fit, six buttons, incognito variant.
    static func cardChecks(_ check: (Bool, String) -> Void) throws {
        let (root, card) = self.card(saved: true)
        let cardPixels = Pixels(OffscreenRenderer().render(root, scale: 1))
        // The card sits at (32, 32) in the scene: the thumbnail's red top band is at its top,
        // the white-ish glyphs of the button row near its bottom (dark appearance).
        let thumbTop = cardPixels.rgb(32 + 124, 32 + 20), glyphRow = (32 + 12 + 160 + 8 + 14 + 8 + 4)...(32 + 12 + 160 + 8 + 14 + 8 + 24)
        let brightest = glyphRow.map { y in (32 + 40...32 + 208).map { x in cardPixels.rgb(x, y).reduce(0, +) }.max() ?? 0 }.max() ?? 0
        check(thumbTop[0] > 200 && thumbTop[1] < 120 && brightest > 400,
              "R-C2 rendered card: thumbnail at the top (\(thumbTop)), light glyphs in the button row at the bottom (max sum \(brightest))")
        check(card.frame.width == 248 && card.thumbnail.frame == CGRect(x: 18, y: 12, width: 213, height: 160),
              "R-C2 card 248 wide; 4:3 thumbnail fits 224 × 160 at the 12 pt padding: \(card.thumbnail.frame)")
        let order = card.actions.map(\.rawValue)
        let frames = card.actions.compactMap { card.buttons[$0]?.frame }
        let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
        check(order == ["copy", "save", "share", "library", "retake", "delete"] && frames.allSatisfy { $0.size == CGSize(width: 28, height: 28) }
              && gaps.allSatisfy { $0 == 6 } && card.savedLine.superview != nil && card.savedLine.stringValue == "Saved to Library"
              && frames.first!.minY == card.savedLine.frame.maxY + 8 && card.frame.height == frames.first!.maxY + 12,
              "R-C2 six 28 pt buttons, 6 pt apart, under \"Saved to Library\": \(order)")
        let labels = card.actions.compactMap { card.buttons[$0]?.accessibilityLabel() }
        check(labels == ["Copy", "Save…", "Share", "Show in Library", "Retake", "Delete"], "R-C2 button accessibility labels: \(labels)")
        let (_, privateCard) = self.card(saved: false)
        check(privateCard.actions == [.copy, .save, .share] && privateCard.savedLine.superview == nil
              && privateCard.frame.height == card.frame.height - 22,
              "R-C2 incognito card: Copy, Save…, Share only; no Library line: \(privateCard.actions.map(\.rawValue))")
        let (_, full) = self.card(saved: true, area: false, note: "Page cut at 32,768 px.")
        check(full.actions == [.copy, .save, .share, .library, .delete] && full.noteLine.stringValue == "Page cut at 32,768 px.",
              "R-C2 full page card: no Retake; the cut note")
        let tall = CaptureResultView.thumbnailSize(CGSize(width: 2720, height: 24000))
        check(tall.height == 160 && tall.width == 18, "R-C2 a tall page's thumbnail fits 160 tall: \(tall)")
    }

    /// R-C3 and the pipeline math: crop, portrait canvas, backgrounds, file name, limits.
    static func composerChecks(_ check: (Bool, String) -> Void) throws {
        let viewSize = CGSize(width: 800, height: 500)
        let page = pagePNG(size: viewSize, scale: 2)
        let area = try CaptureComposer.compose(.init(kind: .area, png: page, selection: CGRect(x: 100, y: 100, width: 300, height: 200), viewSize: viewSize))
        let cropped = Pixels(CaptureComposer.decode(area.png)!)
        // Rows 0–199 of the crop are page y 100–199 (green band) then 200–299 (blue band).
        check(area.pixelWidth == 600 && area.pixelHeight == 400 && cropped.close(10, 10, [77, 191, 89]) && cropped.close(10, 250, [64, 115, 242]),
              "C1 area crop: 300 × 200 pt at 2x is 600 × 400 px with the bands at their page offsets")
        let thumb = CaptureComposer.pixelSize(area.thumbnailPNG)!
        check(max(thumb.width, thumb.height) == CaptureComposer.thumbnailMaxPixels, "thumbnail long side \(CaptureComposer.thumbnailMaxPixels): \(thumb)")
        // Portrait: the popover preview's proportions (239 × 127; page card 96 tall).
        let aspect = Double(CaptureMetrics.portraitAspect)
        let layout = CaptureComposer.portraitLayout(imageSize: CGSize(width: 1000, height: 760))
        check(abs(layout.canvas.width / layout.canvas.height - aspect) < 0.003 && abs(layout.image.height / layout.canvas.height - 96.0 / 127.0) < 0.003
              && abs(layout.image.midX - layout.canvas.width / 2) <= 0.5 && abs(layout.image.midY - layout.canvas.height / 2) <= 0.5,
              "R-C3 portrait: 239:127 canvas, page 96/127 of its height and centred: \(layout)")
        let wideLayout = CaptureComposer.portraitLayout(imageSize: CGSize(width: 2400, height: 600))
        check(abs(wideLayout.canvas.width / wideLayout.canvas.height - aspect) < 0.003 && wideLayout.image.width <= wideLayout.canvas.width * 0.86 + 1,
              "R-C3 a wide page sets the canvas from its width (86 %): \(wideLayout)")
        var corners: [String: [Int]] = [:]
        let wallpaper = pagePNG(size: CGSize(width: 300, height: 200), scale: 1, band: 20)
        let cases: [(String, PortraitStyle, Data?)] = [
            ("color-start", PortraitStyle(source: .color, colorPercentage: 0, hidesWatermark: true), nil),
            ("color-end", PortraitStyle(source: .color, colorPercentage: 1, hidesWatermark: true), nil),
            ("website", PortraitStyle(source: .website, colorPercentage: 1, hidesWatermark: true), nil),
            ("wallpaper", PortraitStyle(source: .wallpaper, colorPercentage: 1, hidesWatermark: true), wallpaper),
            ("wallpaper-unreadable", PortraitStyle(source: .wallpaper, colorPercentage: 1, hidesWatermark: true), Data("not an image".utf8)),
        ]
        for (name, style, data) in cases {
            let output = try CaptureComposer.compose(.init(kind: .portrait, png: page, viewSize: viewSize, portrait: style, wallpaper: data))
            let px = Pixels(CaptureComposer.decode(output.png)!)
            corners[name] = px.rgb(2, 2)
            check(abs(Double(px.width) / Double(px.height) - aspect) < 0.003 && px.rgb(px.width / 2, px.height / 2) != px.rgb(2, 2),
                  "R-C3 \(name) background: \(px.width) × \(px.height), corner \(px.rgb(2, 2))")
        }
        check(Set([corners["color-start"]!, corners["color-end"]!, corners["website"]!, corners["wallpaper"]!]).count == 4
              && corners["wallpaper-unreadable"] == corners["website"],
              "R-C3 colour ends, website and wallpaper differ; an unreadable wallpaper gives the website colour: \(corners)")
        // The watermark tile at the bottom left changes those pixels; hidden, it does not.
        let marked = Pixels(CaptureComposer.decode(try CaptureComposer.compose(.init(kind: .portrait, png: page, viewSize: viewSize,
            portrait: PortraitStyle(source: .color, colorPercentage: 0.5, hidesWatermark: false))).png)!)
        let plain = Pixels(CaptureComposer.decode(try CaptureComposer.compose(.init(kind: .portrait, png: page, viewSize: viewSize,
            portrait: PortraitStyle(source: .color, colorPercentage: 0.5, hidesWatermark: true))).png)!)
        let tile = Double(marked.width) * Double(CaptureMetrics.portraitWatermarkFraction), inset = Double(marked.width) * Double(CaptureMetrics.portraitWatermarkInsetFraction)
        let tx = Int(inset + tile / 2), ty = marked.height - Int(inset + tile / 2)
        check(marked.rgb(tx, ty) != plain.rgb(tx, ty) && marked.rgb(4, 4) == plain.rgb(4, 4),
              "R-C3 watermark tile at the bottom left: \(marked.rgb(tx, ty)) vs hidden \(plain.rgb(tx, ty))")
        let suite = UserDefaults(suiteName: "open.features-render.portrait")!
        suite.removePersistentDomain(forName: "open.features-render.portrait")
        suite.set("theme", forKey: PortraitStyle.sourceKey)
        let migrated = PortraitStyle(defaults: suite)
        PortraitStyle(source: .wallpaper, colorPercentage: 0.25, hidesWatermark: true).save(to: suite)
        let saved = PortraitStyle(defaults: suite)
        suite.removePersistentDomain(forName: "open.features-render.portrait")
        check(migrated == .standard && saved == PortraitStyle(source: .wallpaper, colorPercentage: 0.25, hidesWatermark: true),
              "R-C3 open.capture.portrait* keys: old values give the standard style; the three keys round-trip")
        var components = DateComponents(); components.year = 2026; components.month = 3; components.day = 7; components.hour = 15; components.minute = 4
        let gmt = TimeZone(identifier: "GMT")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = gmt
        let name = CaptureComposer.fileName(title: "Café: News / Today!", date: calendar.date(from: components)!, timeZone: gmt)
        check(name == "Caf News  Today 03-07 at 3.04PM.png", "Save… default name drops characters outside [A-Za-z0-9-_ ]: \"\(name)\"")
        // Pixel limits, at and just over each bound (header-only PNGs of one row or column).
        func png(_ w: Int, _ h: Int) -> Data {
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return CaptureComposer.encodePNG(c.makeImage()!)!
        }
        check(CaptureComposer.pixelSize(png(8192, 1)) != nil && CaptureComposer.pixelSize(png(8193, 1)) == nil
              && CaptureComposer.pixelSize(png(1, 32768)) != nil && CaptureComposer.pixelSize(png(1, 32769)) == nil,
              "limits: 8,192 px wide and 32,768 px tall are accepted, one more is refused")
        check(CaptureComposer.withinLimits(width: 4096, height: 32768) && !CaptureComposer.withinLimits(width: 4097, height: 32768),
              "limits: 4,096 × 32,768 px in all is accepted, 4,097 × 32,768 is refused")
        check(CaptureComposer.decode(Data("not a png".utf8)) == nil && CaptureComposer.pixelSize(Data()) == nil,
              "limits: data that is not a PNG is refused")
    }

    /// The controller over a fake page: overlay → crop → Library → card; lifetime and hover;
    /// Esc; the Cmd+Shift drag with its 4 pt threshold and click replay; incognito; portrait.
    static func controllerChecks(_ check: (Bool, String) -> Void) async throws {
        let size = CGSize(width: 900, height: 600)
        let root = FlippedRoot(frame: CGRect(origin: .zero, size: CGSize(width: 1000, height: 700))); root.wantsLayer = true
        let pageView = ClickRecorder(frame: CGRect(x: 50, y: 60, width: size.width, height: size.height))
        root.addSubview(pageView)
        let window = OffscreenRenderer.host(root, scale: 2)
        defer { window.contentView = nil; window.close() }
        let content = CapturePage(png: pagePNG(size: size, scale: 2))
        let suite = "open.capture-check.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MemoryLibrary()
        let capture = CaptureController(root: root, defaults: defaults)
        var isPrivate = false, sounds = 0, hints = 0, copied = 0
        capture.pageTarget = { .init(url: content.url, title: content.title, content: content, view: pageView, isPrivate: isPrivate) }
        capture.anchor = { CGPoint(x: 940, y: 68) }
        capture.library = library
        capture.playSound = { sounds += 1 }
        // Offscreen windows are never on screen and drop window-delivered clicks; record the replay.
        capture.replay = { pageView.events.append($0) }
        var hooks = CaptureToastHooks(); hooks.shortcutHint = { hints += 1 }; hooks.copied = { copied += 1 }
        capture.toasts = hooks
        func wait(_ condition: () -> Bool) async { for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) } }

        capture.start(.area)
        check(capture.phase == .selecting && capture.overlay?.frame == pageView.frame && capture.isOverlayActive,
              "C1 the overlay covers the focused page only: \(capture.overlay?.frame ?? .zero)")
        capture.overlay?.begin(at: CGPoint(x: 100, y: 100)); capture.overlay?.drag(to: CGPoint(x: 400, y: 300)); capture.overlay?.end()
        await wait { capture.phase == .showing }
        let result = capture.lastResult
        check(result?.pixelWidth == 600 && result?.pixelHeight == 400 && result?.kind == .area && library.rows.count == 1
              && library.rows.values.first?.2 == "capture.example.com" && sounds == 1,
              "C1 area: a 600 × 400 PNG at 2x, one Library row with the source host, the capture sound hook ran")
        let card = capture.card
        check(card?.frame == CGRect(x: 940 - 248, y: 68, width: 248, height: card?.frame.height ?? 0) && card?.actions.count == 6,
              "R-C2 the card's top-right corner sits at the toast anchor: \(card?.frame ?? .zero)")
        check(hints == 0 && defaults.double(forKey: CaptureController.shortcutHintKey) == 0, "§4.6.7 the keycap hint waits for the flow to end")
        let deadline = capture.cardDeadline ?? 0
        check(abs(deadline - CACurrentMediaTime() - 8) < 0.5 && capture.cardRemaining == 8, "R-C2 the card's scheduled lifetime is 8 s")
        card?.setHovered(true)
        check(capture.cardDeadline == nil && capture.card != nil, "R-C2 the pointer over the card pauses its lifetime")
        card?.setHovered(false)
        check(capture.cardDeadline != nil && capture.cardRemaining <= 8 && capture.cardRemaining > 7, "R-C2 leaving resumes it with the time left (\(capture.cardRemaining) s)")
        card?.buttons[.copy]?.performClick(nil)
        check(NSPasteboard.general.data(forType: .png) == result?.png && copied == 1, "C7 Copy puts the PNG on the pasteboard and shows \"Copied Image\"")
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        check(capture.handleKey(esc) && capture.card == nil && capture.phase == .idle && hints == 1, "R-C2 Esc closes the card")
        check(defaults.double(forKey: CaptureController.shortcutHintKey) > 0, "§4.6.7 the hint stored its time")

        // C4: Esc during the overlay, no row; no second hint within 14 days.
        capture.start(.area)
        check(capture.handleKey(esc) && capture.overlay == nil && capture.lastResult?.savedID != nil && library.rows.count == 1 && hints == 1,
              "C4 Esc during the overlay cancels: no new row, no new hint")

        // Delete removes the row; Retake replaces the capture with a new overlay.
        capture.start(.area); capture.overlay?.captureWholePage()
        await wait { capture.phase == .showing }
        check(capture.lastResult?.pixelWidth == 1800 && capture.lastResult?.pixelHeight == 1200 && library.rows.count == 2,
              "Return captures the whole visible page (1800 × 1200)")
        capture.card?.buttons[.retake]?.performClick(nil)
        check(library.rows.count == 1 && capture.overlay != nil && capture.lastEntry == .retake, "Retake deletes this capture and starts a new overlay")
        capture.overlay?.begin(at: .zero); capture.overlay?.drag(to: CGPoint(x: 50, y: 50)); capture.overlay?.end()
        await wait { capture.phase == .showing }
        capture.card?.buttons[.delete]?.performClick(nil)
        check(library.rows.count == 1 && capture.card == nil, "Delete removes the file and the row in one step")

        // C5 and C6: the Cmd+Shift drag through the window's mouse path.
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = [.command, .shift]) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: pageView.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        check(!capture.handleMouse(mouse(.leftMouseDown, CGPoint(x: 30, y: 30), [.command])) && !capture.isHoldingPress,
              "C5 Cmd without Shift is not held")
        check(!capture.handleMouse(mouse(.leftMouseDown, CGPoint(x: 30, y: 30), [.command, .shift, .option])), "C5 Cmd+Shift+Option is not held")
        let down = capture.handleMouse(mouse(.leftMouseDown, CGPoint(x: 200, y: 150)))
        let small = capture.handleMouse(mouse(.leftMouseDragged, CGPoint(x: 203, y: 152)))
        check(down && small && capture.isHoldingPress && capture.overlay == nil, "C5 a 3.6 pt move keeps the press held, no overlay")
        _ = capture.handleMouse(mouse(.leftMouseDragged, CGPoint(x: 204, y: 150)))
        check(capture.overlay?.anchor == CGPoint(x: 200, y: 150) && capture.lastEntry == .drag, "C5 4 pt of travel starts the overlay at the press point")
        _ = capture.handleMouse(mouse(.leftMouseDragged, CGPoint(x: 400, y: 350)))
        let up = capture.handleMouse(mouse(.leftMouseUp, CGPoint(x: 400, y: 350)))
        await wait { capture.phase == .showing }
        check(up && capture.lastResult?.pixelWidth == 400 && capture.lastResult?.pixelHeight == 400 && hints == 1,
              "C5 the drag captures 200 × 200 pt from the press point; no keycap hint after a drag")
        capture.closeCard()
        let clicks = pageView.events.count
        _ = capture.handleMouse(mouse(.leftMouseDown, CGPoint(x: 120, y: 80)))
        let passUp = capture.handleMouse(mouse(.leftMouseUp, CGPoint(x: 120, y: 80)))
        check(!passUp && pageView.events.count == clicks + 1 && pageView.events.last?.type == .leftMouseDown
              && pageView.events.last?.modifierFlags.contains([.command, .shift]) == true && capture.replayCount == 1 && capture.overlay == nil,
              "C6 a Cmd+Shift click replays the held press to the page, then lets the mouse-up through (pass \(passUp), clicks \(clicks) → \(pageView.events.count), replays \(capture.replayCount))")
        defaults.set(false, forKey: CaptureController.dragToCaptureKey)
        check(!capture.handleMouse(mouse(.leftMouseDown, CGPoint(x: 120, y: 80))), "§4.6.2 open.capture.dragToCaptureEnabled = false turns the drag off")
        defaults.removeObject(forKey: CaptureController.dragToCaptureKey)

        // C7 (offscreen): an incognito page saves nothing; the card offers Copy, Save…, Share.
        isPrivate = true
        let savedRows = library.rows.count
        let completedBefore = capture.completedCount
        capture.start(.portrait)
        await wait { capture.portraitView?.preview != nil }
        // Offscreen windows do not order a popover in (`isShown`); the e2e row checks that on screen.
        check(capture.portraitPopover != nil && capture.portraitView?.preview != nil && capture.phase != .capturing && capture.completedCount == completedBefore,
              "C3 Portrait Mode makes the popover with a preview and captures nothing yet (preview \(capture.portraitView?.preview != nil), phase \(capture.phase))")
        capture.portraitView?.captureButton.performClick(nil)
        await wait { capture.phase == .showing }
        let portrait = capture.lastResult
        check(portrait?.savedID == nil && library.rows.count == savedRows && capture.card?.actions == [.copy, .save, .share]
              && abs(Double(portrait?.pixelWidth ?? 0) / Double(portrait?.pixelHeight ?? 1) - Double(CaptureMetrics.portraitAspect)) < 0.003,
              "C3/C7 incognito portrait (popover, then its button): a 239:127 PNG, no Library row, Copy/Save…/Share only")
        isPrivate = false
        content.fullPage = FullPagePNG(data: pagePNG(size: CGSize(width: 400, height: 1200), scale: 2), truncated: true)
        capture.start(.fullPage)
        await wait { capture.phase == .showing }
        check(capture.lastResult?.pixelHeight == 2400 && capture.lastResult?.truncated == true && capture.card?.note == "Page cut at 32,768 px."
              && capture.lastResult?.png == content.fullPage?.data,
              "C2 full page keeps the engine's PNG bytes; a cut page says so on the card")
        capture.tearDown()
        check(capture.card == nil && capture.overlay == nil && capture.phase == .idle, "teardown removes the card and the overlay")
    }

    final class FlippedRoot: NSView { override var isFlipped: Bool { true } }
    final class ClickRecorder: NSView {
        var events: [NSEvent] = []
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { events.append(event) }
        override func mouseUp(with event: NSEvent) {}
    }
}
