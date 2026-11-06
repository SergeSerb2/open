import AppKit
import OpenDesign
import OpenWeb

public enum ExtensionActionIntent {
    case run(String, ExtensionRunSource), closePopup, contextMenu(String, NSEvent?)
}
@MainActor public final class ExtensionActionButton: NSView {
    public private(set) var action: ExtensionActionInfo
    public var onIntent: ((ExtensionActionIntent) -> Void)?
    public var onDrag: ((NSEvent, Bool) -> Void)?
    public var onDragEnd: ((NSEvent) -> Void)?
    public var tooltipStyle: SpaceThemeStyle?
    public private(set) var hovered = false
    public private(set) var pressed = false
    /// In-process acceptance counter: draw calls, not state assignments.
    public private(set) var redrawCount = 0
    private var tracking: NSTrackingArea?
    private var down: CGPoint?
    private var downClosesPopup = false
    private var dragging = false
    private var plate = CALayer()
    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public init(action: ExtensionActionInfo) {
        self.action = action
        super.init(frame: CGRect(origin: .zero, size: ExtensionsMetrics.iconArea))
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        plate.cornerRadius = ChromeMetrics.buttonPlateRadius; plate.cornerCurve = .continuous
        layer?.addSublayer(plate)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        update(action)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() { super.layout(); plate.frame = bounds }
    public func update(_ value: ExtensionActionInfo) {
        guard ExtensionsUIContext.accepts([value]) else { return }
        let changed = action != value
        action = value
        setAccessibilityLabel(value.accessibleName); setAccessibilityIdentifier("extensionAction.\(value.id)")
        updatePlate(animated: false); if changed { needsDisplay = true }
        if hovered && !isHiddenOrHasHiddenAncestor {
            TooltipController.shared.schedule(Tooltip(title: action.tooltip, keys: action.shortcutKeys,
                style: tooltipStyle ?? .defaultTheme(system: contentAppearance)), for: self)
        }
    }
    public func setHovered(_ value: Bool, animated: Bool = true) {
        guard hovered != value else { return }
        hovered = value; updatePlate(animated: animated)
    }
    private func updatePlate(animated: Bool) {
        let color = (pressed || action.isShowingPopup ? SidebarRole.buttonPressed : hovered ? SidebarRole.buttonHover : DesignColor(.clear)).cgColor(contentAppearance)
        guard plate.backgroundColor != color else { return }
        let previous = plate.presentation()?.backgroundColor ?? plate.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true); plate.backgroundColor = color; CATransaction.commit()
        if animated && !Motion.reducesMotion {
            let a = CABasicAnimation(keyPath: "backgroundColor"); a.fromValue = previous; a.toValue = color
            a.duration = Motion.hoverFade; plate.add(a, forKey: "hover")
        }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updatePlate(animated: false); needsDisplay = true }
    public override func draw(_ dirtyRect: NSRect) {
        redrawCount += 1
        guard let image = action.toolbarImage else { return }
        Self.draw(image, centeredIn: bounds, scale: window?.backingScaleFactor ?? 2)
    }
    /// No tint or size mutation. Pick the immutable backing rep, draw at its point size.
    public static func draw(_ image: ExtensionImage, centeredIn rect: CGRect, scale: CGFloat) {
        let destination = CGRect(x: rect.midX - image.pointSize.width / 2, y: rect.midY - image.pointSize.height / 2,
                                 width: image.pointSize.width, height: image.pointSize.height)
        draw(image, in: destination, scale: scale)
    }
    /// Prompt icons have a prescribed frame; action images use the natural-size path above.
    public static func draw(_ image: ExtensionImage, in rect: CGRect, scale: CGFloat, interpolation: CGInterpolationQuality = .none) {
        guard let graphics = NSGraphicsContext.current else { return }
        let context = graphics.cgContext
        context.saveGState(); context.interpolationQuality = interpolation
        if graphics.isFlipped {
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(image.representation(scale: scale), in: CGRect(origin: .zero, size: rect.size))
        } else { context.draw(image.representation(scale: scale), in: rect) }
        context.restoreGState()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    public override func mouseEntered(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        setHovered(true)
        TooltipController.shared.schedule(Tooltip(title: action.tooltip, keys: action.shortcutKeys,
            style: tooltipStyle ?? .defaultTheme(system: contentAppearance)), for: self)
    }
    public override func mouseExited(with event: NSEvent) { setHovered(false); TooltipController.shared.cancel(for: self) }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { TooltipController.shared.cancel(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    public override func mouseDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        down = event.locationInWindow; downClosesPopup = action.isShowingPopup
        dragging = false; pressed = true; updatePlate(animated: true)
        TooltipController.shared.cancel(for: self)
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let begins = !dragging && abs(event.locationInWindow.x - down.x) >= ExtensionsMetrics.dragThreshold
        if begins { dragging = true }
        if dragging { onDrag?(event, begins) }
    }
    public override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil; pressed = false; updatePlate(animated: true)
        if dragging { dragging = false; onDragEnd?(event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            // Making the browser key can close its popup between down and up.
            // This click still toggles that popup; it must not reopen it.
            if downClosesPopup { onIntent?(.closePopup) } else { activate() }
        }
        downClosesPopup = false
    }
    public func activate() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        if action.isShowingPopup { onIntent?(.closePopup) }
        else if action.isEnabled { onIntent?(.run(action.id, .toolbarButton)) }
        else { onIntent?(.contextMenu(action.id, nil)) }
    }
    public override func accessibilityPerformPress() -> Bool { guard !isHiddenOrHasHiddenAncestor else { return false }; activate(); return true }
    public override func rightMouseDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        onIntent?(.contextMenu(action.id, event))
    }
    public func cancelDrag() { down = nil; dragging = false; pressed = false; updatePlate(animated: false) }
}

