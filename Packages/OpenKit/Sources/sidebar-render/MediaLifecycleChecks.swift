import AppKit
import OpenDesign
import OpenMedia
import OpenModel
import OpenSidebar
import OpenWeb

/// Real composed sidebar checks for resize ownership, reduced motion and hide/show.
@MainActor enum MediaLifecycleChecks {
    static func run() {
        print("MC16 code-review regressions: reduced-motion cross-fade, direct width drag, lifecycle")
        for reduced in [false, true] { run(reduced: reduced) }
    }

    private static func run(reduced: Bool) {
        let model = Synthetic.model(); model.rebuildIndex()
        guard let window = model.windows.first, let space = model.spaces.first else { return }
        window.sidebarWidth = 228; space.theme = SpaceTheme()
        let context = SidebarContext(model: model, windowID: window.id); context.systemAppearance = .dark
        let store = MediaSourceStore(); context.media = store
        let delegate = MediaHarnessDelegate(context: context)
        func add(_ index: Int) -> Tab {
            let tab = model.newTab(in: space.id, url: URL(string: "https://media.example.test/lifecycle/\(index)")!, title: "Synthetic lifecycle \(index)")
            delegate.add(tab: tab, state: WebMediaState(playback: .paused, isControllable: true, hasVideo: true, volume: 0.5))
            return tab
        }
        let original = add(0)
        // Create its row before the host: this gate isolates a media publication
        // from the unrelated new-tab row insertion fade in the pager.
        let fourth = model.newTab(in: space.id, url: URL(string: "https://media.example.test/lifecycle/4")!, title: "Synthetic lifecycle 4")
        let force = SidebarDiagnostics.forceAnimations, reduce = SidebarDiagnostics.mediaReduceMotionOverride
        SidebarDiagnostics.forceAnimations = true; SidebarDiagnostics.mediaReduceMotionOverride = reduced
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 2); host.orderBack(nil)
        defer {
            host.orderOut(nil); host.contentView = nil; host.close()
            SidebarDiagnostics.forceAnimations = force; SidebarDiagnostics.mediaReduceMotionOverride = reduce
        }
        let controls = scene.sidebar.mediaControls
        guard let pager = MediaChecks.descendants(scene.sidebar).first(where: { String(describing: type(of: $0)) == "SpacePagerView" }) else { return }
        func layout() { scene.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush() }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)); layout() }
        func event() -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: controls.convert(CGPoint(x: controls.bounds.midX, y: controls.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        func enter() { controls.mouseEntered(with: event()); layout() }
        func leave() { controls.mouseExited(with: event()); layout() }
        func animations(_ layer: CALayer?) -> [CAAnimation] {
            guard let layer else { return [] }
            return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } + (layer.sublayers ?? []).flatMap(animations)
        }
        func startsAtZero(_ animation: CAAnimation) -> Bool {
            if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: startsAtZero) }
            guard let a = animation as? CABasicAnimation, a.keyPath == "opacity", let from = a.fromValue as? NSNumber else { return false }
            return abs(from.doubleValue) < 0.001
        }
        func reducedTransition(_ phase: String) {
            let all = animations(controls.layer) + animations(pager.layer)
            Checks.check(!all.contains(where: startsAtZero), "MC16 C1 \(phase): no view opacity animation starts at zero")
            let fades = animations(controls.layer).compactMap { $0 as? CATransition }
            Checks.check(animations(pager.layer).isEmpty && fades.count == 1 && fades.first?.type == .fade &&
                abs((fades.first?.duration ?? 0)-0.1) < 0.001,
                "MC16 C1 \(phase): one container cross-fade and no pager animation")
            wait(0.016)
            Checks.check((pager.layer?.presentation()?.opacity ?? 0) >= 0.99 && (controls.layer?.presentation()?.opacity ?? 0) >= 0.99,
                "MC16 C1 \(phase): pager/container retain full presentation opacity at +16ms")
        }
        wait(0.8); enter()
        if reduced { reducedTransition("hover in") }
        wait(0.8)
        let second = add(1); wait(0.8)
        let title = controls.cards.first(where: { $0.source.tabID == second.id }).flatMap {
            MediaChecks.descendants($0).first { $0.identifier?.rawValue == "media.titleRow" }
        }
        Checks.check(controls.isExpanded && controls.cards.count == 2 && controls.requiredHeight == 145 && title?.isHiddenOrHasHiddenAncestor == false,
            "MC16 C3 expanded add gives two titled cards and C=145 (Reduce Motion \(reduced))")
        store.remove(tabID: second.id); wait(0.8)
        Checks.check(controls.isExpanded && controls.cards.count == 1 && controls.requiredHeight == 74 && controls.cards.first?.source.tabID == original.id,
            "MC16 C3 expanded removal returns to one card and C=74 (Reduce Motion \(reduced))")
        leave()
        let deadline = CACurrentMediaTime()+1
        while controls.isExpanded && CACurrentMediaTime() < deadline { wait(0.002) }
        if reduced { reducedTransition("hover out") }
        wait(0.8)
        _ = add(2); _ = add(3); wait(0.8)
        if reduced {
            delegate.add(tab: fourth, state: WebMediaState(playback: .paused, isControllable: true, hasVideo: true, volume: 0.5)); wait(0.01)
            reducedTransition("fourth source, unchanged height")
            Checks.check(controls.requiredHeight == 55 && controls.cards.count == 3, "MC16 C1 fourth source keeps C=55")
            wait(0.8)
        }
        for expanded in [false, true] {
            if expanded { enter(); wait(0.016) }
            window.sidebarWidth = 400; wait(0.8)
            var cleanEveryStep = true
            for step in 1...20 {
                window.sidebarWidth = 400 - 172 * Double(step)/20; wait(0.008)
                cleanEveryStep = cleanEveryStep && MediaChecks.animationKeys(controls.layer).isEmpty
            }
            wait(0.016)
            let fit = controls.cards.enumerated().allSatisfy { index, card in
                let expected: CGFloat = 212 - (expanded ? 0 : CGFloat(index)*10)
                return abs(card.bounds.width-expected) <= 0.5 && abs((card.layer?.presentation()?.bounds.width ?? -1)-expected) <= 0.5
            }
            Checks.check(cleanEveryStep && MediaChecks.animationKeys(controls.layer).isEmpty,
                "MC16 C2 width drag attaches no animations (expanded \(expanded), Reduce Motion \(reduced))")
            Checks.check(fit, "MC16 C2 400→228 drag ends at exact inset widths in model and presentation (expanded \(expanded), Reduce Motion \(reduced))")
            if expanded { leave(); wait(0.8) }
        }
        enter(); wait(0.8); leave(); wait(0.1)
        Checks.check(controls.isExpanded && controls.pendingCollapseCount == 1, "MC16 C4 collapse is pending before hiding the sidebar")
        scene.sidebar.isHidden = true; wait(0.02)
        Checks.check(!controls.isExpanded && controls.pendingCollapseCount == 0 && controls.requiredHeight == 55,
            "MC16 C4 hiding cancels work and resets to collapsed C=55")
        scene.sidebar.isHidden = false; wait(0.02)
        Checks.check(!controls.isExpanded && controls.requiredHeight == 55 && controls.cards.allSatisfy { $0.cardHeight == 33 },
            "MC16 C4 shown sidebar stays at rest without another pointer event")
        wait(0.8)
        Checks.check(MediaChecks.animationKeys(controls.layer).isEmpty, "MC16 lifecycle finishes without animation keys")
    }
}
