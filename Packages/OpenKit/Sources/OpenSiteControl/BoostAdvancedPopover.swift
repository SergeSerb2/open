import AppKit
import OpenDesign
import OpenBoosts

@MainActor
public final class BoostAdvancedPopover {
    public let panel: BoostEditorPanel
    public var onClose: (() -> Void)?
    public private(set) var isPresented = false
    public var offscreenMaterial: CGImage? { get { surface.offscreenMaterial } set { surface.offscreenMaterial = newValue } }
    private let parent: NSWindow,anchor: NSView,visibleFrame: CGRect
    private let surface: AdvancedSurface
    private var monitor: Any?
    private var wasKey = false
    init(session: BoostEditorSession,parent: NSWindow,anchor: NSView,visibleFrame: CGRect) {
        self.parent = parent;self.anchor = anchor;self.visibleFrame = visibleFrame
        surface = AdvancedSurface(session: session)
        panel = BoostEditorPanel(contentRect: CGRect(x: 0,y: 0,width: 250,height: 232),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isReleasedWhenClosed = false;panel.backgroundColor = .clear;panel.isOpaque = false;panel.hasShadow = false;panel.appearance = .init(named: .aqua);panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = surface;panel.handleKey = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 { self.close();return true }
            if event.keyCode == 48 {
                let controls = self.surface.sliders,i = controls.firstIndex { self.panel.firstResponder === $0 },step = event.modifierFlags.contains(.shift) ? 2 : 1
                self.panel.makeFirstResponder(controls[i.map { ($0+step)%3 } ?? 0]);return true
            };return false
        }
    }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    public func present() {
        let a = parent.convertToScreen(anchor.convert(anchor.bounds,to: nil)),screen = visibleFrame.insetBy(dx: 8,dy: 8)
        var frame = CGRect(x: a.midX-125.5,y: a.minY-232,width: 250,height: 232)
        frame.origin.x = min(max(frame.minX,screen.minX),screen.maxX-frame.width);frame.origin.y = min(max(frame.minY,screen.minY),screen.maxY-frame.height)
        surface.arrowX = min(max(a.midX-frame.minX,35),215);panel.setFrame(frame,display: true);surface.frame = CGRect(origin: .zero,size: frame.size)
        wasKey = parent.isKeyWindow;isPresented = true;parent.addChildWindow(panel,ordered: .above);panel.orderFront(nil);surface.layoutSubtreeIfNeeded();surface.animate(open: true)
        if wasKey { panel.makeKey();panel.makeFirstResponder(surface.sliders.first) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,self.isPresented,let window = event.window else { return }
                let point = window.convertPoint(toScreen: event.locationInWindow),anchor = self.parent.convertToScreen(self.anchor.convert(self.anchor.bounds,to: nil))
                if !self.panel.frame.contains(point) && !anchor.contains(point) { self.close() }
            }
            return event
        }
    }
    public func refresh() { surface.refresh() }
    public func close(animated: Bool = true) {
        guard isPresented else { return };isPresented = false
        surface.sliders.forEach { $0.finish() }
        if let monitor { NSEvent.removeMonitor(monitor);self.monitor = nil }
        let panel = panel,parent = parent
        let finish: @MainActor @Sendable ()->Void = { parent.removeChildWindow(panel);panel.orderOut(nil);panel.close() }
        if animated { CATransaction.begin();CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } };surface.animate(open: false);CATransaction.commit() } else { finish() }
        if wasKey { parent.makeKey() };onClose?()
    }
}

