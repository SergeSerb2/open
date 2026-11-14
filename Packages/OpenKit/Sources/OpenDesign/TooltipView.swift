import AppKit

/// Arc-style tooltip content: a capsule in the Space's title color with a label,
/// an optional second line, and keycaps (docs/re/interaction-states.md §5).
public struct Tooltip: Equatable {
    public enum Placement: Equatable { case below, above, beside }
    public var showDelay: TimeInterval
    public var title: String
    public var subtitle: String?
    public var keys: [String]
    public var placement: Placement
    public var fill: RGBA
    public var text: RGBA
    public var keycap: RGBA

    public init(title: String, subtitle: String? = nil, keys: [String] = [], placement: Placement = .below, style: SpaceThemeStyle, showDelay: TimeInterval = TooltipMetrics.showDelay) {
        self.showDelay = showDelay
        self.title = title; self.subtitle = subtitle; self.keys = keys; self.placement = placement
        fill = style.tooltipFill; text = style.tooltipText; keycap = style.tooltipKeycap
    }
}

/// The capsule itself. Sized by `fittingSize`; drawn with plain layers and text.
@MainActor
public final class TooltipView: NSView {
    public var tooltip: Tooltip { didSet { needsLayout = true; needsDisplay = true } }

    public init(tooltip: Tooltip) {
        self.tooltip = tooltip
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        frame.size = fittingSize
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    private var titleFont: NSFont { Typography.tooltip.font }
    private var keyFont: NSFont { Typography.keycap.font }

    private func keyWidth(_ k: String) -> CGFloat {
        max(TooltipMetrics.keycapMinWidth, ceil((k as NSString).size(withAttributes: [.font: keyFont]).width) + 8)
    }

    public override var fittingSize: NSSize {
        let m = TooltipMetrics.self
        var w = ceil((tooltip.title as NSString).size(withAttributes: [.font: titleFont]).width)
        if !tooltip.keys.isEmpty {
            w += m.labelToKeycaps + tooltip.keys.map(keyWidth).reduce(0, +) + CGFloat(tooltip.keys.count - 1) * m.keycapGap
        }
        if let sub = tooltip.subtitle {
            w = max(w, ceil((sub as NSString).size(withAttributes: [.font: Typography.tooltipSubtitle.font]).width))
        }
        let h = tooltip.subtitle == nil ? m.height : m.twoLineHeight
        return NSSize(width: w + 2 * m.horizontalPadding + (tooltip.subtitle == nil ? 2 : 6), height: h)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = TooltipMetrics.self
        let b = bounds
        let radius = tooltip.subtitle == nil ? b.height / 2 : 14
        tooltip.fill.nsColor.setFill()
        NSBezierPath(roundedRect: b, xRadius: radius, yRadius: radius).fill()
        let textColor = tooltip.text.nsColor
        let pad = m.horizontalPadding + (tooltip.subtitle == nil ? 1 : 3)
        let titleBaseline: CGFloat = tooltip.subtitle == nil ? 18 : 17
        (tooltip.title as NSString).draw(at: NSPoint(x: pad, y: titleBaseline - titleFont.ascender),
                                         withAttributes: [.font: titleFont, .foregroundColor: textColor])
        if let sub = tooltip.subtitle {
            let f = Typography.tooltipSubtitle.font
            (sub as NSString).draw(at: NSPoint(x: pad, y: 32 - f.ascender),
                                   withAttributes: [.font: f, .foregroundColor: textColor.withAlphaComponent(0.6)])
        }
        guard !tooltip.keys.isEmpty else { return }
        var x = pad + ceil((tooltip.title as NSString).size(withAttributes: [.font: titleFont]).width) + m.labelToKeycaps
        let capY = (m.height - m.keycapHeight) / 2
        for k in tooltip.keys {
            let w = keyWidth(k)
            let cap = NSRect(x: x, y: capY, width: w, height: m.keycapHeight)
            tooltip.keycap.nsColor.setFill()
            NSBezierPath(roundedRect: cap, xRadius: m.keycapRadius, yRadius: m.keycapRadius).fill()
            let s = (k as NSString).size(withAttributes: [.font: keyFont])
            (k as NSString).draw(at: NSPoint(x: cap.midX - s.width / 2, y: cap.midY - s.height / 2),
                                 withAttributes: [.font: keyFont, .foregroundColor: textColor])
            x += w + m.keycapGap
        }
    }
}


/// Shows one tooltip at a time in a borderless child panel after a hover delay.
@MainActor
public final class TooltipController {
    public static let shared = TooltipController()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private weak var owner: NSView?
    private var scheduledTooltip: Tooltip?
    /// Bumped by every show, so a fade-out that finishes after a newer show leaves that tooltip up.
    private var presentation = 0
    public private(set) var scheduleCount = 0
    public private(set) var showCount = 0
    public var visibleOrPendingTooltip: Tooltip? { scheduledTooltip }
    /// Read-back for the real tooltip harness flow.
    public var visibleTooltipView: TooltipView? { panel?.isVisible == true ? panel?.contentView?.subviews.compactMap { $0 as? TooltipView }.first : nil }
    public var visibleTooltip: Tooltip? { visibleTooltipView?.tooltip }

    public func schedule(_ tooltip: Tooltip, for view: NSView, at point: NSPoint? = nil) {
        if owner === view, scheduledTooltip == tooltip, pending != nil || panel?.isVisible == true { return }
        cancel(for: owner)
        owner = view
        scheduledTooltip = tooltip
        scheduleCount += 1
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.owner === view else { return }
                self.pending = nil
                self.show(tooltip, for: view, at: point)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tooltip.showDelay, execute: work)
    }

    public func cancel(for view: NSView?) {
        guard view == nil || owner === view else { return }
        pending?.cancel(); pending = nil
        owner = nil
        scheduledTooltip = nil
        guard let panel else { return }
        let fading = presentation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.tooltipFade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentation == fading else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func show(_ tooltip: Tooltip, for view: NSView, at point: NSPoint?) {
        guard let window = view.window else { return }
        showCount += 1
        presentation += 1
        let content = TooltipView(tooltip: tooltip)
        let size = content.fittingSize
        let margin = TooltipMetrics.shadowMargin
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin: NSPoint
        switch tooltip.placement {
        case .below: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - TooltipMetrics.anchorGap - size.height)
        case .above: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + TooltipMetrics.anchorGap)
        case .beside:
            let p = point.map { window.convertPoint(toScreen: view.convert($0, to: nil)) } ?? NSPoint(x: anchor.midX, y: anchor.minY)
            origin = NSPoint(x: p.x + 12, y: p.y - size.height - 14)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin))
        host.wantsLayer = true
        content.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        content.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
        host.addSubview(content)
        panel.contentView = host
        panel.setFrame(NSRect(x: origin.x - margin, y: origin.y - margin, width: host.frame.width, height: host.frame.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above)
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.tooltipFade
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let p = TooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        return p
    }
}

@MainActor private final class TooltipPanel: NSPanel {}
