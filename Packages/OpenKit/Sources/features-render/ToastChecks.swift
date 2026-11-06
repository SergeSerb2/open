import AppKit
import OpenDesign
import OpenFeatures
import OpenModel
import OpenSidebar

/// A toast clock the checks drive: deadlines fire only when a check advances time (R-T3, R-T4).
@MainActor
final class FakeToastClock: ToastClock {
    var now: CFTimeInterval = 1000
    private var items: [Int: (at: CFTimeInterval, work: @MainActor () -> Void)] = [:]
    private var nextID = 0
    var pendingCount: Int { items.count }
    var deadlines: [CFTimeInterval] { items.values.map(\.at).sorted() }
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ToastTimer {
        nextID += 1; let id = nextID
        items[id] = (now + delay, work)
        return ToastTimer { [weak self] in MainActor.assumeIsolated { _ = self?.items.removeValue(forKey: id) } }
    }
    /// Runs every deadline up to `now + seconds` in time order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = items.min(by: { $0.value.at < $1.value.at }), next.value.at <= end {
            items[next.key] = nil; now = next.value.at; next.value.work()
        }
        now = end
    }
}

/// sRGB RGBA8 pixels of a render (rows top to bottom).
struct ToastPixels {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        bytes = data
    }
    func at(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x) * 4; return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])] }
}

