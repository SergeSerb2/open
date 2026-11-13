import AppKit
import ImageIO
import OpenWeb

/// A single viewport image before motion, never a per-frame capture. It is kept
/// only for the transition. Hiding the engine host then stops its compositor
/// from contributing live surfaces to the moving layer tree.
@MainActor
enum PeekHostSnapshot {
    static func capture(_ host: any WebContentHost) async -> CGImage? {
        guard let page = (host as? any WebContentProviding)?.webContent else { return nil }
        PeekMotionTrace.mark("snapshot.capture.begin")
        defer { PeekMotionTrace.mark("snapshot.capture.end") }
        guard let data = try? await page.motionSnapshotPNG(), !Task.isCancelled,
              data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width <= 16 * 1024 * 1024 / height else { return nil }
        // At most 16M pixels × 4 = 64MiB per decoded Chromium RGBA8 image. Preparation retains the old and
        // destination images; promotion may also retain one fresh capture.
        return PeekMotionTrace.region("snapshot.decode") {
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }
}

extension PeekOverlayView {
    func isHostFrozen(_ view: NSView) -> Bool { motionHostView === view && motionHostFrozen }

    /// Opening freezes the initial, empty page plate. A loaded page uses the
    /// engine's viewport image for close/expand. Both keep the live view hidden
    /// for the entire motion, including late load/reveal callbacks.
    func freezeHost(_ view: NSView, image: CGImage?, hide: Bool = true) {
        endHostSnapshot()
        guard let parent = pageClip.layer, !pageClip.bounds.isEmpty else { return }
        PeekMotionTrace.mark("snapshot.freeze", value: image == nil ? 0 : 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let snapshot = CALayer()
        snapshot.frame = pageClip.bounds
        snapshot.zPosition = 1
        snapshot.contents = image
        snapshot.contentsScale = window?.backingScaleFactor ?? 1
        snapshot.contentsGravity = .resize
        // Preserve the engine's initial plate when no viewport image exists;
        // the clip's black backing is only a mask implementation detail.
        snapshot.backgroundColor = view.layer?.backgroundColor ?? parent.backgroundColor
        parent.addSublayer(snapshot)
        // The captured page, rounded clip, and fixed shadow are static while
        // only this ancestor's transform/position/opacity change. Cache that
        // subtree at this window's real scale until motion finishes.
        if hide, let panelLayer = panel.layer {
            panelLayer.rasterizationScale = window?.backingScaleFactor ?? 1
            panelLayer.shouldRasterize = true
        }
        motionHostView = view; motionHostWasHidden = view.isHidden
        motionSnapshotLayer = snapshot; motionRevealPending = false
        motionHostFrozen = hide
        if hide { view.isHidden = true }
        PeekMotionTrace.region("snapshot.explicitCommit") { CATransaction.commit() }
    }

    /// Leave the old pixels live while the render server receives the image.
    /// A constant layer animation gives the commit one refresh before hiding
    /// the live view. It is not a physical-presentation receipt; native movie
    /// frames verify the handoff. It never drives geometry on the main thread.
    func stageHostSnapshot(_ view: NSView, image: CGImage, ready: @escaping @MainActor () -> Void) {
        freezeHost(view, image: image, hide: false)
        guard let snapshot = motionSnapshotLayer else { ready(); return }
        afterSnapshotCommit(snapshot) { [weak self, weak view] in
            guard let self, let view, self.motionSnapshotLayer === snapshot else { return }
            self.motionHostFrozen = true; view.isHidden = true
            self.panel.layer?.rasterizationScale = self.window?.backingScaleFactor ?? 1
            self.panel.layer?.shouldRasterize = true
            ready()
        }
    }

    func afterSnapshotCommit(_ snapshot: CALayer, ready: @escaping @MainActor () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = snapshot.opacity; hold.toValue = snapshot.opacity
        hold.duration = 1 / Double(max(1, window?.screen?.maximumFramesPerSecond ?? 60))
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { ready() } }
        snapshot.add(hold, forKey: "peekSnapshotReady")
        PeekMotionTrace.region("snapshot.readyCommit") { CATransaction.commit() }
    }

    func attachOpeningHost(_ view: NSView) {
        guard let snapshot = motionSnapshotLayer, motionHostView === view else { return }
        PeekMotionTrace.mark("opening.attachCovered")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        openingHandoff = true; motionHostFrozen = false; motionHostWasHidden = false
        panel.layer?.shouldRasterize = false
        hostedView = view
        if view.superview !== pageClip { pageClip.addSubview(view) }
        view.autoresizingMask = [.width, .height]
        view.isHidden = false; view.alphaValue = 1
        // AppKit may insert its host layer above custom sublayers on attach.
        pageClip.layer?.addSublayer(snapshot)
        PeekMotionTrace.region("opening.attachCommit") { CATransaction.commit() }
    }

    func finishOpeningHandoff(image: CGImage?, ready: @escaping @MainActor () -> Void) {
        guard openingHandoff, let snapshot = motionSnapshotLayer else { return }
        if let image { snapshot.contents = image }
        afterSnapshotCommit(snapshot) { [weak self] in
            guard let self, self.motionSnapshotLayer === snapshot else { return }
            self.endHostSnapshot(); ready()
        }
    }

    func endHostSnapshot(reveal: Bool = true) {
        guard let snapshot = motionSnapshotLayer else { return }
        PeekMotionTrace.mark("snapshot.thaw")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if reveal, let view = motionHostView, view.superview === pageClip {
            if motionRevealPending { view.alphaValue = 1 }
            view.isHidden = motionHostWasHidden
        }
        snapshot.removeFromSuperlayer()
        panel.layer?.shouldRasterize = false
        motionSnapshotLayer = nil; motionHostView = nil; motionRevealPending = false
        motionHostFrozen = false; openingHandoff = false
        PeekMotionTrace.region("snapshot.explicitCommit") { CATransaction.commit() }
    }
}
