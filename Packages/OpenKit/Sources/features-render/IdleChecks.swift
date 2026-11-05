import AppKit
import CoreVideo
import Darwin
import OpenDesign
import OpenFeatures

// Deliberately exercise this deprecated scheduler in the harness canary. These
// C symbols are still shipped on macOS 26+. Keeping the declarations here avoids
// suppressing warnings in the target; product code must use no display link at idle.
@_silgen_name("CVDisplayLinkCreateWithActiveCGDisplays")
private func canaryCVCreate(_ link: UnsafeMutablePointer<CVDisplayLink?>) -> CVReturn
@_silgen_name("CVDisplayLinkSetOutputCallback")
private func canaryCVCallback(_ link: CVDisplayLink, _ callback: CVDisplayLinkOutputCallback, _ context: UnsafeMutableRawPointer?) -> CVReturn
@_silgen_name("CVDisplayLinkStart") private func canaryCVStart(_ link: CVDisplayLink) -> CVReturn
@_silgen_name("CVDisplayLinkStop") private func canaryCVStop(_ link: CVDisplayLink) -> CVReturn

/// Exercises the real window/overlay flow with the production clock. The dyld
/// observer is built and loaded only by tools/verification/features-idle.py.
@MainActor
enum IdleChecks {
    struct Probe {
        let begin: @convention(c) () -> Void
        let reset: @convention(c) () -> Void
        let end: @convention(c) () -> Void
        let watch: @convention(c) (UnsafeMutableRawPointer) -> Void
        let count: @convention(c) (Int32) -> UInt64
        init() throws {
            func symbol<T>(_ name: String, _: T.Type) throws -> T {
                guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
                    throw CLIError(description: "missing idle observer; run python3 tools/verification/features-idle.py")
                }
                return unsafeBitCast(address, to: T.self)
            }
            begin = try symbol("open_idle_begin", (@convention(c) () -> Void).self)
            reset = try symbol("open_idle_reset_events", (@convention(c) () -> Void).self)
            end = try symbol("open_idle_end", (@convention(c) () -> Void).self)
            watch = try symbol("open_idle_watch_view", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
            count = try symbol("open_idle_count", (@convention(c) (Int32) -> UInt64).self)
        }
        func watch(_ view: NSView) { watch(Unmanaged.passUnretained(view).toOpaque()) }
        var counts: [UInt64] { (0..<10).map { count(Int32($0)) } }
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        let probe = try Probe()
        try await observerProof(probe, check)
        defer { Motion.reduceMotionOverride = nil }
        for reduced in [false, true] {
            Motion.reduceMotionOverride = reduced
            try await toast(probe, reduced: reduced, check)
            try await swipe(probe, reduced: reduced, check)
        }
    }