/// Page-platform toasts (plan §8.1 R-T1–R-T7) through the real `BrowserWindowController`,
/// `ToastCenter`, `ToastView` and the offscreen renderer.
@MainActor
enum ToastChecks {
    static func controller(_ model: BrowserModel = FeatureCLI.synthetic(), size: CGSize = CGSize(width: 2216, height: 1394)) -> BrowserWindowController {
        let c = BrowserWindowController(model: model, windowID: model.windows[0].id, factory: FakeWebContentHostFactory(), size: size, defaults: FeatureCLI.defaults())
        OffscreenRenderer.settle(c.contentView, runLoop: 0.01)
        return c
    }
    static func pump(_ view: NSView) { OffscreenRenderer.settle(view, runLoop: 0.01) }
    /// A toast's frame in the window content (flipped, top-left origin).
    static func frame(_ view: ToastView, in root: NSView) -> CGRect { root.convert(view.bounds, from: view) }
    static func hexes(_ c: (top: RGBA, bottom: RGBA)) -> String { "\(hex(c.top)) → \(hex(c.bottom))" }
    static func hex(_ c: RGBA) -> String { String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded())) }
    static func channels(_ c: RGBA) -> [Double] { [c.red * 255, c.green * 255, c.blue * 255] }
    /// Expected gradient color at pixel row `row` (center) of a toast `height` tall.
    static func gradient(_ fill: (top: RGBA, bottom: RGBA), row: Int, height: CGFloat) -> [Double] {
        let t = (Double(row) + 0.5) / Double(height)
        return zip(channels(fill.top), channels(fill.bottom)).map { $0 + ($1 - $0) * t }
    }
    static func within(_ actual: [Int], _ expected: [Double], _ limit: Double = 1) -> Bool {
        zip(actual, expected).allSatisfy { abs(Double($0) - $1.rounded()) <= limit }
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        let savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = savedAppearance; Motion.reduceMotionOverride = nil }
        try plainToast(check)
        try shareToast(check)
        stacking(check)
        lifetimes(check)
        anchors(check)
        themes(check)
        motion(check)
    }

    // MARK: R-T1

    private static func plainToast(_ check: (Bool, String) -> Void) throws {
        let c = controller(); defer { c.container.closeAll(); c.window?.close() }
        c.toasts.show(ToastContent(title: "110%", coalescingKey: "zoom")); pump(c.contentView)
        guard let view = c.toasts.views.first else { check(false, "R-T1 a plain toast shows"); return }
        let f = frame(view, in: c.contentView), panel = c.container.frame, style = view.style
        let placed = f.maxX == panel.maxX - 10 && f.minY == panel.minY + 8 && f.height == 42
        check(placed && abs(f.width - 60) <= 2 && !c.toastOverlay.isHidden,
              String(format: "R-T1 plain toast frame [panel.maxX − 10 − w, panel.minY + 8, w, 42] = [%.0f, %.0f, %.0f, %.0f] (panel %.0f…%.0f; PG-1.2 measured 60 × 42)",
                     f.minX, f.minY, f.width, f.height, panel.minX, panel.maxX))
        check(view.cornerRadius == 11 && view.cornerCurve == .continuous && Typography.toast == FontToken(14, .medium)
              && view.titleFont == Typography.toast.font && view.titleColor == RGBA.white(1),
              "R-T1 radius 11 continuous, title 14 pt Medium, opaque white (hint fit, PG-1.6)")
        // Pixels: render the window content and probe the fill column at x + 6 (clear of the text and corners).
        let image = OffscreenRenderer().render(c.contentView, scale: 1)
        c.window?.contentView = c.contentView
        let pixels = ToastPixels(image), x = Int(f.minX) + 6
        let topRow = 3, bottomRow = Int(f.height) - 4
        let top = pixels.at(x, Int(f.minY) + topRow), bottom = pixels.at(x, Int(f.minY) + bottomRow)
        let expectTop = gradient(style.toastFill, row: topRow, height: f.height), expectBottom = gradient(style.toastFill, row: bottomRow, height: f.height)
        check(within(top, expectTop) && within(bottom, expectBottom),
              "R-T1 rendered fill rows 3 and h − 4 follow \(hexes(style.toastFill)) within 1 unit: top \(top) vs \(expectTop.map { Int($0.rounded()) }), bottom \(bottom) vs \(expectBottom.map { Int($0.rounded()) })")
        let box = view.titleFrame.offsetBy(dx: f.minX, dy: f.minY)
        var brightest = 0
        for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) { brightest = max(brightest, pixels.at(x, y).min() ?? 0) } }
        check(brightest >= 245, "R-T1 title ink reaches white (brightest channel minimum \(brightest) ≥ 245)")
        // The body passes clicks to the page; the toast is never key or first responder.
        let center = c.contentView.convert(CGPoint(x: f.midX, y: f.midY), to: c.contentView.superview)
        let hit = c.contentView.hitTest(center)
        check(!(hit is ToastView) && hit?.isDescendant(of: c.toastOverlay) != true && !view.acceptsFirstResponder,
              "R-T1 a click on the toast body reaches the page (hit \(hit.map { String(describing: type(of: $0)) } ?? "nil"))")
    }

    // MARK: R-T2

    private static func shareToast(_ check: (Bool, String) -> Void) throws {
        let c = controller(); defer { c.container.closeAll(); c.window?.close() }
        var shared = 0
        c.toasts.show(ToastContent(title: URLCleaner.plainTitle, accessory: ToastContent.shareButton)) { _ in shared += 1 }; pump(c.contentView)
        guard let view = c.toasts.views.first, let button = view.accessoryButton else { check(false, "R-T2 a toast with Share shows its button"); return }
        let f = frame(view, in: c.contentView), w = f.width
        check(f.height == 46 && button.frame == CGRect(x: w - 42, y: 10, width: 32, height: 27) && abs(w - 192) <= 4
              && button.accessibilityLabel() == "Share" && button.symbolName == "square.and.arrow.up",
              String(format: "R-T2 copy toast 46 tall, %.0f wide (PG-1.2 192), Share button [w − 42, 10, 32, 27] = [%.0f, %.0f, %.0f, %.0f]",
                     w, button.frame.minX, button.frame.minY, button.frame.width, button.frame.height))
        let center = c.contentView.convert(CGPoint(x: f.minX + button.frame.midX, y: f.minY + button.frame.midY), to: c.contentView.superview)
        let hit = c.contentView.hitTest(center)
        check(hit === button, "R-T2 a click on the Share button reaches the button")
        let image = OffscreenRenderer().render(c.contentView, scale: 1)
        c.window?.contentView = c.contentView
        let pixels = ToastPixels(image), probe = (x: Int(f.minX + button.frame.minX) + 3, row: Int(button.frame.minY) + 3)
        let base = gradient(view.style.toastFill, row: probe.row, height: f.height)
        let expected = base.map { $0 + (255 - $0) * ToastMetrics.accessoryFillAlpha }
        let actual = pixels.at(probe.x, Int(f.minY) + probe.row)
        check(within(actual, expected, 2), "R-T2 button plate is white 0.22 over the fill (PG-1.3): \(actual) vs \(expected.map { Int($0.rounded()) })")
        check(c.toasts.performAccessory(at: 0) && shared == 1, "R-T2 toast-action clicks the real Share button")
    }

    // MARK: R-T3

    private static func stacking(_ check: (Bool, String) -> Void) {
        let c = controller(); defer { c.container.closeAll(); c.window?.close() }
        let clock = FakeToastClock(); c.toasts.clock = clock; c.toasts.animates = { true }
        for title in ["90%", "100%", "110%", "125%"] { c.toasts.show(ToastContent(title: title, coalescingKey: "zoom")) }
        pump(c.contentView)
        let snaps = c.toasts.snapshots, views = c.toasts.views
        let sameAnchor = Set(views.map { frame($0, in: c.contentView).maxX }).count == 1 && Set(views.map { frame($0, in: c.contentView).minY }).count == 1
        check(views.count == 4 && c.toastOverlay.subviews.last === views[0] && snaps[0].content.title == "125%" && !snaps[0].isExiting
              && snaps.dropFirst().allSatisfy(\.isExiting) && sameAnchor && c.toasts.visible.map(\.title) == ["125%"],
              "R-T3 four toasts overlap at one anchor: the newest (125%) on top, three exiting (PG-1.8)")
        c.toasts.show(ToastContent(title: "150%", coalescingKey: "zoom"))
        let titles = c.toasts.snapshots.map(\.content.title)
        check(c.toasts.views.count == 4 && titles == ["150%", "125%", "110%", "100%"],
              "R-T3 a fifth toast removes the oldest view (\(titles.joined(separator: ", ")))")
        clock.advance(by: Motion.toastOut)
        check(c.toasts.views.count == 1 && c.toastOverlay.subviews.count == 1, "R-T3 exiting toasts leave after the exit (\(Motion.toastOut) s)")
    }

    // MARK: R-T4

    private static func lifetimes(_ check: (Bool, String) -> Void) {
        let c = controller(); defer { c.container.closeAll(); c.window?.close() }
        let clock = FakeToastClock(); c.toasts.clock = clock
        func deadline() -> Double? { c.toasts.snapshots.first.flatMap { s in s.deadline.map { $0 - clock.now } } }
        c.toasts.show(ToastContent(title: "110%")); let plain = deadline()
        c.toasts.show(ToastContent(title: URLCleaner.plainTitle, accessory: ToastContent.shareButton)); let share = deadline()
        c.toasts.show(.undo("Peek closed", lifetime: 5)); let undo = deadline()
        check(plain == 3.0 && share == 5.0 && undo == 5.0 && clock.pendingCount == 1,
              "R-T4 scheduled lifetimes: plain \(plain ?? -1) s (3.0), with a button \(share ?? -1) s (5.0, PG-14), undo \(undo ?? -1) s (5.0); older toasts left at once")
        clock.advance(by: 4.99)
        let stillThere = c.toasts.visible.count == 1
        clock.advance(by: 0.02)
        check(stillThere && c.toasts.visible.isEmpty && c.toasts.views.isEmpty && c.toastOverlay.isHidden && clock.pendingCount == 0,
              "R-T4 a toast leaves at its deadline; then nothing is scheduled and the overlay hides")
        // Hover pauses; leaving restarts with 1.5 s left.
        c.toasts.show(ToastContent(title: "Copied Image"))
        guard let view = c.toasts.views.first, let window = c.window else { check(false, "R-T4 hover toast"); return }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        view.mouseEntered(with: event(.mouseEntered))
        let paused = deadline() == nil && clock.pendingCount == 0 && c.toasts.snapshots.first?.isHovered == true
        clock.advance(by: 30)
        let kept = c.toasts.visible.count == 1
        view.mouseExited(with: event(.mouseExited))
        let resumed = deadline()
        clock.advance(by: 1.49); let beforeResume = c.toasts.visible.count == 1
        clock.advance(by: 0.02)
        check(paused && kept && resumed == ToastMetrics.hoverResumeLifetime && beforeResume && c.toasts.visible.isEmpty,
              "R-T4 the pointer over a toast pauses it (30 s kept); leaving restarts it with \(resumed ?? -1) s (1.5)")
        // Sticky stays until dismissed; update keeps the view; hold pauses like hover.
        let sticky = c.toasts.show(ToastContent(title: "Recording Trace…", subtitle: "0:01", accessory: .button(symbol: "stop.fill", accessibilityLabel: "Stop"), isSticky: true))
        let stickyView = c.toasts.views.first
        clock.advance(by: 600)
        sticky.update(ToastContent(title: "Recording Trace…", subtitle: "10:01", accessory: .button(symbol: "stop.fill", accessibilityLabel: "Stop"), isSticky: true))
        let updated = c.toasts.views.first === stickyView && c.toasts.visible.first?.subtitle == "10:01" && stickyView?.frame.height == 60
        sticky.dismiss()
        check(updated && !sticky.isVisible && c.toasts.views.isEmpty && clock.pendingCount == 0,
              "R-T4 a sticky toast stays (600 s), updates in place (two lines, 60 tall), and leaves on dismiss")
        let held = c.toasts.show(ToastContent(title: URLCleaner.cleanedTitle, accessory: ToastContent.shareButton))
        held.hold(true); clock.advance(by: 30); let heldKept = held.isVisible
        held.hold(false); let heldResume = deadline()
        clock.advance(by: 1.51)
        check(heldKept && heldResume == ToastMetrics.hoverResumeLifetime && !held.isVisible,
              "R-T4 hold (share picker open) keeps a toast; release restarts it with 1.5 s")
    }

    // MARK: R-T5

    private static func anchors(_ check: (Bool, String) -> Void) {
        let model = FeatureCLI.synthetic(), space = model.spaces[0]
        model.selectNode(windowID: model.windows[0].id, spaceID: space.id, nodeID: space.pinned[0].tab!.id)
        let c = controller(model); defer { c.container.closeAll(); c.window?.close() }
        c.performCommand("add-split-view"); pump(c.contentView)
        c.toasts.show(ToastContent(title: "Folder deleted"))
        guard let view = c.toasts.views.first else { check(false, "R-T5 split toast"); return }
        var f = frame(view, in: c.contentView), panel = c.container.frame
        let split = c.container.slots.count == 2 && f.maxX == panel.maxX - 10 && f.minY == panel.minY + 8
        check(split, String(format: "R-T5 Split View: the toast anchors at the whole panel's top-right (lead Q10), x %.0f = %.0f − 10", f.maxX, panel.maxX))
        c.toggleSidebar(); pump(c.contentView)
        f = frame(view, in: c.contentView); panel = c.container.frame
        check(c.context.window?.sidebarMode == .hidden && f.maxX == panel.maxX - 10 && f.minY == panel.minY + 8 && panel.minX < 228,
              String(format: "R-T5 hidden sidebar: the shown toast follows the panel to [%.0f, %.0f] (panel x %.0f)", f.minX, f.minY, panel.minX))
        c.isPageFullscreen = true; pump(c.contentView)
        f = frame(view, in: c.contentView)
        let root = c.contentView.bounds
        check(f.maxX == root.maxX - 10 && f.minY == root.minY + 8, "R-T5 HTML fullscreen: the anchor is the window content")
        c.isPageFullscreen = false
        // Little Open: its own center at the page view's top-right.
        let factory = FakeWebContentHostFactory(), littleModel = FeatureCLI.synthetic()
        let little = LittleOpenCoordinator(model: littleModel, archiveSink: nil) { profile in factory.makeHost(tabID: ItemID(), profileID: profile, url: nil)! as! FakeWebContentHost }
        little.presentWindows = false; little.defaults = FeatureCLI.defaults()
        little.open(url: URL(string: "https://example.com")!, profileHint: nil)
        defer { little.closeAll() }
        guard let lc = little.sessions.first.flatMap({ little.controllers[$0.id] }) else { check(false, "R-T5 Little Open session"); return }
        pump(lc.contentView)
        let saved = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        }
        lc.titleBar.copyButton.performClick(nil)
        check(NSPasteboard.general.string(forType: .string) == "https://example.com" && !lc.contentView.subviews.contains { $0 is ToastOverlayView },
              "R-T5 Little Open copy uses the pasteboard without a library toast (Step 6a)")
    }

    // MARK: R-T6

    private static func themes(_ check: (Bool, String) -> Void) {
        let presets = SpaceStylePresets.all
        let light = SpaceThemeStyle(style: presets.first { $0.name == "Pastel 1" }!.style, system: .dark)
        let dark = SpaceThemeStyle(style: presets.first { $0.name == "Drab 1" }!.style, system: .dark)
        let defaultDark = SpaceThemeStyle.defaultTheme(system: .dark), defaultLight = SpaceThemeStyle.defaultTheme(system: .light)
        let fills = [light, dark, defaultDark, defaultLight].map { hexes($0.toastFill) }
        check(light.contentAppearance == .light && dark.contentAppearance == .dark && Set(fills).count == 4
              && light.toastText == .white(1) && dark.toastText == .white(1) && defaultDark.toastText == .white(1),
              "R-T6 fills differ by Space (light content \(fills[0]), dark content \(fills[1]), default \(fills[2])); text white")
        check(defaultDark.toastFill.top == RGBA(hex: 0x442B68) && defaultDark.toastFill.bottom == RGBA(hex: 0x332350)
              && defaultLight.toastFill.top == RGBA(hex: 0xD0C6F0) && defaultLight.toastFill.bottom == RGBA(hex: 0xC2B4E9)
              && defaultLight.toastText == RGBA(hex: 0x0D0D10),
              "R-T6 default theme: dark \(fills[2]) white text (A0440); macOS Light \(fills[3]) dark text (S2 20/0048)")
        // The live window reads its focused Space: a themed Space changes the next toast, and the hint reads the same rule.
        let model = FeatureCLI.synthetic()
        model.spaces[0].theme.style = presets.first { $0.name == "Drab 1" }!.style
        let c = controller(model); defer { c.container.closeAll(); c.window?.close() }
        c.toasts.show(ToastContent(title: "Cleared Tabs")); pump(c.contentView)
        let expected = c.context.style(for: model.spaces[0])
        let image = OffscreenRenderer().render(c.contentView, scale: 1)
        c.window?.contentView = c.contentView
        guard let view = c.toasts.views.first else { check(false, "R-T6 themed toast"); return }
        let f = frame(view, in: c.contentView), pixels = ToastPixels(image)
        let row = 3, actual = pixels.at(Int(f.minX) + 6, Int(f.minY) + row)
        check(view.style == expected && expected.lightPalette != nil && within(actual, gradient(expected.toastFill, row: row, height: f.height)),
              "R-T6 a themed Space's toast renders its fill \(hexes(expected.toastFill)) (row 3 \(actual))")
        // The first-hide hint reads the same rule: render it on the macOS Light default theme.
        let hint = HintToastView(keys: "⌘S", style: defaultLight)
        let hintPixels = ToastPixels(OffscreenRenderer().render(hint, scale: 1))
        let hintFill = hintPixels.at(6, 3), hintExpected = gradient(defaultLight.toastFill, row: 3, height: HintToastMetrics.height)
        check(within(hintFill, hintExpected), "R-T6 the first-hide hint reads the same fill rule (light default row 3 \(hintFill) vs \(hintExpected.map { Int($0.rounded()) }))")
    }

    // MARK: R-T7

    private static func motion(_ check: (Bool, String) -> Void) {
        let c = controller(); defer { c.container.closeAll(); c.window?.close() }
        let clock = FakeToastClock(); c.toasts.clock = clock; c.toasts.animates = { true }
        c.toasts.reducesMotion = { false }
        let normal = c.toasts.show(ToastContent(title: "110%"))
        let springIn = c.toasts.lastAnimations["in.transform"] as? CASpringAnimation
        normal.dismiss()
        let shrink = c.toasts.lastAnimations["out.transform"] as? CABasicAnimation
        let start = (springIn?.fromValue as? NSValue)?.caTransform3DValue
        check(springIn != nil && abs((start?.m11 ?? 0) - Motion.toastInScale) < 1e-9 && shrink?.duration == Motion.toastOut
              && c.toasts.lastAnimations["in.opacity"]?.duration == Motion.toastFadeIn,
              "R-T7 normal motion: grows from \(Motion.toastInScale) at the top center with the toastIn spring, fades in \(Motion.toastFadeIn) s, shrinks out \(Motion.toastOut) s (PG-14)")
        clock.advance(by: 1)
        c.toasts.reducesMotion = { true }
        let reduced = c.toasts.show(ToastContent(title: "125%"))
        let inKeys = Set(c.toasts.lastAnimations.keys)
        reduced.dismiss()
        let keys = Set(c.toasts.lastAnimations.keys)
        check(inKeys == ["in.opacity"] && keys == ["in.opacity", "out.opacity"],
              "R-T7 Reduce Motion: fades only, no scale (animations \(keys.sorted().joined(separator: ", ")))")
        // The scale keeps the top edge and the horizontal center in place (PG-14 "top center").
        let size = CGSize(width: 200, height: 46)
        let t = ToastCenter.topCenterScale(0.3, size: size)
        let topCenter = CGPoint(x: 100, y: 0).applying(CATransform3DGetAffineTransform(t))
        let corner = CGPoint(x: 0, y: 46).applying(CATransform3DGetAffineTransform(t))
        // On screen: a toast frozen at the start scale draws its fill at the top center of its frame
        // and leaves the page visible at its bottom.
        let r = controller(); defer { r.container.closeAll(); r.window?.close() }
        let empty = ToastPixels(OffscreenRenderer().render(r.contentView, scale: 1)); r.window?.contentView = r.contentView
        r.toasts.show(ToastContent(title: "110%")); pump(r.contentView)
        guard let view = r.toasts.views.first, let layer = view.layer else { check(false, "R-T7 frozen toast"); return }
        let f = frame(view, in: r.contentView)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = ToastCenter.topCenterScale(Motion.toastInScale, size: view.bounds.size)
        CATransaction.commit()
        let frozen = ToastPixels(OffscreenRenderer().render(r.contentView, scale: 1)); r.window?.contentView = r.contentView
        // x − 7 from the center maps to x ≈ 6.7 in the toast (fill, no text); row 3 is inside the 12.6 pt scaled height.
        let topProbe = (x: Int(f.midX) - 7, y: Int(f.minY) + 3), bottomProbe = (x: Int(f.midX), y: Int(f.maxY) - 3)
        let fillHere = frozen.at(topProbe.x, topProbe.y), pageThere = frozen.at(bottomProbe.x, bottomProbe.y)
        check(abs(topCenter.x - 100) < 1e-9 && abs(topCenter.y) < 1e-9 && abs(corner.x - 70) < 1e-9 && abs(corner.y - 13.8) < 1e-9
              && within(fillHere, gradient(view.style.toastFill, row: 10, height: f.height), 6) && pageThere == empty.at(bottomProbe.x, bottomProbe.y),
              "R-T7 the appear and exit scale pins the top center of the toast (rendered: fill \(fillHere) at the top center, page \(pageThere) at the bottom)")
    }
}

