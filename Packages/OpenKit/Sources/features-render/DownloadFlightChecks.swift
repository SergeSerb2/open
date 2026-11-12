import AppKit
import OpenDesign
import OpenFeatures

/// The download start animation against capture PB1-b (C-report-s10 (b)): the model at the measured
/// times, then the real overlay through `BrowserWindowController.playDownloadFlight`.
@MainActor
enum DownloadFlightChecks {
    static func run(_ check: (Bool, String) -> Void) {
        defer { Motion.reduceMotionOverride = nil }
        // Capture geometry in screen points: link at (390, 133); last seen at (60, 782) after 0.883 s.
        let f = DownloadFlight(start: CGPoint(x: 390, y: 133), target: CGPoint(x: 60, y: 782))
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool { abs(a - b) <= tolerance }
        let apex = f.position(at: 0.16), mid = f.position(at: 0.50), late = f.position(at: 0.70), end = f.position(at: f.duration)
        check(near(CGFloat(f.duration), 0.883, 0.03) && near(f.horizontalSpeed, -360, 20),
              "DF1 capture flight: duration \(String(format: "%.3f", f.duration)) s (0.883 ± 0.03), horizontal speed \(Int(f.horizontalSpeed)) pt/s (−360 ± 20)")
        check(near(apex.y, 102, 3) && near(mid.y, 254, 12) && near(late.y, 482, 15) && near(end.y, 782, 0.5) && near(end.x, 60, 0.5),
              "DF2 path at 0.16 / 0.50 / 0.70 s and the end: y \(Int(apex.y)) / \(Int(mid.y)) / \(Int(late.y)) / \(Int(end.y)) (capture 102 / 254 / 482 / 782), end x \(Int(end.x))")
        check(f.size(at: 0) == 34 && near(f.size(at: f.apexTime), 47, 0.01) && near(f.size(at: f.duration), 10, 0.01)
              && f.size(at: f.apexTime + (f.duration - f.apexTime) / 2) < 47,
              "DF3 size 34 → 47 pt at the apex → 10 pt at the end")
        check(DownloadFlight.startDelay == 0.17, "DF4 the icon appears 0.17 s after the click")

        // The real overlay in a real window controller.
        Motion.reduceMotionOverride = false
        let c = ToastChecks.controller()
        defer { c.container.closeAll(); c.window?.close() }
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        guard let target = c.sidebar.libraryButtonFrame(in: c.contentView) else { check(false, "DF5 the Library button has a frame"); return }
        let start = CGPoint(x: c.container.frame.midX, y: c.container.frame.minY + 80)
        guard let view = c.playDownloadFlight(from: start, icon: icon) else { check(false, "DF5 the flight plays"); return }
        let keys = Set(view.iconLayer.animationKeys() ?? [])
        let position = view.iconLayer.animation(forKey: "downloads.flight.position") as? CAKeyframeAnimation
        let last = (position?.values?.last as? NSValue)?.pointValue ?? .zero, first = (position?.values?.first as? NSValue)?.pointValue ?? .zero
        check(view.superview === c.contentView && view.frame == c.contentView.bounds && view.hitTest(start) == nil
              && keys == ["downloads.flight.position", "downloads.flight.bounds", "downloads.flight.opacity"]
              && near(CGFloat(position?.duration ?? 0), CGFloat(view.flight.duration), 0.001)
              && near(first.x, start.x, 0.5) && near(first.y, start.y, 0.5) && near(last.x, target.midX, 0.5) && near(last.y, target.midY, 0.5),
              "DF5 overlay over the whole window, click-through, three keyframe animations from the start point to the Library button centre (\(Int(last.x)), \(Int(last.y)))")
        check(view.iconLayer.opacity == 0 && view.iconLayer.bounds.width == DownloadFlight.endSize,
              "DF6 model state is the hidden end state (no snap or leftover after the flight)")
        OffscreenRenderer.settle(c.contentView, runLoop: DownloadFlight.startDelay + view.flight.duration + 0.25)
        check(view.superview == nil, "DF7 the overlay removes itself when the flight ends")

        Motion.reduceMotionOverride = true
        check(c.playDownloadFlight(from: start, icon: icon) == nil, "DF8 Reduce Motion plays no flight")
    }
}
