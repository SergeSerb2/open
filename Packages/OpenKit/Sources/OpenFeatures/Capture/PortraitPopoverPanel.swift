import AppKit
import OpenDesign

/// The Portrait Mode popover's chrome (LEAD 13:40 look review): a light card with a faint lavender
/// tint, about 20 pt corners, a soft shadow and an arrow on the side facing the anchor. NSPopover's
/// system background cannot take that tint, so Open draws the card in its own borderless panel.
@MainActor
public final class PortraitPopoverChrome: NSView {
    public enum Side { case left, right }
    /// Where the card sits relative to the anchor; the arrow points the other way.
    public var side: Side = .left { didSet { needsLayout = true; needsDisplay = true } }
    public let content: NSView
    static let arrowLength: CGFloat = 9, arrowBase: CGFloat = 20, radius: CGFloat = 20
    /// Room around the card for its shadow.
    static let shadowPad: CGFloat = 24

    public init(content: NSView) {
        self.content = content
        let size = content.frame.size
        super.init(frame: CGRect(x: 0, y: 0, width: size.width + Self.arrowLength + Self.shadowPad * 2, height: size.height + Self.shadowPad * 2))
        wantsLayer = true
        addSubview(content)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override public var isFlipped: Bool { true }

    /// The card's rect (without the arrow) in this view.
    public var cardRect: CGRect {
        let size = content.frame.size
        let x = side == .left ? Self.shadowPad : Self.shadowPad + Self.arrowLength
        return CGRect(x: x, y: Self.shadowPad, width: size.width, height: size.height)
    }
    /// The arrow's tip in this view.
    public var arrowTip: CGPoint {
        let card = cardRect
        return CGPoint(x: side == .left ? card.maxX + Self.arrowLength : card.minX - Self.arrowLength, y: card.midY)
    }

    override public func layout() { super.layout(); content.frame.origin = cardRect.origin }

    static func fill(dark: Bool) -> NSColor {
        // A faint lavender, close to the default sidebar colour (GUESS values from the capture crop).
        dark ? NSColor(srgbRed: 0.205, green: 0.196, blue: 0.245, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.953, blue: 0.992, alpha: 1)
    }

    func shape() -> NSBezierPath {
        let card = cardRect, r = Self.radius, half = Self.arrowBase / 2, tip = arrowTip
        let path = NSBezierPath(roundedRect: card, xRadius: r, yRadius: r)
        let arrow = NSBezierPath()
        let baseX = side == .left ? card.maxX - 1 : card.minX + 1
        arrow.move(to: CGPoint(x: baseX, y: tip.y - half))
        // Soft shoulders into a rounded tip.
        arrow.curve(to: CGPoint(x: tip.x, y: tip.y), controlPoint1: CGPoint(x: (baseX + tip.x) / 2, y: tip.y - half * 0.55),
                    controlPoint2: CGPoint(x: tip.x, y: tip.y - 2))
        arrow.curve(to: CGPoint(x: baseX, y: tip.y + half), controlPoint1: CGPoint(x: tip.x, y: tip.y + 2),
                    controlPoint2: CGPoint(x: (baseX + tip.x) / 2, y: tip.y + half * 0.55))
        arrow.close()
        path.append(arrow)
        return path
    }

    override public func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let path = shape()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.45 : 0.18); shadow.set()
        Self.fill(dark: dark).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Hairline edge.
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.10 : 0.06).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// A borderless child panel that shows the chrome next to an anchor point and closes on Esc or a
/// click outside it.
@MainActor
public final class PortraitPopoverPanel {
    final class Panel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }
    public let chrome: PortraitPopoverChrome
    let panel: Panel
    private var monitor: Any?
    private weak var parent: NSWindow?
    public var onClose: (() -> Void)?

    public init(content: NSView) {
        chrome = PortraitPopoverChrome(content: content)
        panel = Panel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.contentView = chrome
        panel.onCancel = { [weak self] in self?.close() }
    }

    public var isShown: Bool { panel.isVisible }
    /// The card (without arrow and shadow room) in screen coordinates.
    public var cardFrameInScreen: CGRect {
        let card = chrome.cardRect
        return CGRect(x: panel.frame.minX + card.minX, y: panel.frame.maxY - card.maxY, width: card.width, height: card.height)
    }

    /// `anchor`: a point in screen coordinates on the page's sidebar-side edge. The card goes to
    /// the anchor's left (over the sidebar) when the screen has room, else to its right.
    public func show(anchor: CGPoint, in window: NSWindow) {
        let size = chrome.frame.size, visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let leftOrigin = anchor.x - (size.width - PortraitPopoverChrome.shadowPad)
        chrome.side = leftOrigin + PortraitPopoverChrome.shadowPad >= visible.minX ? .left : .right
        chrome.layoutSubtreeIfNeeded()
        let tip = chrome.arrowTip
        var origin = CGPoint(x: anchor.x - tip.x, y: anchor.y - (size.height - tip.y))
        origin.y = min(max(origin.y, visible.minY - PortraitPopoverChrome.shadowPad), visible.maxY - size.height + PortraitPopoverChrome.shadowPad)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        parent = window
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.close() }
            return event
        }
    }

    public func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        guard panel.isVisible || panel.parent != nil else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        let done = onClose; onClose = nil; done?()
    }
}
