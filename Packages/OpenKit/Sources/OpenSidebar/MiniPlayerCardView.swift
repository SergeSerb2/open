import AppKit
import OpenDesign
import OpenMedia
import OpenModel
import Symbols

@MainActor public final class MiniPlayerCardView: NSView {
    public let source: MediaSource
    public let marquee = MarqueeLabel(frame: .zero)
    private let context: SidebarContext
    private var stackEdge: CALayer?
    public var isRetiring = false
    public var showsStackEdge = false { didSet { if showsStackEdge != oldValue { needsLayout = true } } }
    private let favicon = FaviconView()
    private let titleHit = MiniPlayerTitleHitView(frame: .zero)
    private var buttons: [String: MediaControlButton] = [:]
    private let slider = MediaVolumeSlider(frame: .zero)
    private var observation: ObservationLoop?
    private var tracking: NSTrackingArea?
    private var pointerInside = false, pointerOnTitle = false
    private var pressed = false
    public var onHeightChange: (() -> Void)?
    public var cardHeight: CGFloat { MiniPlayerMetrics.height + (drawerIsOpen ? MiniPlayerMetrics.drawerHeight : 0) }
    public var drawerIsOpen: Bool {
        guard source.kind != .recording, let id = source.tabID, context.mediaDrawers.contains(id) else { return false }
        return source.volume != nil
    }
    public var isCardHovered: Bool {
        if let forced = context.forcedMediaHover {
            switch forced { case .card(let id), .title(let id): return id == source.tabID; case .stack: return false }
        }
        return pointerInside
    }
    private var isTitleHovered: Bool {
        if let forced = context.forcedMediaHover { if case .title(let id) = forced { return id == source.tabID }; return false }
        return pointerInside && pointerOnTitle
    }
    public init(source: MediaSource, context: SidebarContext) {
        self.source = source; self.context = context
        super.init(frame: .zero); wantsLayer = true; layer?.cornerCurve = .continuous
        layer?.cornerRadius = MiniPlayerMetrics.cornerRadius
        favicon.context = context; favicon.tab = source.tabID.flatMap { context.model.tab(id: $0) }
        addSubview(titleHit); titleHit.addSubview(favicon); titleHit.addSubview(marquee)
        titleHit.action = { [weak self] in self?.send(MediaIntent.backToTab) }
        titleHit.label = { [weak self] in "Back to Tab, " + (self?.tab?.displayTitle ?? "") }
        makeButton("pip", glyph: .mediaPiP, title: "Open Picture in Picture") { [weak self] in self?.send(MediaIntent.openPictureInPicture) }
        makeButton("close", glyph: .mediaClose, title: "Close Mini Player") { [weak self] in self?.send(MediaIntent.close) }
        makeButton("previous", glyph: .mediaPrevious, title: "Previous Track") { [weak self] in self?.send(MediaIntent.previousTrack) }
        makeButton("play", glyph: .mediaPause, title: "Pause") { [weak self] in
            guard let self else { return }; self.send(self.source.playback == .playing ? MediaIntent.pause : MediaIntent.play)
        }
        makeButton("next", glyph: .mediaNext, title: "Next Track") { [weak self] in self?.send(MediaIntent.nextTrack) }
        makeButton("volume", glyph: .mediaVolume, title: "Adjust Tab Volume") { [weak self] in
            guard let self, let id = self.source.tabID else { return }
            if self.source.volume == nil { self.send(MediaIntent.toggleMute) }
            else {
                if self.context.mediaDrawers.contains(id) { self.context.mediaDrawers.remove(id) } else { self.context.mediaDrawers.insert(id) }
                self.sync(); self.onHeightChange?()
            }
        }
        makeButton("microphone", glyph: .mediaMicrophone, title: "Toggle Microphone") { [weak self] in self?.send(MediaIntent.toggleMicrophone) }
        makeButton("camera", glyph: .mediaCamera, title: "Toggle Camera") { [weak self] in self?.send(MediaIntent.toggleCamera) }
        makeButton("volumeLow", glyph: .mediaVolumeLow, title: "Mute") { [weak self] in self?.send(MediaIntent.toggleMute) }
        makeButton("volumeHigh", glyph: .mediaVolumeHigh, title: "Set Tab Volume to 100%") { [weak self] in self?.setVolume(1) }
        slider.onValue = { [weak self] value in self?.setVolume(value) }; addSubview(slider)
        observation = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.source.playback; _ = self.source.actions; _ = self.source.hasVideo; _ = self.source.kind
            _ = self.source.isMuted
            if self.source.kind == .recording { _ = self.source.microphoneOn; _ = self.source.cameraOn }
            if self.drawerIsOpen { _ = self.source.volume }
            _ = self.context.focusedSpace?.theme; _ = self.context.systemAppearance
            _ = self.context.mediaDrawers; _ = self.context.forcedMediaHover; _ = self.tab?.displayTitle
        }) { [weak self] in self?.sync(); self?.onHeightChange?() }
        sync()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observation?.cancel() }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { !isRetiring && marquee.isExposed ? super.hitTest(point) : nil }
    private var tab: Tab? { source.tabID.flatMap { context.model.tab(id: $0) } }
    private var titleColor: NSColor {
        guard let space = context.focusedSpace else { return .labelColor }
        return context.style(for: space).titleColor(context.appearance(for: space)).nsColor
    }
    private func send(_ intent: (ItemID) -> MediaIntent) { if let id = source.tabID { context.send(.media(intent(id))) } }
    private func setVolume(_ value: Double) { if let id = source.tabID { context.send(.media(.setVolume(id, value))) } }
    /// Real controls for harness events and the later app automation adapter.
    public func control(named id: String) -> (view: NSView, glyph: Glyph?, tooltip: Tooltip?)? {
        guard let button = buttons[id] else { return nil }
        return (button, button.displayedGlyph, button.tooltip?())
    }
    private func makeButton(_ id: String, glyph: Glyph, title: String, action: @escaping @MainActor () -> Void) {
        let button = MediaControlButton(glyph: glyph); button.context = context
        button.glyphTint = { _ in SidebarRole.mediaControlGlyph.nsColor }
        button.accessibleTitle = { title }; button.action = action
        button.setAccessibilityIdentifier("media." + id)
        button.tooltip = { [weak context, weak button] in
            guard let context, let space = context.focusedSpace else { return nil }
            return Tooltip(title: button?.accessibleTitle?() ?? title, placement: .above, style: context.style(for: space), showDelay: MiniPlayerMetrics.tooltipDelay)
        }
        buttons[id] = button; addSubview(button)
    }
    private func sync() {
        let recording = source.kind == .recording
        buttons["previous"]?.isHidden = recording || !source.actions.contains(.previousTrack)
        buttons["next"]?.isHidden = recording || !source.actions.contains(.nextTrack)
        buttons["play"]?.isHidden = recording
        buttons["volume"]?.isHidden = recording
        buttons["microphone"]?.isHidden = !recording || !source.actions.contains(.toggleMicrophone)
        buttons["camera"]?.isHidden = !recording || !source.actions.contains(.toggleCamera)
        buttons["pip"]?.isHidden = !source.hasVideo
        if let close = buttons["close"] {
            let target: CGFloat = isCardHovered ? 1 : 0, old = close.alphaValue
            CATransaction.begin(); CATransaction.setDisableActions(true); close.alphaValue = target; CATransaction.commit()
            if old != target && animatesMediaChanges {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = old; fade.toValue = target
                fade.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : Motion.miniPlayerReveal
                close.layer?.add(fade, forKey: "media.closeOpacity")
            }
        }
        buttons["play"]?.setGlyph(source.playback == .playing ? .mediaPause : .mediaPlay)
        buttons["play"]?.accessibleTitle = { [weak source] in source?.playback == .playing ? "Pause" : "Play" }
        buttons["volume"]?.setGlyph(source.isMuted ? .mediaVolumeMuted : .mediaVolume)
        if recording {
            buttons["microphone"]?.setGlyph(source.microphoneOn == false ? .mediaMicrophoneMuted : .mediaMicrophone)
            buttons["camera"]?.setGlyph(source.cameraOn == false ? .mediaCameraOff : .mediaCamera)
        }
        buttons["volumeLow"]?.isHidden = !drawerIsOpen; buttons["volumeHigh"]?.isHidden = !drawerIsOpen; slider.isHidden = !drawerIsOpen
        if drawerIsOpen { slider.value = source.volume ?? 1 }
        marquee.configure(text: isTitleHovered ? "Back to Tab" : (tab?.displayTitle ?? ""), color: titleColor,
                          playing: source.playback == .playing, titleHovered: isTitleHovered)
        CATransaction.begin()
        CATransaction.setDisableActions(!animatesMediaChanges)
        CATransaction.setAnimationDuration(Motion.hoverFade)
        layer?.backgroundColor = (isCardHovered ? SidebarRole.miniPlayerHoverFill : SidebarRole.miniPlayerFill).cgColor(contentAppearance)
        layer?.borderWidth = SidebarDiagnostics.mediaIncreasesContrast ? 1 : 0
        layer?.borderColor = SidebarColors.separator.cgColor(contentAppearance)
        CATransaction.commit()
        stackEdge?.backgroundColor = SidebarColors.separator.cgColor(contentAppearance)
        needsLayout = true
    }
    public override func layout() {
        super.layout()
        let m = MiniPlayerMetrics.self, w = bounds.width, hovered = isCardHovered
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if showsStackEdge {
            let edge = stackEdge ?? CALayer()
            if stackEdge == nil { layer?.addSublayer(edge); stackEdge = edge }
            edge.backgroundColor = SidebarColors.separator.cgColor(contentAppearance)
            edge.frame = CGRect(x: m.cornerRadius, y: 0, width: max(0, w - 2 * m.cornerRadius), height: m.stackEdge)
        } else { stackEdge?.removeFromSuperlayer(); stackEdge = nil }
        titleHit.frame = CGRect(x: 0, y: 0, width: w, height: m.titleRowHeight)
        favicon.frame = m.favicon
        let closeWidth = hovered ? m.button : 0
        if let close = buttons["close"] {
            let previous = close.frame
            close.frame = CGRect(x: w - m.rightButtonInset, y: m.titleButtonY, width: closeWidth, height: m.button)
            if previous.width != closeWidth && animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion {
                let a = CABasicAnimation(keyPath: "bounds.size.width"); a.fromValue = previous.width; a.toValue = closeWidth; a.duration = Motion.miniPlayerReveal
                close.layer?.add(a, forKey: "media.closeWidth")
            }
        }
        buttons["pip"]?.frame = CGRect(x: w - m.rightButtonInset - (hovered ? m.rightButtonPitch : 0), y: m.titleButtonY, width: m.button, height: m.button)
        let rightButtons = (source.hasVideo ? 1 : 0) + (hovered ? 1 : 0)
        marquee.frame = CGRect(x: m.titleX, y: 0, width: max(0, w - m.titleTrailing - CGFloat(rightButtons) * m.rightButtonPitch - m.titleX), height: m.titleRowHeight)
        var x = m.controlsInset
        for id in ["previous", "play", "next"] where buttons[id]?.isHidden == false {
            buttons[id]?.frame = CGRect(x: x, y: m.controlsY, width: m.button, height: m.button); x += m.controlsPitch
        }
        buttons["volume"]?.frame = CGRect(x: w - m.rightButtonInset, y: m.controlsY, width: m.button, height: m.button)
        x = m.controlsInset
        for id in ["microphone", "camera"] where buttons[id]?.isHidden == false {
            buttons[id]?.frame = CGRect(x: x, y: m.controlsY, width: m.button, height: m.button); x += m.controlsPitch
        }
        buttons["volumeLow"]?.frame = CGRect(x: m.drawerIconX, y: m.drawerIconY, width: m.drawerIcon, height: m.drawerIcon)
        buttons["volumeHigh"]?.frame = CGRect(x: w - m.drawerTrailingIconInset, y: m.drawerIconY, width: m.drawerIcon, height: m.drawerIcon)
        slider.frame = CGRect(x: m.drawerSliderX, y: m.drawerSliderY, width: max(0, w - 2 * m.drawerSliderX), height: m.drawerSliderHeight)
        CATransaction.commit()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { pointerInside = true; pointerOnTitle = convert(event.locationInWindow, from: nil).y < MiniPlayerMetrics.titleRowHeight; sync() }
    public override func mouseMoved(with event: NSEvent) { pointerOnTitle = convert(event.locationInWindow, from: nil).y < MiniPlayerMetrics.titleRowHeight; sync() }
    public override func mouseExited(with event: NSEvent) { pointerInside = false; pointerOnTitle = false; sync() }
    public override func mouseDown(with event: NSEvent) { pressed = true }
    public override func mouseUp(with event: NSEvent) { if pressed && bounds.contains(convert(event.locationInWindow, from: nil)) { send(MediaIntent.backToTab) }; pressed = false }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); sync() }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRoleDescription() -> String? { "media controls" }
    public override func accessibilityIdentifier() -> String { "media.miniPlayer." + (source.tabID?.description ?? "auxiliary") }
    public override func accessibilityLabel() -> String? {
        let state = source.isMuted ? "Muted" : (source.playback == .playing ? "Playing" : "Paused")
        return [tab?.displayTitle ?? "", tab?.url.host ?? "", state].joined(separator: ", ")
    }
}

