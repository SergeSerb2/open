import AppKit
import OpenDesign

/// Same capsule/keycap recipe as OpenSidebar, without a dependency on that target.
@MainActor
final class SiteControlTooltip {
    static let shared = SiteControlTooltip()
    private var pending: DispatchWorkItem?
    private var panel: NSPanel?
    private weak var owner: NSView?

    func schedule(_ text: String?, for view: NSView) {
        hide()
        guard let text, !text.isEmpty, view.window?.isVisible == true else { return }
        owner = view
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.owner === view, !view.isHiddenOrHasHiddenAncestor else { return }
                self.pending = nil; self.show(text, for: view)
            }
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + TooltipMetrics.showDelay, execute: work)
    }
    func hide(for view: NSView? = nil) {
        guard view == nil || owner === view else { return }
        pending?.cancel(); pending = nil; owner = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.tooltipFade; panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        })
    }
    private func show(_ text: String, for view: NSView) {
        guard let window = view.window, window.isVisible else { return }
        let content = SiteControlTooltipView(text)
        let margin = TooltipMetrics.shadowMargin
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.panel = panel
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(x: 0, y: 0, width: content.frame.width + 2 * margin, height: content.frame.height + 2 * margin))
        host.wantsLayer = true; content.setFrameOrigin(CGPoint(x: margin, y: margin))
        content.shadow = {
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(SiteControlMetrics.shadowOpacity))
            shadow.shadowBlurRadius = SiteControlTooltipMetrics.shadowRadius; shadow.shadowOffset = CGSize(width: 0, height: -SiteControlTooltipMetrics.shadowOffset)
            return shadow
        }()
        host.addSubview(content); panel.contentView = host
        let screen = window.screen?.visibleFrame
        let x = min(max(anchor.midX - content.frame.width / 2 - margin, (screen?.minX ?? 0) - margin), (screen?.maxX ?? .greatestFiniteMagnitude) - host.frame.width + margin)
        panel.setFrame(CGRect(x: x, y: anchor.minY - TooltipMetrics.anchorGap - content.frame.height - margin, width: host.frame.width, height: host.frame.height), display: true)
        window.addChildWindow(panel, ordered: .above); panel.alphaValue = 0; panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in context.duration = Motion.tooltipFade; panel.animator().alphaValue = 1 }
    }
}

@MainActor
private final class SiteControlTooltipView: NSView {
    private let caption: String
    private let keys: [String]
    override var isFlipped: Bool { true }
    init(_ text: String) {
        if text.hasSuffix(" (⇧⌘C)") { caption = String(text.dropLast(" (⇧⌘C)".count)); keys = ["⇧", "⌘", "C"] }
        else if text.hasSuffix(" (⇧⌘2)") { caption = String(text.dropLast(" (⇧⌘2)".count)); keys = ["⇧", "⌘", "2"] }
        else { caption = text; keys = [] }
        super.init(frame: .zero); wantsLayer = true
        let label = (caption as NSString).size(withAttributes: [.font: Typography.tooltip.font]).width
        let caps = keys.map(keyWidth).reduce(0, +) + CGFloat(max(0, keys.count - 1)) * TooltipMetrics.keycapGap
        frame.size = CGSize(width: ceil(label) + (keys.isEmpty ? 0 : caps + TooltipMetrics.labelToKeycaps) + 2 * (TooltipMetrics.horizontalPadding + SiteControlTooltipMetrics.extraPadding), height: TooltipMetrics.height)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private func keyWidth(_ key: String) -> CGFloat {
        max(TooltipMetrics.keycapMinWidth, ceil((key as NSString).size(withAttributes: [.font: Typography.keycap.font]).width) + SiteControlTooltipMetrics.keyPadding)
    }
    override func draw(_ dirtyRect: NSRect) {
        SiteControlColors.tooltipFill.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let padding = TooltipMetrics.horizontalPadding + SiteControlTooltipMetrics.extraPadding
        SiteControlDrawing.text(caption, x: padding, baseline: SiteControlTooltipMetrics.titleBaseline, width: bounds.width - 2 * padding, font: Typography.tooltip.font, color: SiteControlColors.tooltipText.nsColor)
        var x = padding + ceil((caption as NSString).size(withAttributes: [.font: Typography.tooltip.font]).width) + TooltipMetrics.labelToKeycaps
        for key in keys {
            let width = keyWidth(key)
            let rect = CGRect(x: x, y: (bounds.height - TooltipMetrics.keycapHeight) / 2, width: width, height: TooltipMetrics.keycapHeight)
            SiteControlColors.tooltipText.withAlpha(Double(SiteControlTooltipMetrics.keyAlpha)).nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: TooltipMetrics.keycapRadius, yRadius: TooltipMetrics.keycapRadius).fill()
            SiteControlDrawing.text(key, x: rect.minX, baseline: rect.midY + (Typography.keycap.font.ascender + Typography.keycap.font.descender) / 2, width: rect.width, font: Typography.keycap.font, color: SiteControlColors.tooltipText.nsColor, alignment: .center)
            x += width + TooltipMetrics.keycapGap
        }
    }
}
