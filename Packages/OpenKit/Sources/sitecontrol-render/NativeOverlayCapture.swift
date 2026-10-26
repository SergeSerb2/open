import AppKit
import OpenDesign

/// Captures our process's native menu/tooltip content for offscreen contact sheets.
@MainActor
final class NativeOverlayCapture {
    var image: CGImage?
    var hasImage: Bool { image != nil }
    private var isMenu = false
    private var timer: Timer?
    private weak var menu: NSMenu?
    func captureMenu(_ menu: NSMenu,excluding parent: NSWindow,scale: CGFloat) {
        self.menu = menu; isMenu = true
        timer = Timer(timeInterval: 0.12,repeats: false) { [weak self, weak parent] _ in
            MainActor.assumeIsolated {
                guard let self,let parent else { return }
                self.captureVisible(excluding: parent,scale: scale)
                self.menu?.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(timer!,forMode: .eventTracking)
    }
    func captureVisible(excluding parent: NSWindow,scale: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0 !== parent && $0.isVisible && ($0.className.contains("PopupMenu") || $0 is NSPanel) && ($0.contentView?.bounds.width ?? 0) > 0 && ($0.contentView?.bounds.height ?? 0) > 0 }),let view = window.contentView else { return }
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        view.wantsLayer = true; mark(view); OffscreenRenderer.settle(view)
        image = OffscreenRenderer().snapshot(view,scale: scale)
    }
    func composite(_ root: NSView,scale: CGFloat,at origin: CGPoint) -> CGImage {
        guard let image else { return OffscreenRenderer().snapshot(root,scale: scale) }
        let layer = CALayer(); layer.contents = image; layer.contentsScale = scale
        layer.frame = CGRect(origin: origin,size: CGSize(width: CGFloat(image.width)/scale,height: CGFloat(image.height)/scale))
        if isMenu { layer.backgroundColor = Core.popoverBackground.cgColor(root.contentAppearance); layer.cornerRadius = 8; layer.masksToBounds = true }
        root.layer?.addSublayer(layer); defer { layer.removeFromSuperlayer() }
        return OffscreenRenderer().snapshot(root,scale: scale)
    }
}
