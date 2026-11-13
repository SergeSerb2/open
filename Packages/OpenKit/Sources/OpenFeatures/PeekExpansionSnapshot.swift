import AppKit
import OpenDesign

extension PeekOverlayView {
    /// Commit the destination viewport once, underneath the old opaque image.
    /// Its ready image is then clipped and translated at native scale. Text
    /// therefore matches the live destination instead of shrinking on handoff.
    func prepareExpansionViewport(_ target: CGRect) {
        guard let view = motionHostView, let snapshot = motionSnapshotLayer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        expansionOriginalViewport = view.frame
        expansionViewport = CGRect(origin: .zero, size: target.size)
        panel.layer?.shouldRasterize = false
        motionHostFrozen = false
        if view.frame != expansionViewport! {
            hostFrameChangeCount += 1
            PeekMotionTrace.mark("host.setFrame.prepareExpansion", value: target.width)
            view.frame = expansionViewport!
        }
        view.isHidden = false; view.alphaValue = 1
        pageClip.layer?.addSublayer(snapshot)
        PeekMotionTrace.region("expansion.prepareCommit") { CATransaction.commit() }
    }

    func stageExpansionImage(_ image: CGImage, target: CGRect, ready: @escaping @MainActor () -> Void) {
        guard let parent = layer else { ready(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let card = CALayer(), clip = CALayer(), pixels = CALayer()
        card.anchorPoint = .zero; card.position = panel.frame.origin
        card.bounds = CGRect(origin: .zero, size: panel.bounds.size)
        card.shadowColor = panel.layer?.shadowColor; card.shadowOpacity = PeekMetrics.shadowOpacity
        card.shadowRadius = PeekMetrics.shadowRadius; card.shadowOffset = CGSize(width: 0, height: -2)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
        clip.anchorPoint = .zero; clip.position = .zero; clip.bounds = card.bounds
        clip.cornerRadius = PanelMetrics.cornerRadius; clip.masksToBounds = true
        // Keep image pixels pinned to the card's top-left while its clip grows.
        // Only this layer position changes; image size and text scale stay fixed.
        pixels.anchorPoint = CGPoint(x: 0, y: 1)
        pixels.bounds = CGRect(origin: .zero, size: target.size)
        pixels.position = CGPoint(x: 0, y: card.bounds.height)
        pixels.contents = image; pixels.contentsScale = window?.backingScaleFactor ?? 1
        pixels.contentsGravity = .resize
        clip.addSublayer(pixels); card.addSublayer(clip); parent.addSublayer(card)
        expansionCard = card; expansionImage = pixels
        expandedImagePixels = CGSize(width: image.width, height: image.height)
        PeekMotionTrace.region("expansion.imageCommit") { CATransaction.commit() }
        afterSnapshotCommit(card) { [weak self] in
            guard let self, self.expansionCard === card else { return }
            self.panel.layer?.opacity = 0
            self.motionHostFrozen = true; self.motionHostView?.isHidden = true
            ready()
        }
    }

    func animateExpansionCard(to target: CGRect, duration: Double, completion: @escaping @MainActor () -> Void) {
        guard let card = expansionCard, let clip = card.sublayers?.first else { completion(); return }
        motionKind = "expand"; motionDuration = duration; motionStartedAt = CACurrentMediaTime()
        PeekMotionTrace.mark("motion.expand", value: duration)
        animateCard(card, clip: clip, target: target, duration: duration, completion: completion)
    }

    func reverseExpansionCard(duration: Double, completion: @escaping @MainActor () -> Void) {
        guard let card = expansionCard, let clip = card.sublayers?.first else { completion(); return }
        restoreExpansionViewport()
        motionKind = "cancel-expand"; motionDuration = duration; motionStartedAt = CACurrentMediaTime()
        PeekMotionTrace.mark("motion.cancel-expand", value: duration)
        animateCard(card, clip: clip, target: panel.frame, duration: duration) { [weak self] in
            guard let self, self.expansionCard === card else { return }
            self.clearExpansionCard(); completion()
        }
    }

    private func animateCard(_ card: CALayer, clip: CALayer, target: CGRect, duration: Double,
                             completion: @escaping @MainActor () -> Void) {
        let displayed = card.presentation() ?? card
        let oldBounds = displayed.bounds, oldPosition = displayed.position
        let bounds = CGRect(origin: .zero, size: target.size)
        let path = CGPath(roundedRect: bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let resize = CABasicAnimation(keyPath: "bounds")
        resize.fromValue = NSValue(rect: oldBounds); resize.toValue = NSValue(rect: bounds)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: oldPosition); move.toValue = NSValue(point: target.origin)
        let shadow = CABasicAnimation(keyPath: "shadowPath")
        shadow.fromValue = displayed.shadowPath; shadow.toValue = path
        for animation in [resize, move, shadow] { animation.duration = duration }
        let group = CAAnimationGroup(); group.animations = [resize, move, shadow]
        group.duration = duration; group.timingFunction = Motion.easeInOut
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        card.bounds = bounds; card.position = target.origin; card.shadowPath = path
        card.add(group, forKey: "peekGeometry")
        resize.duration = duration; resize.timingFunction = Motion.easeInOut
        clip.bounds = bounds; clip.add(resize, forKey: "peekClip")
        if let pixels = expansionImage {
            let pin = CABasicAnimation(keyPath: "position")
            pin.fromValue = NSValue(point: (pixels.presentation() ?? pixels).position)
            pin.toValue = NSValue(point: CGPoint(x: 0, y: bounds.height))
            pin.duration = duration; pin.timingFunction = Motion.easeInOut
            pixels.position = CGPoint(x: 0, y: bounds.height)
            pixels.add(pin, forKey: "peekTopEdge")
        }
        for button in buttons {
            if let layer = button.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = (layer.presentation() ?? layer).opacity
                fade.toValue = target == panel.frame ? 1 : 0; fade.duration = duration
                layer.opacity = target == panel.frame ? 1 : 0
                layer.add(fade, forKey: "peekVisibility")
            }
        }
        PeekMotionTrace.region("motion.explicitCommit") { CATransaction.commit() }
    }

    func restoreExpansionViewport() {
        if let frame = expansionOriginalViewport, let view = motionHostView, view.superview === pageClip, view.frame != frame {
            hostFrameChangeCount += 1; view.frame = frame
        }
        expansionViewport = nil; expansionOriginalViewport = nil
    }

    func clearExpansionCard() {
        expansionCard?.removeFromSuperlayer(); expansionCard = nil; expansionImage = nil; expandedImagePixels = nil
        panel.layer?.opacity = 1
    }
}
