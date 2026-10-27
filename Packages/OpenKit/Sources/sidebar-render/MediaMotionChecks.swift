import AppKit
import OpenDesign
import OpenMedia
import OpenModel
import OpenSidebar
import OpenWeb

/// Native events through a real composed sidebar; all windows remain offscreen.
/// Inspect actual CA start/presentation values, rather than merely checking keys.
@MainActor enum MediaMotionChecks {
    static func run() {
        print("MC15 motion regression: anchored starts, interruption continuity and clipped rows")
        for count in [1, 3] { run(cardCount: count) }
    }

    private static func run(cardCount: Int) {
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let space = model.spaces.first else { return }
        window.sidebarWidth = 228; space.theme = SpaceTheme()
        let context = SidebarContext(model: model, windowID: window.id)
        context.systemAppearance = .dark
        let store = MediaSourceStore(); context.media = store
        let delegate = MediaHarnessDelegate(context: context)
        for index in 0..<cardCount {
            let tab = model.newTab(in: space.id, url: URL(string: "https://media.example.test/motion/\(index)")!, title: "Synthetic motion title \(index)")
            delegate.add(tab: tab, state: WebMediaState(playback: .playing, isControllable: true,
                hasVideo: true, actions: [.play, .pause], volume: 0.5))
        }
        let oldForce = SidebarDiagnostics.forceAnimations, oldReduce = SidebarDiagnostics.mediaReduceMotionOverride
        SidebarDiagnostics.forceAnimations = true; SidebarDiagnostics.mediaReduceMotionOverride = false
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 2)
        host.orderBack(nil)
        defer {
            host.orderOut(nil); host.contentView = nil; host.close()
            SidebarDiagnostics.forceAnimations = oldForce; SidebarDiagnostics.mediaReduceMotionOverride = oldReduce
        }
        let controls = scene.sidebar.mediaControls
        guard let pager = MediaChecks.descendants(scene.sidebar).first(where: { String(describing: type(of: $0)) == "SpacePagerView" }),
              let card = controls.cards.first else { Checks.check(false, "MC15 motion fixture exists"); return }
        func layout() { scene.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush() }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)); layout() }
        func event(_ type: NSEvent.EventType, _ view: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        func enter() { controls.mouseEntered(with: event(.mouseMoved, controls)); layout() }
        func leave() { controls.mouseExited(with: event(.mouseMoved, controls)); layout() }
        func point(_ layer: CALayer?) -> CGPoint { layer?.presentation()?.position ?? layer?.position ?? .zero }
        func size(_ layer: CALayer?) -> CGSize { layer?.presentation()?.bounds.size ?? layer?.bounds.size ?? .zero }
        func opacity(_ layer: CALayer?) -> Float { layer?.presentation()?.opacity ?? layer?.opacity ?? 0 }
        func fromPoint(_ layer: CALayer?, _ key: String) -> CGPoint? {
            ((layer?.animation(forKey: key) as? CABasicAnimation)?.fromValue as? NSValue)?.pointValue
        }
        func fromSize(_ layer: CALayer?, _ key: String) -> CGSize? {
            ((layer?.animation(forKey: key) as? CABasicAnimation)?.fromValue as? NSValue)?.sizeValue
        }
        func same(_ a: CGPoint?, _ b: CGPoint, tolerance: CGFloat = 1) -> Bool {
            a.map { abs($0.x-b.x) <= tolerance && abs($0.y-b.y) <= tolerance } ?? false
        }
        func same(_ a: CGSize?, _ b: CGSize, tolerance: CGFloat = 1) -> Bool {
            a.map { abs($0.width-b.width) <= tolerance && abs($0.height-b.height) <= tolerance } ?? false
        }
        func rowsClear(_ label: String) {
            for (index, c) in controls.cards.enumerated() {
                let views = MediaChecks.descendants(c)
                guard let title = views.first(where: { $0.identifier?.rawValue == "media.titleRow" }),
                      let play = c.control(named: "play")?.view, let row = play.superview else { continue }
                let titleFrame = title.layer?.presentation()?.frame ?? title.frame
                let controlFrame = row.layer?.presentation()?.frame ?? row.frame
                if !title.isHidden && opacity(title.layer) > 0.02 {
                    Checks.check(titleFrame.maxY <= controlFrame.minY + 1,
                        "MC15 F3 \(cardCount) cards \(label), card \(index): title never overlaps controls (\(titleFrame.maxY), \(controlFrame.minY))")
                }
                if let drawer = views.first(where: { $0.identifier?.rawValue == "media.drawerRow" }), !drawer.isHidden {
                    let drawerFrame = drawer.layer?.presentation()?.frame ?? drawer.frame
                    Checks.check(drawerFrame.maxY <= controlFrame.minY + 1,
                        "MC15 F3 \(label), card \(index): drawer never overlaps controls")
                }
            }
        }
        wait(0.8)
        Checks.check(host.frame.maxX < 0 && !host.isKeyWindow, "MC15 motion host is offscreen and non-key")
        if cardCount == 1, let play = card.control(named: "play")?.view {
            let native = MediaChecks.descendants(play).compactMap { $0 as? NSImageView }.first
            Checks.check(native?.image === Glyph.mediaPause.image && native?.imageScaling == .scaleNone &&
                SidebarDiagnostics.mediaReduceMotionOverride == false, "MC15 F7 Reduce Motion OFF uses the shipping native pause image")
            if let native, let bitmap = native.bitmapImageRepForCachingDisplay(in: native.bounds) {
                native.cacheDisplay(in: native.bounds, to: bitmap)
                var ink = 0
                for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 } }
                Checks.check(ink > 0, "MC15 F7 live native pause path draws ink without the layer cloner")
            } else { Checks.check(false, "MC15 F7 native pause bitmap exists") }
            host.sendEvent(event(.leftMouseDown, play)); host.sendEvent(event(.leftMouseUp, play)); wait(0.02)
            Checks.check(native?.image === Glyph.mediaPlay.image && card.source.playback == .paused,
                "MC15 F7 native events replace pause with play with Reduce Motion OFF")
            host.sendEvent(event(.leftMouseDown, play)); host.sendEvent(event(.leftMouseUp, play)); wait(0.8)
        }
        let oldPager = point(pager.layer), oldContainer = point(controls.layer)
        enter()
        Checks.check(same(fromPoint(pager.layer, "media.containerMove"), oldPager, tolerance: 0.5) &&
            same(fromPoint(controls.layer, "media.containerMove"), oldContainer, tolerance: 0.5),
            "MC15 F1 \(cardCount) cards: height animation starts at on-screen positions, including non-centered anchors")
        wait(0.016)
        let pagerPresentation = pager.layer?.presentation()
        Checks.check(pagerPresentation != nil && abs(point(pager.layer).x-pager.frame.minX) <= 1 &&
            abs((pagerPresentation?.frame.minY ?? -1)-pager.frame.minY) <= 1,
            "MC15 F1 \(cardCount) cards: pager stays at its on-screen x/y 16 ms after hover")
        rowsClear("expand +16ms"); wait(0.034); rowsClear("expand +50ms"); wait(0.75)
        leave()
        let deadline = CACurrentMediaTime() + 1
        while controls.isExpanded && CACurrentMediaTime() < deadline { wait(0.002) }
        Checks.check(!controls.isExpanded && controls.layer?.animation(forKey: "media.containerResize") != nil,
            "MC15 F2 \(cardCount) cards: real delayed collapse starts")
        wait(0.05); rowsClear("collapse +50ms")
        let containerSize = size(controls.layer), pagerSize = size(pager.layer)
        let containerPosition = point(controls.layer), pagerPosition = point(pager.layer)
        let cardSize = size(card.layer), contentSize = size(card.contentView.layer)
        let cardPosition = point(card.layer), cardOpacity = opacity(card.layer)
        let title = MediaChecks.descendants(card).first { $0.identifier?.rawValue == "media.titleRow" }
        let titleOpacity = opacity(title?.layer)
        let shadowHeight = card.shadowLayer.presentation()?.shadowPath?.boundingBoxOfPath.height
        enter()
        Checks.check(same(fromPoint(controls.layer, "media.containerMove"), containerPosition) &&
            same(fromPoint(pager.layer, "media.containerMove"), pagerPosition) &&
            same(fromSize(controls.layer, "media.containerResize"), containerSize) && same(fromSize(pager.layer, "media.containerResize"), pagerSize),
            "MC15 F2 \(cardCount) cards: pager/container retarget from their presentation values")
        Checks.check(same(fromPoint(card.layer, "media.position"), cardPosition) && same(fromSize(card.layer, "media.size"), cardSize) &&
            same(fromSize(card.contentView.layer, "media.size"), contentSize),
            "MC15 F2 \(cardCount) cards: card/content retarget from their presentation values")
        let opacityFrom = (title?.layer?.animation(forKey: "media.titleRowOpacity") as? CABasicAnimation)?.fromValue as? NSNumber
        Checks.check(opacityFrom.map { abs($0.floatValue-titleOpacity) <= 0.08 } == true,
            "MC15 F2 title opacity retargets from visible opacity (\(titleOpacity))")
        if let value = (card.shadowLayer.animation(forKey: "media.shadowPath") as? CABasicAnimation)?.fromValue, let shadowHeight {
            let path = value as! CGPath
            Checks.check(abs(path.boundingBoxOfPath.height-shadowHeight) <= 1, "MC15 F2 shadow retargets from the visible path")
        } else { Checks.check(false, "MC15 F2 shadow presentation/path animation exists") }
        if let from = (card.layer?.animation(forKey: "media.stackOpacity") as? CABasicAnimation)?.fromValue as? NSNumber {
            Checks.check(abs(from.floatValue-cardOpacity) <= 0.02, "MC15 F2 card opacity retargets from visible opacity")
        }
        wait(0.016)
        Checks.check(size(controls.layer).height >= containerSize.height - 0.5 && size(card.layer).height >= cardSize.height - 0.5,
            "MC15 F2 \(cardCount) cards: interrupted collapse has no backward jump at +16ms (container \(containerSize.height) → \(size(controls.layer).height))")
        rowsClear("interrupted +16ms"); wait(0.8)
        if let volume = card.control(named: "volume")?.view {
            let start = point(controls.layer)
            host.sendEvent(event(.leftMouseDown, volume)); host.sendEvent(event(.leftMouseUp, volume)); layout()
            Checks.check(same(fromPoint(controls.layer, "media.containerMove"), start, tolerance: 0.5), "MC15 F1 drawer starts at its on-screen container position")
            wait(0.016); rowsClear("drawer +16ms"); wait(0.8)
        }
        let plates = card.control(named: "play")?.view.layer?.sublayers?.filter { $0.cornerRadius > 0 } ?? []
        Checks.check(plates.count == 1 && plates.first?.cornerRadius == 5 && plates.first?.cornerCurve == .continuous,
            "MC15 F4 mini-player plate radius is 5 continuous")
        leave(); wait(1.2)
        Checks.check(MediaChecks.animationKeys(scene.layer).isEmpty && controls.pendingCollapseCount == 0,
            "MC15 motion ends without idle animation keys or collapse work")
    }
}