@MainActor
private final class AdvancedSurface: NSView {
    let sliders: [EditorSlider]
    let session: BoostEditorSession
    var arrowX: CGFloat = 125.5 { didSet { needsLayout = true } }
    private let labels = AdvancedLabels(frame: .zero)
    private let effect = NSVisualEffectView(),surfaceShadow = CALayer(),rim = CAShapeLayer(),mask = CAShapeLayer(),fallback = CALayer()
    var offscreenMaterial: CGImage? { didSet { effect.isHidden = offscreenMaterial != nil;fallback.contents = offscreenMaterial } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    init(session: BoostEditorSession) {
        self.session = session;sliders = [1,0,2].map { EditorSlider(session: session,component: $0) };super.init(frame: .zero);wantsLayer = true
        effect.material = PopoverMaterial.material;effect.blendingMode = PopoverMaterial.blending;effect.state = .active;effect.appearance = .init(named: .aqua);effect.wantsLayer = true;effect.layer?.mask = mask
        layer?.addSublayer(surfaceShadow);addSubview(effect);layer?.addSublayer(fallback);layer?.addSublayer(rim)
        addSubview(labels);sliders.forEach(addSubview);setAccessibilityElement(false);refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout();let path = PopoverShape.path(body: CGRect(x: 14,y: 13,width: 222,height: 205),arrowTip: CGPoint(x: arrowX,y: 2),radius: 12)
        CATransaction.begin();CATransaction.setDisableActions(true)
        effect.frame = bounds;mask.frame = bounds;mask.path = path;fallback.frame = bounds
        let fmask = CAShapeLayer();fmask.path = path;fallback.mask = fmask
        rim.path = path;rim.fillColor = nil;rim.strokeColor = SiteControlColors.rim.cgColor(.light);rim.lineWidth = 1/(window?.backingScaleFactor ?? 1)
        surfaceShadow.frame = bounds;surfaceShadow.shadowPath = path;surfaceShadow.shadowColor = NSColor.black.cgColor;surfaceShadow.shadowOpacity = PopoverMaterial.shadowOpacity;surfaceShadow.shadowRadius = PopoverMaterial.shadowRadius;surfaceShadow.shadowOffset = CGSize(width: 0,height: PopoverMaterial.shadowOffsetY)
        CATransaction.commit()
        labels.frame = bounds
        for (i,slider) in sliders.enumerated() { slider.frame = CGRect(x: 32,y: 60+CGFloat(i)*62,width: 186,height: 16) }
    }
    func refresh() {
        let w = session.displayWheel
        for slider in sliders { let value = slider.component == 2 ? w.originalSaturation*50 : ((slider.component == 0 ? w.brightness : w.contrast)-0.5)*100;slider.doubleValue = value;if slider.isEnabled != session.colorsReady { slider.isEnabled = session.colorsReady } }
    }
    func animate(open: Bool) {
        guard let layer else { return };let frame = layer.frame,point = CGPoint(x: arrowX,y: 2)
        CATransaction.begin();CATransaction.setDisableActions(true);layer.anchorPoint = CGPoint(x: point.x/bounds.width,y: point.y/bounds.height);layer.position = CGPoint(x: frame.minX+point.x,y: frame.minY+point.y);CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity");fade.fromValue = open ? 0 : (layer.presentation()?.opacity ?? 1);fade.toValue = open ? 1 : 0;fade.duration = open ? Motion.popoverOpenFade : Motion.popoverClose;layer.opacity = open ? 1 : 0;layer.add(fade,forKey: "popover.opacity")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a: CABasicAnimation = open ? Motion.popoverOpen.animation(keyPath: "transform.scale") : CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = open ? 0.15 : (layer.presentation()?.transform.m11 ?? 1);a.toValue = open ? 1 : 0.9;a.duration = open ? 0.3 : Motion.popoverClose;layer.add(a,forKey: "popover.scale")
        }
    }
}

@MainActor
private final class AdvancedLabels: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame);wantsLayer = true;setAccessibilityElement(false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        EditorRaster.display(self) {
            for (i,title) in ["Contrast","Brightness","Original Saturation"].enumerated() { SiteControlDrawing.text(title,x: 32,baseline: 53+CGFloat(i)*62,width: 186,font: Typography.editorSlider.font,color: BoostEditorColors.label.nsColor) }
        }
    }
}

