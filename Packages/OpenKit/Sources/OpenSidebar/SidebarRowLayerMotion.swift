import AppKit
import OpenDesign

/// Native list edits settle once. Only the already laid-out row layers move.
/// The bookkeeping and optional departing-row bitmap happen at edit boundaries,
/// never on a display timer. At most 256 visible rows and 8 MiB of bitmaps survive.
@MainActor
final class SidebarRowLayerMotion {
    private struct Previous { let origin: CGPoint; let view: NSTableRowView; let opacity: Float }
    private var previous: [ObjectIdentifier: Previous] = [:]
    private var depth = 0
    private var enabled = false
    private var duration: CFTimeInterval = Motion.rowStructure
    private var timing = Motion.easeInOut
    private var departing: [CALayer] = []
    private var bitmapPixels = 0
    private var generation = 0
    private struct Rasterized {
        let layer: CALayer
        let enabled: Bool
        let scale: CGFloat
    }
    private var rasterized: [Rasterized] = []

    private func restoreRasterization() {
        for saved in rasterized {
            saved.layer.shouldRasterize = saved.enabled
            saved.layer.rasterizationScale = saved.scale
        }
        rasterized.removeAll(keepingCapacity: true)
    }

    func begin(_ outline: NSOutlineView, animated: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        depth += 1
        guard depth == 1 else { return }
        enabled = animated && !Motion.reducesMotion
        self.duration = duration; self.timing = timing
        generation += 1
        restoreRasterization()
        departing.forEach { $0.removeFromSuperlayer() }; departing.removeAll(); bitmapPixels = 0
        previous.removeAll(keepingCapacity: true)
        if enabled {
            outline.enumerateAvailableRowViews { view, row in
                guard self.previous.count < 256, let item = outline.item(atRow: row) as AnyObject? else { return }
                var point = view.convert(NSPoint.zero, to: outline)
                point.y += view.layer?.presentation()?.transform.m42 ?? 0
                self.previous[ObjectIdentifier(item)] = Previous(origin: point, view: view, opacity: view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 1)
            }
        } else {
            // An immediate edit can interrupt a prior animated edit (including
            // a Reduce Motion change). Do not carry its offset into new rows.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outline.enumerateAvailableRowViews { view, _ in
                view.layer?.removeAnimation(forKey: "row.structure.position")
                view.layer?.removeAnimation(forKey: "row.structure.opacity")
                view.layer?.transform = CATransform3DIdentity; view.layer?.opacity = 1
            }
            CATransaction.commit()
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
    }

    func captureDeparture(_ item: AnyObject, in outline: NSOutlineView) {
        guard enabled, let old = previous[ObjectIdentifier(item)], !departing.contains(where: { $0.name == String(describing: ObjectIdentifier(item)) }) else { return }
        let view = old.view, scale = view.window?.backingScaleFactor ?? 1
        let width = ceil(view.bounds.width * scale), height = ceil(view.bounds.height * scale)
        // One allocation is <= 8 MiB; the whole transition has the same ceiling.
        guard width > 0, height > 0, width <= 2048, height <= 1024,
              bitmapPixels + Int(width * height) <= 2_097_152,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return }
        bitmapPixels += Int(width * height)
        let copy = CALayer(); copy.contents = image; copy.contentsScale = scale
        copy.name = String(describing: ObjectIdentifier(item))
        copy.frame = CGRect(origin: old.origin, size: view.bounds.size)
        copy.opacity = old.opacity
        departing.append(copy)
    }

    func captureDescendants(of item: Any, in outline: NSOutlineView) {
        guard enabled else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        let level = outline.level(forRow: row)
        var next = row + 1
        while next < outline.numberOfRows, outline.level(forRow: next) > level {
            if let child = outline.item(atRow: next) as AnyObject? { captureDeparture(child, in: outline) }
            next += 1
        }
    }

    /// Keep motion at the active screen cadence without a main-thread display callback.
    private func preferDisplayRefresh(_ animation: CAAnimation, on screen: NSScreen?) {
        guard let screen else { return }
        let rate = Float(screen.maximumFramesPerSecond)
        guard rate > 0 else { return }
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    func end(_ outline: NSOutlineView) {
        guard depth > 0 else { return }
        depth -= 1; guard depth == 0 else { return }
        NSAnimationContext.endGrouping()
        guard enabled else { previous.removeAll(); return }
        outline.layoutSubtreeIfNeeded()
        let token = generation
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.departing.forEach { $0.removeFromSuperlayer() }; self.departing.removeAll()
                self.restoreRasterization()
            }
        }
        outline.enumerateAvailableRowViews { view, row in
            guard let item = outline.item(atRow: row) as AnyObject?, let layer = view.layer else { return }
            let old = self.previous[ObjectIdentifier(item)]
            let delta = old.map { $0.origin.y - view.convert(NSPoint.zero, to: outline).y } ?? -min(16, view.bounds.height)
            let opacity = old?.opacity ?? 0
            if abs(delta) > 0.01 || opacity < 1 {
                // Cache the static AppKit/text subtree only while it moves. The
                // departing images and these caches share a 2,097,152-pixel
                // budget (8 MiB at RGBA8; Core Animation owns cache storage).
                let scale = view.window?.backingScaleFactor ?? 1
                let width = ceil(view.bounds.width * scale), height = ceil(view.bounds.height * scale)
                if self.rasterized.count < 256, width > 0, height > 0, width <= 2048, height <= 1024,
                   self.bitmapPixels + Int(width * height) <= 2_097_152 {
                    self.bitmapPixels += Int(width * height)
                    self.rasterized.append(Rasterized(layer: layer, enabled: layer.shouldRasterize, scale: layer.rasterizationScale))
                    layer.rasterizationScale = scale; layer.shouldRasterize = true
                }
            }
            layer.removeAnimation(forKey: "row.structure.position")
            layer.removeAnimation(forKey: "row.structure.opacity")
            layer.transform = CATransform3DIdentity; layer.opacity = 1
            if abs(delta) > 0.01 {
                let move = CABasicAnimation(keyPath: "transform.translation.y")
                move.fromValue = delta; move.toValue = 0; move.duration = self.duration; move.timingFunction = self.timing
                self.preferDisplayRefresh(move, on: outline.window?.screen)
                layer.add(move, forKey: "row.structure.position")
            }
            if opacity < 1 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = opacity; fade.toValue = 1; fade.duration = self.duration; fade.timingFunction = self.timing
                self.preferDisplayRefresh(fade, on: outline.window?.screen)
                layer.add(fade, forKey: "row.structure.opacity")
            }
        }
        for layer in departing {
            outline.layer?.addSublayer(layer)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = duration; fade.timingFunction = timing
            preferDisplayRefresh(fade, on: outline.window?.screen)
            layer.opacity = 0; layer.add(fade, forKey: "row.structure.opacity")
        }
        CATransaction.commit()
        previous.removeAll(keepingCapacity: true)
    }
}
