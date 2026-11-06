import AppKit
import OpenDesign

/// Shared borderless child-panel behavior for the theme editor and icon picker.
@MainActor
public class EditorPopoverPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                         backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = false; hasShadow = true; isOpaque = false; backgroundColor = .clear
        isReleasedWhenClosed = false; hidesOnDeactivate = false
    }
    public static func installMaterial(in view: NSView, radius: CGFloat) -> NSVisualEffectView {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius; view.layer?.cornerCurve = .continuous; view.layer?.masksToBounds = true
        let material = NSVisualEffectView(frame: view.bounds)
        material.autoresizingMask = [.width, .height]
        material.material = PopoverMaterial.material; material.blendingMode = .behindWindow; material.state = .active
        view.addSubview(material, positioned: .below, relativeTo: nil)
        return material
    }
}
