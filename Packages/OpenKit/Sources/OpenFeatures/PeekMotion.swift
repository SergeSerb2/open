import AppKit
import OpenDesign

extension PeekOverlayView {
    /// Layout is committed once before motion. The render server animates
    /// the fixed native view tree; no NSView geometry follows individual frames.
    func animatePresentation(_ shown: Bool, duration: CFTimeInterval, completion: (@MainActor () -> Void)? = nil) {
        layoutSubtreeIfNeeded()
        guard duration > 0, let layer, let panelLayer = panel.layer else {
            resetMotion(); completion?(); return
        }
        let interrupted = layer.animation(forKey: "peekVisibility") != nil || panelLayer.animation(forKey: "peekGeometry") != nil
        let opacity = interrupted || !shown ? (layer.presentation() ?? layer).opacity : 0
        let transform = interrupted || !shown ? (panelLayer.presentation() ?? panelLayer).transform : CATransform3DMakeScale(0.98, 0.98, 1)
        let position = (panelLayer.presentation() ?? panelLayer).position
        let target = shown ? Float(1) : 0
        // Preserve main's slight close contraction until C14-4 measures it.
        let targetTransform = shown ? CATransform3DIdentity : CATransform3DMakeScale(0.98, 0.98, 1)
        beginMotion(shown ? "open" : "close", duration: duration, completion: completion)
        fade(layer, from: opacity, to: target, duration: duration)
        if let backdropLayer = backdrop.layer {
            fade(backdropLayer, from: interrupted || !shown ? (backdropLayer.presentation() ?? backdropLayer).opacity : 0, to: target, duration: duration)
        }
        geometry(panelLayer, from: transform, position: position, to: targetTransform, targetPosition: panelLayer.position,
                 duration: duration, holdsEnd: !shown, timing: shown ? Motion.easeOut : CAMediaTimingFunction(name: .default))
        PeekMotionTrace.region("motion.explicitCommit") { CATransaction.commit() }
    }

    /// Escape during expansion reverses from the displayed geometry, without
    /// snapping to the model frame or resizing the live page on every frame.
    func cancelExpansion(duration: CFTimeInterval, completion: (@MainActor () -> Void)? = nil) {
        if expansionCard != nil {
            reverseExpansionCard(duration: duration) { completion?() }
            return
        }
        restoreExpansionViewport()
        guard duration > 0, let panelLayer = panel.layer else { resetMotion(); completion?(); return }
        let current = panelLayer.presentation() ?? panelLayer
        let transform = current.transform, position = current.position
        let snapshot = motionSnapshotLayer
        beginMotion("cancel-expand", duration: duration) { [weak self] in
            guard let self, self.motionSnapshotLayer === snapshot else { return }
            if let completion { completion() } else { self.endHostSnapshot() }
        }
        geometry(panelLayer, from: transform, position: position, to: CATransform3DIdentity, targetPosition: panelLayer.position,
                 duration: duration, holdsEnd: false, timing: Motion.easeOut)
        for button in buttons {
            if let layer = button.layer { fade(layer, from: (layer.presentation() ?? layer).opacity, to: 1, duration: duration) }
        }
        PeekMotionTrace.region("motion.explicitCommit") { CATransaction.commit() }
    }

    func resetMotion() {
        restoreExpansionViewport(); clearExpansionCard()
        endHostSnapshot()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [layer, backdrop.layer] + buttons.map(\.layer) {
            layer?.removeAnimation(forKey: "peekVisibility"); layer?.opacity = 1
        }
        panel.layer?.removeAnimation(forKey: "peekGeometry")
        motionKind = ""; motionDuration = 0
        PeekMotionTrace.region("reset.explicitCommit") { CATransaction.commit() }
    }

    func revealHost(_ view: NSView, duration: CFTimeInterval) {
        if isHostFrozen(view) {
            motionRevealPending = true
            PeekMotionTrace.mark("host.reveal.deferred")
            return
        }
        PeekMotionTrace.mark("host.reveal", value: duration)
        let opacity = view.layer.map { ($0.presentation() ?? $0).opacity } ?? Float(view.alphaValue)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.alphaValue = 1
        if let layer = view.layer {
            if duration > 0 { fade(layer, from: opacity, to: 1, duration: duration) }
            else { layer.removeAnimation(forKey: "peekVisibility"); layer.opacity = 1 }
        }
        PeekMotionTrace.region("host.explicitCommit") { CATransaction.commit() }
    }

    private func beginMotion(_ kind: String, duration: CFTimeInterval, completion: (@MainActor () -> Void)?) {
        motionKind = kind; motionDuration = duration; motionStartedAt = CACurrentMediaTime()
        PeekMotionTrace.mark("motion." + kind, value: duration)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let completion { CATransaction.setCompletionBlock { MainActor.assumeIsolated {
            PeekMotionTrace.region("motion.completion") { completion() }
        } } }
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .default)
        layer.opacity = to
        layer.add(animation, forKey: "peekVisibility")
    }

    private func geometry(_ layer: CALayer, from: CATransform3D, position: CGPoint, to: CATransform3D, targetPosition: CGPoint,
                          duration: CFTimeInterval, holdsEnd: Bool, timing: CAMediaTimingFunction) {
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: from); scale.toValue = NSValue(caTransform3D: to)
        scale.duration = duration
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: position); move.toValue = NSValue(point: targetPosition)
        move.duration = duration
        let group = CAAnimationGroup(); group.animations = [scale, move]
        group.duration = duration; group.timingFunction = timing
        // The backing layer's model geometry always remains the view's real
        // frame. Retain only the visual endpoint until dismissal/promotion.
        group.fillMode = .forwards; group.isRemovedOnCompletion = !holdsEnd
        layer.add(group, forKey: "peekGeometry")
    }
}