@MainActor private final class MiniPlayerTitleHitView: NSView {
    var action: (() -> Void)?, label: (() -> String)?
    private var pressed = false
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        if pressed && bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
        pressed = false
    }
    override var isFlipped: Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { label?() }
    override func accessibilityIdentifier() -> String { "media.title" }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}

/// Fixed-frame system play/pause replacement; other controls draw the standard glyph.
@MainActor private final class MediaSymbolImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor private final class MediaControlButton: PlateButton {
    private var currentGlyph: Glyph?
    private var symbol: MediaSymbolImageView?
    var displayedGlyph: Glyph? { currentGlyph ?? glyphView.glyph }
    func setGlyph(_ glyph: Glyph) {
        guard let image = glyph.image else { return }
        let isPlayback = glyph == .mediaPlay || glyph == .mediaPause
        if isPlayback && !SidebarDiagnostics.mediaReducesMotion {
            let view = symbol ?? {
                let view = MediaSymbolImageView(frame: bounds)
                view.wantsLayer = true; view.imageScaling = .scaleNone
                addSubview(view); symbol = view; needsLayout = true
                return view
            }()
            glyphView.isHidden = true
            view.contentTintColor = SidebarRole.mediaControlGlyph.nsColor
            if currentGlyph != nil && currentGlyph != glyph && animatesMediaChanges {
                view.setSymbolImage(image, contentTransition: .replace)
            } else if view.image !== image { view.image = image }
        } else {
            symbol?.removeFromSuperview(); symbol = nil
            glyphView.isHidden = false; glyphView.glyph = glyph
        }
        currentGlyph = glyph
    }
    override func layout() {
        super.layout()
        if symbol?.frame != bounds { symbol?.frame = bounds }
    }
    override func accessibilityHelp() -> String? { accessibleTitle?() }
}

