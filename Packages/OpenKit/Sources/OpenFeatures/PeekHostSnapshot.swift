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

    func prepareOpeningPlate(_ view: NSView, color: NSColor) {
        clearHost()
        layoutSubtreeIfNeeded()
        pageClip.layer?.backgroundColor = color.cgColor
        freezeHost(view, image: nil)
        motionSnapshotLayer?.backgroundColor = color.cgColor
        // Only rounded solid backgrounds move here. Their own corner radii
        // draw the outline without clipping a child subtree offscreen.
        pageClip.layer?.masksToBounds = false
        PeekMotionTrace.mark("opening.plateReady")
    }

    /// A loaded page uses a viewport image for close/expand. An opening uses
    /// the source page color until ready content can fade over it. The live
    /// compositor never participates in moving the card.
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
        if image == nil { snapshot.cornerRadius = parent.cornerRadius }
        // A known page color also covers transparent snapshot pixels.
        snapshot.backgroundColor = parent.backgroundColor
        parent.addSublayer(snapshot)
        // The captured page, rounded clip, and fixed shadow are static while
        // only this ancestor's transform/position/opacity change. Cache that
        // subtree at this window's real scale until motion finishes.
        // A solid opening plate needs no offscreen raster texture. Loaded
        // viewport images still cache their masked subtree while moving.
        if hide, image != nil, let panelLayer = panel.layer {
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
        requestDisplayRate(hold)
        snapshot.add(hold, forKey: "peekSnapshotReady")
        PeekMotionTrace.region("snapshot.readyCommit") { CATransaction.commit() }
    }

    func attachOpeningHost(_ view: NSView) {
        guard let snapshot = motionSnapshotLayer, motionHostView === view else { return }
        PeekMotionTrace.mark("opening.attachCovered")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        openingHandoff = true; motionHostFrozen = false; motionHostWasHidden = false
        pageClip.layer?.masksToBounds = true
        panel.layer?.shouldRasterize = false
        hostedView = view
        if view.superview !== pageClip { pageClip.addSubview(view) }
        view.autoresizingMask = [.width, .height]
        view.isHidden = false; view.alphaValue = 1
        // AppKit may insert its host layer above custom sublayers on attach.
        pageClip.layer?.addSublayer(snapshot)
        PeekMotionTrace.region("opening.attachCommit") { CATransaction.commit() }
    }

    func holdOpeningPlate() {
        guard let snapshot = motionSnapshotLayer else { return }
        snapshot.opacity = (snapshot.presentation() ?? snapshot).opacity
        snapshot.removeAllAnimations()
        motionHostView?.isHidden = true; motionHostFrozen = true
        openingHandoff = false
    }

    func finishOpeningHandoff(image: CGImage?, duration: CFTimeInterval, ready: @escaping @MainActor () -> Void) {
        guard openingHandoff, let snapshot = motionSnapshotLayer else { return }
        // The opaque plate stays in place until the image exists. Fade only
        // destination pixels over the same page color with the engine hidden.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let image {
            motionHostView?.isHidden = true; motionHostFrozen = true
            snapshot.contents = image
        }
        snapshot.opacity = image == nil ? snapshot.opacity : 0
        PeekMotionTrace.region("opening.imageCommit") { CATransaction.commit() }
        // Keep engine visibility and image preparation out of the animation
        // transaction. The source color stays opaque for this commit fence.
        afterSnapshotCommit(snapshot) { [weak self] in
            guard let self, self.openingHandoff, self.motionSnapshotLayer === snapshot else { return }
            self.fadeOpeningImage(snapshot, hasImage: image != nil, duration: duration, ready: ready)
        }
    }

    private func fadeOpeningImage(_ snapshot: CALayer, hasImage: Bool, duration: CFTimeInterval,
                                  ready: @escaping @MainActor () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = hasImage ? 0 : snapshot.opacity
        fade.toValue = hasImage ? 1 : 0
        fade.duration = duration
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in
            guard let self, self.openingHandoff, self.motionSnapshotLayer === snapshot else { return }
            // Reattach live pixels under the completed image before retiring
            // it. Native captures verify that the last swap has no flash.
            self.motionHostFrozen = false
            self.motionHostView?.isHidden = false
            self.afterSnapshotCommit(snapshot) { [weak self] in
                guard let self, self.openingHandoff, self.motionSnapshotLayer === snapshot else { return }
                self.endHostSnapshot(); ready()
            }
        } }
        snapshot.opacity = hasImage ? 1 : 0
        requestDisplayRate(fade)
        snapshot.add(fade, forKey: "peekContentReveal")
        PeekMotionTrace.mark("opening.contentFade", value: duration)
        PeekMotionTrace.region("opening.fadeCommit") { CATransaction.commit() }
    }

    func endHostSnapshot(reveal: Bool = true) {
        pageClip.layer?.masksToBounds = true
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