/// `features-render toast`: renders for `docs/plans/page-platform/` (our own renders only).
@MainActor
enum ToastScene {
    static func run(_ args: [String], size: CGSize, scale: CGFloat) async throws {
        let variant = RenderCLI.value(args, "--variant") ?? "copy"
        NSApp.appearance = NSAppearance(named: variant == "light" ? .aqua : .darkAqua)
        let model = FeatureCLI.synthetic()
        if variant == "themed" { model.spaces[0].theme.style = SpaceStylePresets.all.first { $0.name == "Drab 4" }!.style }
        if variant == "split", let space = model.spaces.first {
            let tabs = space.today.compactMap(\.tab)
            _ = model.makeSplit(tabIDs: Array(tabs.prefix(2)).map(\.id))
            if let split = space.today.compactMap(\.split).first { model.selectNode(windowID: model.windows[0].id, spaceID: space.id, nodeID: split.id) }
        }
        let c = ToastChecks.controller(model, size: size)
        if variant == "hidden" { c.toggleSidebar() }
        ToastChecks.pump(c.contentView)
        switch variant {
        case "zoom": c.toasts.show(ToastContent(title: "110%", coalescingKey: "zoom"))
        case "two-line": c.toasts.show(ToastContent(title: URLCleaner.plainTitle, subtitle: "Share a link directly to this text instead?",
                                                   accessory: .button(symbol: "quote.bubble.fill", accessibilityLabel: "Copy Quote Link")))
        case "keycaps": c.toasts.show(ToastContent(title: "and drag your mouse to capture any time.", accessory: .keycaps(["⌘", "⇧"])))
        case "undo", "split", "hidden": c.toasts.show(.undo("Folder deleted", lifetime: 5))
        default: c.toasts.show(ToastContent(title: variant == "copy" ? URLCleaner.cleanedTitle : URLCleaner.plainTitle, accessory: ToastContent.shareButton))
        }
        ToastChecks.pump(c.contentView)
        guard args.contains("--crop") else { try FeatureCLI.output(c.contentView, args: args, scale: scale); c.container.closeAll(); return }
        // `--crop`: only the panel's top-right corner, 560 × 120 pt (keeps committed renders small).
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out required") }
        let image = OffscreenRenderer().render(c.contentView, scale: scale)
        let panel = c.container.frame
        let crop = CGRect(x: (panel.maxX + 10 - 560) * scale, y: 0, width: 560 * scale, height: 120 * scale)
        guard let cropped = image.cropping(to: crop) else { throw CLIError(description: "crop failed") }
        OffscreenRenderer.writePNG(cropped, to: URL(fileURLWithPath: out)); print("rendered \(out)")
        c.container.closeAll()
    }
}
