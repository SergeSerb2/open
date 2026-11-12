import AppKit
import OpenDesign

/// The area-capture overlay (page-platform §4.6.3, guess pending capture C-C1). It covers the
/// focused page view only, dims everything outside the selection, draws the selection edge and
/// its `W × H` size label, and shows the hint capsule until the drag starts. It draws only when
/// the selection changes; nothing runs while it sits still.
@MainActor
public final class CaptureOverlayView: NSView {
    public enum Outcome: Equatable, Sendable {
        case cancelled
        /// A selection in this view's points (top-left origin), or the whole bounds (Return).
        case selected(CGRect)
    }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The press point (one corner) and the current selection, normalized and clamped to bounds.
    public private(set) var anchor: CGPoint?
    public private(set) var selection: CGRect?
    public private(set) var isFinished = false
    /// Redraw count, for the idle check (no drawing without input).
    public private(set) var drawCount = 0
    public var onFinish: ((Outcome) -> Void)?
    /// Hover element capture (Arc FA CA-4, capture s4 `e6-capture-ui`): asks the page for the
    /// element block under a point (overlay points); nil when there is none. One request runs
    /// at a time; the newest point waits behind it.
    public var elementAt: ((CGPoint, @escaping @MainActor (CGRect?) -> Void) -> Void)?
    /// The hovered element's rectangle (overlay points) while no drag runs.
    public private(set) var hoveredElement: CGRect?
    private var elementRequestInFlight = false
    private var pendingHoverPoint: CGPoint?
    private var hoverTracking: NSTrackingArea?
    public let hint = CaptureHintCapsule(text: CaptureMetrics.hintText)