    /// Fail closed if dyld interposition or method observation stops working.
    /// These are real schedulers and native drawing, not substitute feature code.
    private static func observerProof(_ p: Probe, _ check: (Bool, String) -> Void) async throws {
        p.begin(); defer { p.end() }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 60, repeating: 60); source.resume()
        let dormant = DispatchSource.makeTimerSource(queue: .main)
        dormant.resume() // no deadline: must still be observed as a live source
        let view = CanaryView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        let host = OffscreenRenderer.host(view, scale: 1)
        defer { host.contentView = nil; host.close() }
        p.watch(view)
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        view.layer?.setNeedsDisplay(); view.layer?.displayIfNeeded()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0; animation.toValue = 1; animation.duration = 60; animation.repeatCount = .infinity
        view.layer?.add(animation, forKey: "idle-canary")
        let animated = animationCount(view.layer) > 0
        let target = DisplayTarget()
        let displayLink = view.displayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        displayLink.add(to: .main, forMode: .default)
        var cv: CVDisplayLink?
        let created = canaryCVCreate(&cv)
        if let cv { _ = canaryCVCallback(cv, { _, _, _, _, _, _ in kCVReturnSuccess }, nil); _ = canaryCVStart(cv) }
        let counts = p.counts
        let queued = DispatchWorkItem {}, delayed = DispatchWorkItem {}
        DispatchQueue.main.async(execute: queued)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: delayed)
        let queueObserved = p.count(4) >= counts[4] + 2
        queued.cancel(); delayed.cancel()
        timer.invalidate(); source.cancel(); dormant.cancel(); displayLink.invalidate(); view.layer?.removeAllAnimations()
        if let cv { _ = canaryCVStop(cv) }
        let stopped = p.counts
        check(created == kCVReturnSuccess && counts[6] > 0 && counts[7] >= 2 && counts[8] > 0 && counts[9] > 0
              && counts[0...4].allSatisfy { $0 > 0 } && queueObserved && animated && animationCount(view.layer) == 0
              && stopped[6...9].allSatisfy { $0 == 0 },
              "S8 observer detects real Timer/DispatchSourceTimer/CVDisplayLink/NSView.displayLink, GCD work and drawing/layout/display/invalidation, then teardown: \(counts) → \(stopped)")
    }

    private final class DisplayTarget: NSObject {
        @objc func tick(_ link: CADisplayLink) {}
    }

    private final class CanaryView: NSView {
        override func draw(_ dirtyRect: NSRect) { NSColor.red.setFill(); dirtyRect.fill() }
    }

    private static func toast(_ p: Probe, reduced: Bool, _ check: (Bool, String) -> Void) async throws {
        p.begin(); defer { p.end() }
        let c = ToastChecks.controller()
        defer { c.toasts.dismissAll(); c.container.closeAll(); c.window?.close() }
        p.watch(c.toastOverlay)
        try await sample(p, controller: c, roots: [c.toastOverlay], label: "toast never shown; reduced=\(reduced)", check)
        c.toasts.animates = { true }
        // The production SystemToastClock drives expiry and the animated removal.
        c.toasts.show(ToastContent(title: "Idle gate expiry", lifetime: 0.12))
        c.toasts.views.forEach { p.watch($0) }
        try await Task.sleep(for: .seconds(0.12 + Motion.toastOut + 0.5))
        check(c.toasts.views.isEmpty && c.toastOverlay.isHidden, "S8 toast real expiry completes; reduced=\(reduced)")
        let handle = c.toasts.show(ToastContent(title: "Idle gate dismiss", lifetime: 0.12))
        c.toasts.views.forEach { p.watch($0) }
        handle.dismiss()
        try await Task.sleep(for: .seconds(Motion.toastOut + 0.5))
        check(c.toasts.views.isEmpty && c.toastOverlay.isHidden, "S8 toast animated dismiss completes; reduced=\(reduced)")
        try await sample(p, controller: c, roots: [c.toastOverlay], label: "toast dismissed; reduced=\(reduced)", check)
    }

    private static func swipe(_ p: Probe, reduced: Bool, _ check: (Bool, String) -> Void) async throws {
        p.begin(); defer { p.end() }
        let model = FeatureCLI.synthetic(), c = ToastChecks.controller(model)
        defer { c.container.closeAll(); c.window?.close() }
        let space = model.spaces[0], tab = space.pinned[0].tab!
        _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id))
        ToastChecks.pump(c.contentView)
        guard let slot = c.container.slots.first else { check(false, "S8 swipe pane exists"); return }
        func send(_ phase: SwipeIndicatorView.Phase, _ progress: Double) {
            c.container.showHistorySwipe(tabID: tab.id, .init(phase: phase, direction: .back, progress: progress))
        }
        try await sample(p, controller: c, roots: [slot], label: "swipe never started; reduced=\(reduced)", check)
        for phase in [SwipeIndicatorView.Phase.completed, .cancelled] {
            send(.began, 0); send(.changed, phase == .completed ? 1 : 0.5)
            guard let indicator = slot.swipeIndicator else { check(false, "S8 swipe indicator exists"); return }
            p.watch(indicator)
            send(phase, phase == .completed ? 1 : 0.5)
            try await Task.sleep(for: .seconds(1)) // exit and ready spring have both settled
            check(indicator.isHidden && !indicator.isActive, "S8 swipe \(phase.rawValue) exit completes; reduced=\(reduced)")
            try await sample(p, controller: c, roots: [indicator], label: "swipe \(phase.rawValue); reduced=\(reduced)", check)
        }
    }

    private static func animationCount(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) }
    }

    private static func sample(_ p: Probe, controller c: BrowserWindowController, roots: [NSView], label: String,
                               _ check: (Bool, String) -> Void) async throws {
        // Drain pre-existing layout/CA commits before the measured interval. No
        // polling, timer, display or layout request is issued during the 2 s wait.
        ToastChecks.pump(c.contentView)
        roots.forEach { p.watch($0) }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        let before = p.counts
        let animationsBefore = roots.reduce(0) { $0 + animationCount($1.layer) }
        p.reset()
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(2))
        let elapsed = CACurrentMediaTime() - start
        c.contentView.layoutSubtreeIfNeeded(); c.window?.displayIfNeeded(); CATransaction.flush()
        let after = p.counts
        let animations = roots.reduce(0) { $0 + animationCount($1.layer) }
        var load = [0.0, 0, 0]; getloadavg(&load, 3)
        let ok = before[5...9].allSatisfy { $0 == 0 } && after.allSatisfy { $0 == 0 } && animationsBefore == 0 && animations == 0
        check(ok, String(format: "S8 idle %@: events [draw,layout,display,invalidate,schedule,overflow]=%@; live [Timer,DispatchTimer,CVLink,CALink]=%@→%@; CA=%d→%d; %.3f s; load %.2f/%.2f/%.2f",
                         label, String(describing: Array(after[0...5])), String(describing: Array(before[6...9])),
                         String(describing: Array(after[6...9])), animationsBefore, animations, elapsed, load[0], load[1], load[2]))
    }
}