@MainActor
final class EditorSlider: NSControl {
    let session: BoostEditorSession,component: Int
    private let owner = BoostEditorInteractionOwner()
    private var value: Double = 50,dragging = false,keyboardFocus = false,pointerFocus = false
    private var end: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(session: BoostEditorSession,component: Int) {
        self.session = session;self.component = component;super.init(frame: .zero);wantsLayer = true;identifier = .init("editor.slider.\(component)")
        setAccessibilityElement(true);setAccessibilityRole(.slider);setAccessibilityLabel(["Brightness","Contrast","Original Saturation"][component]);setAccessibilityMinValue(0);setAccessibilityMaxValue(100)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { end?.cancel() }
    override var doubleValue: Double { get { value } set { let v = min(100,max(0,newValue));if value != v { value = v;needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { EditorRaster.display(self) { paint() } }
    private func change(_ value: Double) {
        doubleValue = value
        _ = session.editWheel(owner: owner) { wheel in let mapped = component == 2 ? doubleValue/50 : 0.5+doubleValue/100;switch component { case 0:wheel.brightness = mapped;case 1:wheel.contrast = mapped;default:wheel.originalSaturation = mapped } }
    }
    private func point(_ event: NSEvent) { change(Double(min(1,max(0,convert(event.locationInWindow,from: nil).x/bounds.width)))*100) }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return };finish();keyboardFocus = false;pointerFocus = true;window?.makeFirstResponder(self);pointerFocus = false;session.beginInteractive(owner: owner);dragging = true;point(event) }
    override func mouseDragged(with event: NSEvent) { if dragging { point(event) } }
    override func mouseUp(with event: NSEvent) { if dragging { point(event);dragging = false;finish() } }
    override func keyDown(with event: NSEvent) { if [123,124,125,126].contains(event.keyCode) { step([124,126].contains(event.keyCode) ? 1 : -1) } else { finish();super.keyDown(with: event) } }
    override func becomeFirstResponder() -> Bool { keyboardFocus = !pointerFocus;needsDisplay = true;return true }
    override func resignFirstResponder() -> Bool { finish();keyboardFocus = false;needsDisplay = true;return true }
    override func setAccessibilityFocused(_ value: Bool) { if !value { finish() };super.setAccessibilityFocused(value) }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityPerformIncrement() -> Bool { step(1);return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { step(-1);return isEnabled }
    func finish() { end?.cancel();end = nil;session.endInteractive(owner: owner) }
    private func step(_ delta: Double) {
        guard isEnabled else { return };keyboardFocus = true;session.beginInteractive(owner: owner);change(value+delta);end?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } };end = work;DispatchQueue.main.asyncAfter(deadline: .now()+1,execute: work)
    }
    private func paint() {
        let track = CGRect(x: 0,y: 6,width: bounds.width,height: 4),x = CGFloat(value/100)*(bounds.width-20)+10
        NSColor(srgbRed: 216/255,green: 216/255,blue: 218/255,alpha: 1).setFill();NSBezierPath(roundedRect: track,xRadius: 2,yRadius: 2).fill()
        NSColor(srgbRed: 169/255,green: 169/255,blue: 171/255,alpha: 1).setFill();NSBezierPath(roundedRect: CGRect(x: 0,y: 6,width: x,height: 4),xRadius: 2,yRadius: 2).fill()
        NSGraphicsContext.saveGraphicsState();let shadow = NSShadow();shadow.shadowColor = .black.withAlphaComponent(0.15);shadow.shadowBlurRadius = 1.5;shadow.shadowOffset = CGSize(width: 0,height: -0.5);shadow.set()
        NSColor.white.setFill();NSBezierPath(roundedRect: CGRect(x: x-10,y: 0,width: 20,height: 16),xRadius: 8,yRadius: 8).fill();NSGraphicsContext.restoreGraphicsState()
        if keyboardFocus && window?.firstResponder === self { Core.focusRing.nsColor.setStroke();let focus = NSBezierPath(roundedRect: CGRect(x: x-12,y: -2,width: 24,height: 20),xRadius: 10,yRadius: 10);focus.lineWidth = 2;focus.stroke() }
    }
}