    public init(frame: CGRect, hintFill: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        // The page view sits in a rounded panel or pane slot: dim only inside its corners.
        layer?.cornerRadius = PanelMetrics.cornerRadius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        hint.fill = hintFill
        addSubview(hint)
        setAccessibilityRole(.group); setAccessibilityLabel("Capture area")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let size = hint.fittingSize
        hint.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: CaptureMetrics.hintTop, width: size.width, height: size.height)
    }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }

    /// Highlights the element under `point` (no drag running). Also the automation entry.
    public func hover(at point: CGPoint) {
        guard !isFinished, anchor == nil, let elementAt else { return }
        guard !elementRequestInFlight else { pendingHoverPoint = point; return }
        elementRequestInFlight = true
        elementAt(clamp(point)) { [weak self] rect in
            guard let self else { return }
            self.elementRequestInFlight = false
            if !self.isFinished, self.anchor == nil {
                let clipped = rect.map { $0.intersection(self.bounds) }.flatMap { $0.isNull || $0.width < 4 || $0.height < 4 ? nil : $0 }
                if clipped != self.hoveredElement { self.hoveredElement = clipped; self.needsDisplay = true }
            }
            if let next = self.pendingHoverPoint { self.pendingHoverPoint = nil; self.hover(at: next) }
        }
    }

    // MARK: Input (the view's own mouse events, and the Cmd+Shift drag that the window forwards)

    public func begin(at point: CGPoint) {
        guard !isFinished else { return }
        pressedElement = hoveredElement
        anchor = clamp(point); selection = CGRect(origin: anchor!, size: .zero)
        hideHint(); needsDisplay = true
    }
    public func drag(to point: CGPoint) {
        guard !isFinished, let anchor else { return }
        let p = clamp(point)
        let rect = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        guard rect != selection else { return }
        selection = rect; needsDisplay = true
    }
    /// The element under the press: a click (no drag) captures it.
    private var pressedElement: CGRect?
    /// Mouse-up: a drag captures its area; a click captures the hovered element (Arc's
    /// "Click or drag…"); a click with no element under it, or a tiny drag, cancels (§4.6.3).
    public func end() {
        guard !isFinished else { return }
        guard let selection, selection.width >= CaptureMetrics.minimumSelection, selection.height >= CaptureMetrics.minimumSelection else {
            if let element = pressedElement, (selection?.width ?? 0) < CaptureMetrics.minimumSelection,
               (selection?.height ?? 0) < CaptureMetrics.minimumSelection {
                finish(.selected(element.integral.intersection(bounds)))
            } else { finish(.cancelled) }
            return
        }
        finish(.selected(selection))
    }
    public func cancel() { finish(.cancelled) }
    /// Return captures the whole visible page.
    public func captureWholePage() { finish(.selected(bounds)) }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        onFinish?(outcome)
    }
    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height)) }
    private func hideHint() {
        guard !hint.isHidden, hint.alphaValue > 0 else { return }
        if Motion.reducesMotion || window?.isVisible != true { hint.alphaValue = 0; hint.isHidden = true; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureMetrics.hintFadeOut
            hint.animator().alphaValue = 0
        } completionHandler: { [weak hint] in MainActor.assumeIsolated { hint?.isHidden = true } }
    }

    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); begin(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    public override func mouseUp(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)); end() }
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: captureWholePage()
        default: super.keyDown(with: event)
        }
    }
    public override func cancelOperation(_ sender: Any?) { cancel() }

    // MARK: Drawing

    /// The size label's frame for the current selection: 6 pt below it, above it when there is
    /// no room below, inside its bottom edge when neither fits.
    public var sizeLabelFrame: CGRect? {
        guard let selection else { return nil }
        let text = Self.sizeText(selection)
        let width = (text.size(withAttributes: [.font: CaptureMetrics.sizeLabelFont.font]).width + CaptureMetrics.sizeLabelPadding * 2).rounded(.up)
        let h = CaptureMetrics.sizeLabelHeight, gap = CaptureMetrics.sizeLabelGap
        let x = min(max(selection.midX - width / 2, 0), max(0, bounds.width - width)).rounded()
        var y = selection.maxY + gap
        if y + h > bounds.height { y = selection.minY - gap - h }
        if y < 0 { y = max(0, selection.maxY - gap - h) }
        return CGRect(x: x, y: y.rounded(), width: width, height: h)
    }
    /// `W × H` in page points.
    public static func sizeText(_ rect: CGRect) -> String { "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))" }

    public override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dim = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptureMetrics.dimAlpha)
        context.setFillColor(dim)
        guard let selection, selection.width > 0, selection.height > 0 else {
            guard let element = hoveredElement else { context.fill(bounds); return }
            // The hovered element stays bright inside a white rounded outline (s4 `e6-capture-ui`).
            let r = CaptureMetrics.elementOutlineRadius
            let hole = CGPath(roundedRect: element, cornerWidth: r, cornerHeight: r, transform: nil)
            context.addRect(bounds); context.addPath(hole); context.fillPath(using: .evenOdd)
            let w = CaptureMetrics.elementOutlineWidth
            context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(w)
            context.addPath(CGPath(roundedRect: element.insetBy(dx: -w / 2, dy: -w / 2), cornerWidth: r + w / 2, cornerHeight: r + w / 2, transform: nil))
            context.strokePath()
            return
        }
        // Everything outside the selection, as one even-odd path (no double dimming at the seams).
        context.addRect(bounds); context.addRect(selection); context.fillPath(using: .evenOdd)
        let w = CaptureMetrics.edgeWidth
        context.setStrokeColor(CaptureMetrics.edgeOuter.cgColor); context.setLineWidth(w)
        context.stroke(selection.insetBy(dx: -w / 2, dy: -w / 2))
        context.setStrokeColor(CaptureMetrics.edgeInner.cgColor)
        context.stroke(selection.insetBy(dx: w / 2, dy: w / 2))
        guard let label = sizeLabelFrame else { return }
        let path = CGPath(roundedRect: label, cornerWidth: CaptureMetrics.sizeLabelRadius, cornerHeight: CaptureMetrics.sizeLabelRadius, transform: nil)
        context.addPath(path); context.setFillColor(CaptureMetrics.sizeLabelFill.cgColor); context.fillPath()
        let font = CaptureMetrics.sizeLabelFont.font
        let monospaced = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium)
        let text = NSAttributedString(string: Self.sizeText(selection), attributes: [.font: monospaced, .foregroundColor: CaptureMetrics.sizeLabelText.nsColor])
        let size = text.size()
        text.draw(at: CGPoint(x: label.midX - size.width / 2, y: label.midY - size.height / 2))
    }
}

/// "Drag to capture. Press Esc to cancel." on the toast fill (§4.6.3).
@MainActor
public final class CaptureHintCapsule: NSView {
    public override var isFlipped: Bool { true }
    public var fill: NSColor = .black { didSet { layer?.backgroundColor = fill.cgColor } }
    private let label: NSTextField
    public var text: String { label.stringValue }
    public init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CaptureMetrics.hintRadius; layer?.cornerCurve = .continuous
        label.font = CaptureMetrics.hintFont.font; label.textColor = .white; label.alignment = .center
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var fittingSize: NSSize {
        NSSize(width: (label.intrinsicContentSize.width + CaptureMetrics.hintPadding * 2).rounded(.up), height: CaptureMetrics.hintHeight)
    }
    public override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
