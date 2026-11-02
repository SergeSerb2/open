import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// S-US1 (page-platform §8.1): the status button under the URL field on the real `SidebarView`:
/// frame `[8, 88, W − 16, 28]`, the 34 pt push-down, the four title states at W = 228 and 300
/// (and the short title at 200 pt), the click intent, the hidden rules, the push-down motion, and
/// the fill against the URL field's. `sidebar-render url-status --out DIR` renders the states.
@MainActor
enum URLStatusChecks {
    static let states: [(String, URLStatusItem)] = [
        ("available", URLStatusItem(action: .translation, title: "Translation Available", compactTitle: "Translation…", symbol: "translate")),
        ("translating", URLStatusItem(action: .translation, title: "Translating…", symbol: "translate", isBusy: true)),
        ("translated", URLStatusItem(action: .translation, title: "Translated", symbol: "translate")),
        ("error", URLStatusItem(action: .translation, title: "Translation Available", compactTitle: "Translation…", symbol: "exclamationmark.triangle")),
    ]

    static func makeScene(width: CGFloat, delegate: RecordingDelegate) -> (SidebarContext, RenderScene, BrowserModel) {
        let model = Synthetic.model(), state = model.windows[0]
        let context = SidebarContext(model: model, windowID: state.id)
        var options = RenderScene.Options(); options.size = CGSize(width: 900, height: 700)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        context.sidebarWidthOverride = width
        let space = model.spaces[0]
        if let tab = space.today.first?.tab ?? space.pinned.first?.tab { model.selectNode(windowID: state.id, spaceID: space.id, nodeID: tab.id) }
        return (context, scene, model)
    }

    static func run() {
        let check = Checks.check
        let delegate = RecordingDelegate()
        let (context, scene, model) = makeScene(width: 228, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar
        func settle() { scene.needsLayout = true; OffscreenRenderer.settle(scene, runLoop: 0.01) }
        settle()
        let favoritesBefore = sidebar.chromeGeometry.favorites
        check(!sidebar.urlStatusState.shown && favoritesBefore.minY == FavoritesMetrics.sectionTop,
              "S-US1 no offer: no status button; Favorites at y \(FavoritesMetrics.sectionTop)")
        var rows: [String] = [], ok = true
        for w: CGFloat in [228, 300] {
            context.sidebarWidthOverride = w
            for (name, item) in states {
                context.urlStatus = item; settle()
                let s = sidebar.urlStatusState
                let expected = CGRect(x: 8, y: 88, width: w - 16, height: 28)
                let good = s.shown && s.frame == expected && s.title == item.title
                    && sidebar.chromeGeometry.favorites.minY == FavoritesMetrics.sectionTop + 34
                ok = ok && good
                rows.append("\(Int(w)) \(name): \(s.frame) \"\(s.title)\"\(good ? "" : " ✗")")
            }
        }
        check(ok, "S-US1 frame [8, 88, W − 16, 28], four titles, Favorites pushed down 34 pt (\(rows.joined(separator: "; ")))")
        context.sidebarWidthOverride = 216; context.urlStatus = states[0].1; settle()
        let narrow = sidebar.urlStatusState
        context.sidebarWidthOverride = 217; settle()
        let wide = sidebar.urlStatusState
        check(narrow.frame.width == 200 && narrow.title == "Translation…" && wide.title == "Translation Available",
              "S-US1 PG-7.3 width rule: \"Translation…\" at a 200 pt button (W 216), \"Translation Available\" at 201 pt")

        context.sidebarWidthOverride = 228; settle()
        delegate.log = []
        sidebar.pressURLStatus()
        let anchor = sidebar.convert(sidebar.urlStatusState.frame, to: nil)
        let sent: Bool
        if case .showTranslation(let a)? = delegate.log.last { sent = a == anchor } else { sent = false }
        check(sent, "S-US1 a click sends .showTranslation(anchor:) with the button frame in window coordinates (\(anchor); got \(delegate.log.last.map { "\($0)" } ?? "none"))")

        // Pixels: the button and the URL field share one fill.
        let image = OffscreenRenderer().render(scene, scale: 1)
        let button = sidebar.urlStatusState.frame
        let field = sidebar.chromeGeometry.urlField
        let a = pixel(image, x: Int(button.minX + 4), y: Int(button.midY)), b = pixel(image, x: Int(field.minX + 4), y: Int(field.midY))
        check(!a.isEmpty && zip(a, b).allSatisfy { abs($0 - $1) <= 2 }, "S-US1 fill equals the URL field fill (\(a) vs \(b))")

        // Hidden rules: the content toolbar replaces the URL field.
        model.windows[0].showsToolbar = true; settle()
        check(!sidebar.urlStatusState.shown, "S-US1 hidden while the content toolbar shows")
        model.windows[0].showsToolbar = false; settle()
        check(sidebar.urlStatusState.shown, "S-US1 shows again without the toolbar")

        // Motion: the push-down slides with Motion.rowStructure; Reduce Motion does not slide.
        SidebarDiagnostics.forceAnimations = true
        defer { SidebarDiagnostics.forceAnimations = false; Motion.reduceMotionOverride = nil }
        context.urlStatus = nil; settle()
        let hide = sidebar.urlStatusAnimations["favorites"] as? CABasicAnimation
        context.urlStatus = states[0].1; settle()
        let show = sidebar.urlStatusAnimations["favorites"] as? CABasicAnimation
        check(hide?.duration == Motion.rowStructure && show?.duration == Motion.rowStructure
              && (show?.toValue as? CGPoint).map { abs($0.y - (show?.fromValue as? CGPoint ?? .zero).y) == 34 } == true,
              "S-US1 the push-down slides 34 pt over \(Motion.rowStructure) s both ways")
        Motion.reduceMotionOverride = true
        context.urlStatus = nil; settle()
        check(sidebar.urlStatusAnimations.isEmpty && sidebar.chromeGeometry.favorites.minY == FavoritesMetrics.sectionTop,
              "S-US1 Reduce Motion: Favorites move without a slide")
        context.urlStatus = nil
    }

    static func render(_ args: [String]) throws {
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out DIR required") }
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for w: CGFloat in [228, 300] {
            for (name, item) in [("none", nil)] + states.map({ ($0.0, Optional($0.1)) }) {
                let (context, scene, _) = makeScene(width: w, delegate: RecordingDelegate())
                context.urlStatus = item
                let host = OffscreenRenderer.host(scene, scale: scale)
                scene.needsLayout = true; OffscreenRenderer.settle(scene, runLoop: 0.01)
                let full = OffscreenRenderer().render(scene, scale: scale)
                let crop = full.cropping(to: CGRect(x: 0, y: 0, width: Int(w * scale), height: Int(260 * scale))) ?? full
                let url = URL(fileURLWithPath: out).appendingPathComponent("url-status-\(Int(w))-\(name).png")
                OffscreenRenderer.writePNG(crop, to: url); print("rendered \(url.path)")
                host.contentView = nil; host.close()
            }
        }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        guard let data = ctx.data else { return [] }
        let p = data.assumingMemoryBound(to: UInt8.self)
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }
}