@MainActor private final class MediaVolumeSlider: NSView {
    var value: Double = 1 { didSet { needsDisplay = true } }
    var onValue: ((Double) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 0, y: MiniPlayerMetrics.drawerTrackY, width: bounds.width, height: MiniPlayerMetrics.drawerTrackHeight)
        SidebarColors.separator.nsColor.setFill(); NSBezierPath(roundedRect: track, xRadius: MiniPlayerMetrics.drawerTrackRadius, yRadius: MiniPlayerMetrics.drawerTrackRadius).fill()
        let knob = MiniPlayerMetrics.drawerKnob
        let x = knob / 2 + CGFloat(min(1, max(0, value))) * max(0, bounds.width - knob)
        var fill = track; fill.size.width = x
        SidebarRole.mediaControlGlyph.nsColor.setFill(); NSBezierPath(roundedRect: fill, xRadius: MiniPlayerMetrics.drawerTrackRadius, yRadius: MiniPlayerMetrics.drawerTrackRadius).fill()
        let shadow = NSShadow(); shadow.shadowColor = SidebarColors.tabShadowSelected.nsColor; shadow.shadowBlurRadius = MiniPlayerMetrics.drawerShadowBlur; shadow.shadowOffset = MiniPlayerMetrics.drawerShadowOffset
        NSGraphicsContext.saveGraphicsState(); shadow.set(); SidebarRole.mediaDrawerKnob.nsColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: x - knob / 2, y: bounds.midY - knob / 2, width: knob, height: knob)).fill(); NSGraphicsContext.restoreGraphicsState()
    }
    private func change(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let step = MiniPlayerMetrics.volumeStep
        value = min(1, max(0, (Double((x - MiniPlayerMetrics.drawerKnob / 2) / max(bounds.width - MiniPlayerMetrics.drawerKnob, 1)) / step).rounded() * step)); onValue?(value)
    }
    override func mouseDown(with event: NSEvent) { change(event) }
    override func mouseDragged(with event: NSEvent) { change(event) }
    override func mouseUp(with event: NSEvent) { change(event) }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Tab Volume" }
    override func accessibilityValue() -> Any? { "\(Int(value * 100))%" }
    override func accessibilityPerformIncrement() -> Bool { value = min(1, value + 0.1); onValue?(value); return true }
    override func accessibilityPerformDecrement() -> Bool { value = max(0, value - 0.1); onValue?(value); return true }
}
