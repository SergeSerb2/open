import AppKit
import OpenDesign

/// When the last sidebar row motion started so far settles, in
/// `CACurrentMediaTime()` seconds. Deferrable main-thread work (the App's
/// menu rebuild) waits for it. One store per animated edit; no timer.
@MainActor
public enum SidebarMotionClock {
    public internal(set) static var settlesAt: CFTimeInterval = 0
}

/// Native list edits settle once. Only the already laid-out row layers move.
/// The bookkeeping and optional departing-row bitmap happen at edit boundaries,
/// never on a display timer. At most 256 visible rows and 8 MiB of departing bitmaps survive.
@MainActor
final class SidebarRowLayerMotion {
    private struct Previous { let origin: CGPoint; let view: NSTableRowView; let opacity: Float }
    private struct Departure { let layer: CALayer; let pixels: Int; let generation: Int }
    private var previous: [ObjectIdentifier: Previous] = [:]
    private var depth = 0
    private var enabled = false
    private var duration: CFTimeInterval = Motion.rowStructure
    private var timing = Motion.easeInOut
    private var departing: [Departure] = []
    private var bitmapPixels = 0
    private var generation = 0

    func begin(_ outline: NSOutlineView, animated: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        depth += 1
        guard depth == 1 else { return }
        enabled = animated && !Motion.reducesMotion
        SidebarDiagnostics.folderTrace?("rowMotion.begin enabled=\(enabled)")
        self.duration = duration; self.timing = timing
        generation += 1
        previous.removeAll(keepingCapacity: true)
        if enabled {
            outline.enumerateAvailableRowViews { view, row in
                guard self.previous.count < 256, let item = outline.item(atRow: row) as AnyObject? else { return }
                var point = view.convert(NSPoint.zero, to: outline)
                point.y += view.layer?.presentation()?.transform.m42 ?? 0
                self.previous[ObjectIdentifier(item)] = Previous(origin: point, view: view, opacity: view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 1)
            }
        } else {
            departing.forEach { $0.layer.removeFromSuperlayer() }; departing.removeAll(); bitmapPixels = 0
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
        guard enabled, departing.count < 256, let old = previous[ObjectIdentifier(item)],
              !departing.contains(where: { $0.generation == generation && $0.layer.name == String(describing: ObjectIdentifier(item)) }) else { return }
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
        departing.append(Departure(layer: copy, pixels: Int(width * height), generation: generation))
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

    /// Optional fixed-rate request (min = max = screen maximum). Off: the
    /// system default cadence for Core Animation. On the M1, the fixed request
    /// coincided with first motion intervals of two or three refreshes.
    private func preferDisplayRefresh(_ animation: CAAnimation, on screen: NSScreen?) {
        guard SidebarDiagnostics.rowMotionRequestsFixedRate, let screen else { return }
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
        SidebarDiagnostics.folderTrace?("rowMotion.end.laidOut")
        let token = generation
        SidebarMotionClock.settlesAt = max(SidebarMotionClock.settlesAt, CACurrentMediaTime() + duration)
        let batch = departing.filter { $0.generation == token }
        let retiring = Set(batch.map { ObjectIdentifier($0.layer) })
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                SidebarDiagnostics.folderTrace?("rowMotion.complete")
                guard let self else { return }
                // A subsequent edit must not cut short an earlier departure.
                // Each transaction retires only its own layers and releases
                // their share of the same global 8 MiB bitmap budget.
                self.departing.removeAll { entry in
                    guard retiring.contains(ObjectIdentifier(entry.layer)) else { return false }
                    entry.layer.removeFromSuperlayer()
                    self.bitmapPixels -= entry.pixels
                    return true
                }
            }
        }
        outline.enumerateAvailableRowViews { view, row in
            guard let item = outline.item(atRow: row) as AnyObject?, let layer = view.layer else { return }
            let old = self.previous[ObjectIdentifier(item)]
            let delta = old.map { $0.origin.y - view.convert(NSPoint.zero, to: outline).y } ?? -min(16, view.bounds.height)
            let opacity = old?.opacity ?? 0
            // Existing row contents are already backed by layer textures.
            // Translate them directly; a temporary raster cache would require
            // an extra offscreen pass at the start of each list edit.
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
        for entry in batch {
            let layer = entry.layer
            outline.layer?.addSublayer(layer)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = duration; fade.timingFunction = timing
            preferDisplayRefresh(fade, on: outline.window?.screen)
            layer.opacity = 0; layer.add(fade, forKey: "row.structure.opacity")
        }
        CATransaction.commit()
        SidebarDiagnostics.folderTrace?("rowMotion.end.added departures=\(batch.count)")
        previous.removeAll(keepingCapacity: true)
    }
}