/// Small plate used by More, Little Open and the SCC pin control. Own drawing;
/// the same capsule tooltip and event-driven fade as the action buttons.
@MainActor public final class ExtensionsPlateButton: NSButton {
    public var glyph: Glyph? { didSet { image = glyph?.image } }
    public var tooltipTitle = ""
    public var tooltipStyle: SpaceThemeStyle?
    public var restingFill: DesignColor? { didSet { plate(animated: false) } }
    private var tracking: NSTrackingArea?
    private var hovered = false
    public override init(frame: NSRect) {
        super.init(frame: frame); title = ""; isBordered = false; wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = ChromeMetrics.buttonPlateRadius
        contentTintColor = SidebarRole.toolbarGlyph.nsColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = t; addTrackingArea(t)
    }
    public override func mouseEntered(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        setHovered(true)
        if !tooltipTitle.isEmpty { TooltipController.shared.schedule(Tooltip(title: tooltipTitle, style: tooltipStyle ?? .defaultTheme(system: contentAppearance)), for: self) }
    }
    public func setHovered(_ value: Bool, animated: Bool = true) {
        guard hovered != value else { return }; hovered = value; plate(animated: animated)
    }
    public override func mouseExited(with event: NSEvent) { setHovered(false); TooltipController.shared.cancel(for: self) }
    public override var isHighlighted: Bool { didSet { plate() } }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); plate(animated: false); needsDisplay = true }
    public override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = CGRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        Self.drawTemplate(image, in: rect, color: SidebarRole.toolbarGlyph.resolved(contentAppearance).nsColor)
    }
    static func drawTemplate(_ image: NSImage, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(color.cgColor); context.fill(rect)
        context.endTransparencyLayer(); context.restoreGState()
    }
    private func plate(animated: Bool = true) {
        guard layer != nil else { return }
        let overlay = (isHighlighted ? SidebarRole.buttonPressed : hovered ? SidebarRole.buttonHover : DesignColor(.clear)).resolved(contentAppearance)
        let color: CGColor
        if let base = restingFill?.resolved(contentAppearance) {
            // Preserve the pin's circular base beneath its transient hover/press plate.
            let alpha = overlay.alpha
            color = RGBA(overlay.red * alpha + base.red * (1 - alpha), overlay.green * alpha + base.green * (1 - alpha),
                         overlay.blue * alpha + base.blue * (1 - alpha), base.alpha + alpha * (1 - base.alpha), overlay.space).cgColor
        } else { color = overlay.cgColor }
        guard layer?.backgroundColor != color else { return }
        let from = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true); layer?.backgroundColor = color; CATransaction.commit()
        if animated && !Motion.reducesMotion {
            let a = CABasicAnimation(keyPath: "backgroundColor"); a.fromValue = from; a.toValue = color
            a.duration = Motion.hoverFade; layer?.add(a, forKey: "hover")
        }
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { TooltipController.shared.cancel(for: self) }; super.viewWillMove(toWindow: newWindow)
    }
}
