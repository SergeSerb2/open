import AppKit
import OpenDesign
import OpenFeatures

/// Open's history swipe indicator (page-platform §8.1 R-W1) through the real
/// `BrowserWindowController`, its `WebContentContainer` pane slot and `SwipeIndicatorView`, fed the
/// way the App feeds engine events (`container.showHistorySwipe`).
@MainActor
enum SwipeChecks {
    static func run(_ check: (Bool, String) -> Void) async throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        progress(check)
        await exits(check)
        Motion.reduceMotionOverride = true
        reduceMotion(check)
    }

    private static func setup() -> (BrowserWindowController, PaneSlotView)? {
        let model = FeatureCLI.synthetic()
        let c = ToastChecks.controller(model)
        guard let space = model.spaces.first, let tab = space.pinned.first?.tab ?? space.today.first?.tab else { return nil }
        _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)); ToastChecks.pump(c.contentView)
        guard let slot = c.container.slots.first else { return nil }
        return (c, slot)
    }

    private static func event(_ phase: SwipeIndicatorView.Phase, _ p: Double, _ direction: SwipeIndicatorView.Direction = .back) -> SwipeIndicatorView.Event {
        .init(phase: phase, direction: direction, progress: p)
    }

    // MARK: Progress 0, 0.5, 1.0 (back and forward)

    private static func progress(_ check: (Bool, String) -> Void) {
        guard let (c, slot) = setup() else { check(false, "R-W1 a pane slot exists"); return }
        defer { c.container.closeAll(); c.window?.close() }
        let id = slot.tabID
        let d = SwipeIndicatorMetrics.diameter, inset = SwipeIndicatorMetrics.edgeInset
        check(c.container.showHistorySwipe(tabID: id, event(.began, 0)) && slot.swipeIndicator != nil, "R-W1 the pane makes its indicator on the first swipe event")
        guard let ind = slot.swipeIndicator else { return }
        ToastChecks.pump(c.contentView)
        let page = ind.frame
        var f = ind.circleFrame
        check(f.minX == -d && f.width == d && abs(f.midY - page.height / 2) <= 0.5 && ind.circleOpacity == Float(SwipeIndicatorMetrics.baseAlpha),
              String(format: "R-W1 progress 0: circle x −40 (hidden), 40 × 40, centered vertically; alpha 0.35 (x %.1f, alpha %.2f)", f.minX, ind.circleOpacity))
        ind.update(event(.changed, 0.5))
        f = ind.circleFrame
        check(abs(f.minX - (-d + (d + inset) * 0.5)) < 0.01 && abs(ind.circleOpacity - 0.675) < 0.001 && ind.circleScale == 1,
              String(format: "R-W1 progress 0.5: x %.1f (expected −12), alpha %.3f (0.675), scale 1", f.minX, ind.circleOpacity))
        // Pixels at 0.5: a sample left of the glyph is the fill at alpha 0.675 over the page.
        c.window?.contentView = c.contentView
        let image = OffscreenRenderer().render(c.contentView, scale: 1)
        let pixels = ToastPixels(image)
        // A point inside the circle, clear of the glyph, and one on the page at the same row.
        let sample = c.contentView.convert(CGPoint(x: f.minX + 26, y: f.midY + 12), from: ind)
        let pagePoint = c.contentView.convert(CGPoint(x: page.width / 2, y: f.midY + 12), from: ind)
        let sx = Int(sample.x), sy = Int(sample.y)
        let bg = pixels.at(Int(pagePoint.x), Int(pagePoint.y))
        let fill = ToastChecks.channels(ind.style.toastFillTop)
        let expected = zip(bg, fill).map { Double($0) + ($1 - Double($0)) * 0.675 }
        let actual = pixels.at(sx, sy)
        check(ToastChecks.within(actual, expected, 3),
              "R-W1 rendered fill at 0.5 = page + (toastFillTop − page) × 0.675 within 3: \(actual) vs \(expected.map { Int($0.rounded()) }) (page \(bg))")
        ind.update(event(.changed, 1.0))
        f = ind.circleFrame
        check(f.minX == inset && ind.circleOpacity == 1 && abs(ind.circleScale - SwipeIndicatorMetrics.readyScale) < 0.001,
              String(format: "R-W1 progress 1.0: x 16 (edge inset), alpha 1, ready scale 1.12 (x %.1f, scale %.3f)", f.minX, ind.circleScale))
        ind.update(event(.changed, 0.9))
        check(ind.circleScale == 1, "R-W1 below 1.0 the ready scale goes back to 1")
        // Forward mirrors it at the right edge.
        ind.update(event(.cancelled, 0)); ind.update(event(.began, 0, .forward)); ind.update(event(.changed, 1.0, .forward))
        f = ind.circleFrame
        check(abs(f.maxX - (page.width - inset)) < 0.01, String(format: "R-W1 forward at 1.0: right edge %.1f = page width − 16 (%.1f)", f.maxX, page.width - inset))
        check(ind.hitTest(CGPoint(x: page.midX, y: page.midY)) == nil, "R-W1 the indicator never takes mouse events")
    }

    // MARK: Completed and cancelled

    private static func exits(_ check: (Bool, String) -> Void) async {
        guard let (c, slot) = setup() else { return }
        defer { c.container.closeAll(); c.window?.close() }
        c.container.showHistorySwipe(tabID: slot.tabID, event(.began, 0))
        guard let ind = slot.swipeIndicator else { return }
        ind.update(event(.changed, 1.0)); ind.update(event(.completed, 1.0))
        let fadeModel = ind.circleOpacity, keptX = ind.circleFrame.minX
        let deadline = Date().addingTimeInterval(SwipeIndicatorMetrics.completedFade + 0.4)
        while !ind.isHidden && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        check(fadeModel == 0 && keptX == SwipeIndicatorMetrics.edgeInset && ind.isHidden && !ind.isActive,
              "R-W1 completed: fades to 0 in place over 0.18 s, then hides (x \(keptX), hidden \(ind.isHidden))")
        ind.update(event(.began, 0)); ind.update(event(.changed, 0.5)); ind.update(event(.cancelled, 0.5))
        let slidX = ind.circleFrame.minX
        let deadline2 = Date().addingTimeInterval(SwipeIndicatorMetrics.cancelledSlide + 0.4)
        while !ind.isHidden && Date() < deadline2 { try? await Task.sleep(nanoseconds: 20_000_000) }
        check(slidX == -SwipeIndicatorMetrics.diameter && ind.circleOpacity == 0 && ind.isHidden,
              "R-W1 cancelled: slides back to x −40 over 0.20 s ease-out, then hides (x \(slidX))")
        ind.update(event(.changed, 0.7))
        check(ind.isHidden && ind.circleOpacity == 0, "R-W1 a stray change after the end does nothing")
    }

    // MARK: Reduce Motion

    private static func reduceMotion(_ check: (Bool, String) -> Void) {
        guard let (c, slot) = setup() else { return }
        defer { c.container.closeAll(); c.window?.close() }
        c.container.showHistorySwipe(tabID: slot.tabID, event(.began, 0))
        guard let ind = slot.swipeIndicator else { return }
        let x0 = ind.circleFrame.minX
        ind.update(event(.changed, 0.4))
        check(x0 == SwipeIndicatorMetrics.edgeInset && ind.circleFrame.minX == x0 && ind.circleOpacity == 1 && ind.circleHasAnimation("fade"),
              "R-W1 Reduce Motion: no slide, the circle fades in at its final position (x \(x0))")
        ind.update(event(.cancelled, 0.4))
        check(ind.circleFrame.minX == x0, "R-W1 Reduce Motion: cancel fades out in place (no slide back)")
    }
}
