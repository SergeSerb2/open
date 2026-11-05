import AppKit
import OpenDesign
import OpenWeb

public enum ExtensionItemIntent {
    case run(String, anchor: NSView), togglePin(String), contextMenu(String, anchor: NSView, event: NSEvent?), addExtension
}
@MainActor public final class ExtensionItemView: NSView {
    public enum Style { case row, tile }
    public let style: Style
    public let item: ExtensionItem
    public let isAdd: Bool
    public var tooltipStyle: SpaceThemeStyle? { didSet { pin.tooltipStyle = tooltipStyle } }
    public var onIntent: ((ExtensionItemIntent) -> Void)?
    public var pickerFocused = false { didSet { updateFocusRing() } }
    public private(set) var hovered = false
    private var tracking: NSTrackingArea?
    private var pendingClick = false
    private let focusLayer = CAShapeLayer()
    private let pin = ExtensionsPlateButton(frame: .zero)
    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public init(item: ExtensionItem, style: Style, isAdd: Bool = false) {
        self.item = item; self.style = style; self.isAdd = isAdd
        super.init(frame: .zero); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false; layer?.masksToBounds = false
        focusLayer.fillColor = nil; focusLayer.lineWidth = 2; focusLayer.zPosition = 10
        layer?.addSublayer(focusLayer)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(item.accessibleName)
        setAccessibilityIdentifier(isAdd ? "extensions.add" : "extensionItem.\(item.id)")
        pin.isBordered = false; pin.title = ""; pin.target = self; pin.action = #selector(togglePin)
        pin.setAccessibilityLabel(item.isPinned ? "Unpin" : "Pin")
        pin.tooltipTitle = item.isPinned ? "Unpin" : "Pin"
        addSubview(pin); updatePin()
        if !isAdd {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: item.isPinned ? "Unpin" : "Pin", handler: { [weak self] in
                guard let self else { return false }; self.togglePin(); return true
            })])
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() {
        super.layout(); updateFocusRing()
        pin.frame = style == .row ? CGRect(x: bounds.width - 28, y: 4, width: 24, height: 24) : CGRect(x: 30, y: 0, width: 14, height: 14)
    }
    public func setHovered(_ value: Bool) { hovered = value; updatePin(); needsDisplay = true }
    private func updatePin() {
        pin.isHidden = isAdd || (!item.isPinned && !hovered)
        let image = NSImage(systemSymbolName: item.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.image = image?.withSymbolConfiguration(.init(pointSize: style == .row ? 12 : 8, weight: .regular))
        pin.contentTintColor = SidebarRole.toolbarGlyph.nsColor
        if style == .tile { pin.wantsLayer = true; pin.layer?.cornerRadius = 7; pin.restingFill = Core.backgroundPrimary }
    }
    public override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = style == .row ? 6 : 8
        if hovered { SidebarRole.buttonHover.nsColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
        let imageRect = style == .row ? CGRect(x: 2, y: 2, width: 28, height: 28) : CGRect(x: 8, y: 8, width: 28, height: 28)
        if let image = item.toolbarImage { ExtensionActionButton.draw(image, centeredIn: imageRect, scale: window?.backingScaleFactor ?? 2) }
        if isAdd {
            if let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil) {
                ExtensionsPlateButton.drawTemplate(image, in: imageRect.insetBy(dx: 6, dy: 6),
                    color: SidebarRole.toolbarGlyph.resolved(contentAppearance).nsColor)
            }
        }
        if style == .row {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let font = Typography.extensionName.font
            (item.name as NSString).draw(in: CGRect(x: 36, y: 21 - font.ascender, width: max(0, bounds.width - 70), height: 20),
                withAttributes: [.font: font, .foregroundColor: (item.isEnabled ? Core.foregroundPrimary : Core.foregroundSecondary).nsColor, .paragraphStyle: paragraph])
        }
    }
    private func updateFocusRing() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let radius: CGFloat = style == .row ? 8 : 10
        focusLayer.path = CGPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        focusLayer.strokeColor = Core.focusRing.cgColor(contentAppearance); focusLayer.isHidden = !pickerFocused
        CATransaction.commit()
    }
    @objc private func togglePin() { onIntent?(.togglePin(item.id)) }
    public func activate() { onIntent?(isAdd ? .addExtension : .run(item.id, anchor: self)) }
    public override func accessibilityPerformPress() -> Bool { guard !isHiddenOrHasHiddenAncestor else { return false }; activate(); return true }
    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { pendingClick = true }
    }
    public override func mouseUp(with event: NSEvent) {
        let invoke = pendingClick && bounds.contains(convert(event.locationInWindow, from: nil))
        pendingClick = false
        if invoke { activate() }
    }
    public override func rightMouseDown(with event: NSEvent) { if !isAdd { onIntent?(.contextMenu(item.id, anchor: self, event: event)) } }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = t; addTrackingArea(t)
    }
    public override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        if style == .tile {
            TooltipController.shared.schedule(Tooltip(title: item.name, subtitle: item.tooltip == item.name ? nil : item.tooltip,
                style: tooltipStyle ?? .defaultTheme(system: contentAppearance)), for: self)
        }
    }
    public override func mouseExited(with event: NSEvent) { setHovered(false); TooltipController.shared.cancel(for: self) }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { TooltipController.shared.cancel(for: self) }; super.viewWillMove(toWindow: newWindow)
    }
}
