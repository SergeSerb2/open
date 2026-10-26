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
    isolated deinit { timer?.invalidate() }
    func captureMenu(_ menu: NSMenu,excluding parent: NSWindow,scale: CGFloat) {
        timer?.invalidate(); image = nil
        self.menu = menu; isMenu = true
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        // menuWillOpen precedes creation of AppKit's popup window. Under load,
        // a fixed delay can expire before that window exists. Wait for the
        // actual native surface; never reopen/retry the menu to obtain a pass.
        timer = Timer(timeInterval: 0.01,repeats: true) { [weak self, weak parent] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let parent else { self.timer?.invalidate(); return }
                if self.captureVisible(excluding: parent,scale: scale) || ProcessInfo.processInfo.systemUptime >= deadline {
                    self.timer?.invalidate(); self.menu?.cancelTrackingWithoutAnimation()
                }
            }
        }
        RunLoop.main.add(timer!,forMode: .eventTracking)
    }
    @discardableResult func captureVisible(excluding parent: NSWindow,scale: CGFloat) -> Bool {
        guard let window = NSApp.windows.first(where: { $0 !== parent && $0.isVisible && ($0.className.contains("PopupMenu") || (!isMenu && $0 is NSPanel)) && ($0.contentView?.bounds.width ?? 0) > 0 && ($0.contentView?.bounds.height ?? 0) > 0 }),let view = window.contentView else { return false }
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        view.wantsLayer = true; mark(view); OffscreenRenderer.settle(view)
        image = OffscreenRenderer().snapshot(view,scale: scale)
        return image != nil
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
