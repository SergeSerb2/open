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
        guard let data = try? await page.snapshotPNG(), !Task.isCancelled,
              data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        // At most 8192² × 4 = 256 MiB for a decoded viewport; no full-page image.
        return PeekMotionTrace.region("snapshot.decode") {
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }
}

extension PeekOverlayView {
    func isHostFrozen(_ view: NSView) -> Bool { motionHostView === view }

    /// Opening freezes the initial, empty page plate. A loaded page uses the
    /// engine's viewport image for close/expand. Both keep the live view hidden
    /// for the entire motion, including late load/reveal callbacks.
    func freezeHost(_ view: NSView, image: CGImage?) {
        endHostSnapshot()
        guard let parent = pageClip.layer, !pageClip.bounds.isEmpty else { return }
        PeekMotionTrace.mark("snapshot.freeze", value: image == nil ? 0 : 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let snapshot = CALayer()
        snapshot.frame = pageClip.bounds
        snapshot.contents = image
        snapshot.contentsScale = window?.backingScaleFactor ?? 1
        snapshot.contentsGravity = .resize
        snapshot.backgroundColor = pageClip.layer?.backgroundColor
        parent.addSublayer(snapshot)
        motionHostView = view; motionHostWasHidden = view.isHidden
        motionSnapshotLayer = snapshot; motionRevealPending = false
        view.isHidden = true
        PeekMotionTrace.region("snapshot.explicitCommit") { CATransaction.commit() }
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
        motionSnapshotLayer = nil; motionHostView = nil; motionRevealPending = false
        PeekMotionTrace.region("snapshot.explicitCommit") { CATransaction.commit() }
    }
}
