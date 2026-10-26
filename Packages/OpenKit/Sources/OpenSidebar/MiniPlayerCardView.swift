import AppKit
import OpenDesign
import OpenMedia
import OpenModel
import Symbols

/// Receipt from the real title draw; the internal TextLabel remains encapsulated.
public struct MiniPlayerTitleState {
    public let frame: CGRect
    public let baseline: CGFloat
    public let fontSize: CGFloat
    public let drawnText: String
    public let drawnWidth: CGFloat
    public let wasTruncated: Bool
}

/// Capture session 2 card: media plan §13. Finite CA transitions; no idle work.
@MainActor public final class MiniPlayerCardView: NSView {
    public let source: MediaSource
    public let shadowLayer = CALayer()
    public let contentView: NSView = MiniPlayerRowView(frame: .zero)
    private let titleRow = MiniPlayerTitleHitView(frame: .zero)
    private let titleLabel = TextLabel(frame: .zero)
    private let controlsRow = MiniPlayerRowView(frame: .zero)
    private let drawerRow = MiniPlayerRowView(frame: .zero)
    private let context: SidebarContext
    private let favicon = FaviconView()
    private var buttons: [String: MediaControlButton] = [:]
    private let slider = MediaVolumeSlider(frame: .zero)
    private var observation: ObservationLoop?
    private var tracking: NSTrackingArea?
    private var pointerOnTitle = false
    private var pressed = false
    private var previousShadowPath: CGPath?
    private var titleRowTransition = 0
    private var resizingDrawer = false
    private var lastDrawerOpen = false
    public var isRetiring = false
    public private(set) var isExpanded = false
    public private(set) var level = 0
    public var onHeightChange: (() -> Void)?
    public var cardHeight: CGFloat { MiniPlayerMetrics.cardHeight(expanded: isExpanded, drawer: drawerIsOpen) }
    public var drawerIsOpen: Bool {
        isExpanded && source.kind != .recording && source.volume != nil && source.tabID.map { context.mediaDrawers.contains($0) } == true
    }
    private var isTitleHovered: Bool {
        if let forced = context.forcedMediaHover { if case .title(let id) = forced { return id == source.tabID }; return false }
        return pointerOnTitle && isExpanded
    }
    private var titleText = ""
    private var drawnTitle = "", drawnTitleWidth: CGFloat = 0
    private var titleWasTruncated = false
    public var titleState: MiniPlayerTitleState {
        MiniPlayerTitleState(frame: titleLabel.frame, baseline: titleLabel.baseline,
                             fontSize: titleLabel.font.pointSize, drawnText: drawnTitle,
                             drawnWidth: drawnTitleWidth, wasTruncated: titleWasTruncated)
    }
    public init(source: MediaSource, context: SidebarContext) {
        self.source = source; self.context = context
        super.init(frame: .zero); wantsLayer = true; layerContentsRedrawPolicy = .never
        layer?.allowsGroupOpacity = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = MiniPlayerMetrics.shadowOpacity
        shadowLayer.shadowRadius = MiniPlayerMetrics.shadowRadius
        shadowLayer.shadowOffset = .zero
        layer?.addSublayer(shadowLayer)
        contentView.wantsLayer = true; contentView.layer?.cornerCurve = .continuous
        contentView.layer?.cornerRadius = MiniPlayerMetrics.cornerRadius; contentView.layer?.masksToBounds = true
        addSubview(contentView)
        for row in [titleRow, drawerRow, controlsRow] as [NSView] { row.wantsLayer = true; contentView.addSubview(row) }
        titleRow.identifier = NSUserInterfaceItemIdentifier("media.titleRow")
        drawerRow.identifier = NSUserInterfaceItemIdentifier("media.drawerRow")
        titleLabel.identifier = NSUserInterfaceItemIdentifier("media.titleLabel")
        titleLabel.font = Typography.miniPlayerTitle.font; titleLabel.baseline = MiniPlayerMetrics.titleBaseline
        titleLabel.onDrawnLine = { [weak self] line, original, truncated, width in
            self?.drawnTitle = TextLabel.visibleText(line, original: original)
            self?.drawnTitleWidth = width; self?.titleWasTruncated = truncated
        }
        titleLabel.text = { [weak self] in self?.titleText ?? "" }
        titleLabel.color = { SidebarRole.miniPlayerTitle.nsColor }
        titleRow.addSubview(titleLabel)
        titleRow.action = { [weak self] in self?.send(MediaIntent.backToTab) }
        titleRow.label = { "Back to Tab" }
        makeButton("favicon", glyph: nil, title: "Back to Tab", row: controlsRow) { [weak self] in self?.send(MediaIntent.backToTab) }
        favicon.context = context; favicon.tab = source.tabID.flatMap { context.model.tab(id: $0) }
        buttons["favicon"]?.addSubview(favicon)
        makeButton("pip", glyph: .mediaPiP, title: "Open Picture in Picture", row: titleRow) { [weak self] in self?.send(MediaIntent.openPictureInPicture) }
        makeButton("close", glyph: .mediaClose, title: "Close Mini Player", row: titleRow) { [weak self] in self?.send(MediaIntent.close) }
        makeButton("previous", glyph: .mediaPrevious, title: "Previous Track", row: controlsRow) { [weak self] in self?.send(MediaIntent.previousTrack) }
        makeButton("play", glyph: .mediaPause, title: "Pause", row: controlsRow) { [weak self] in
            guard let self else { return }; self.send(self.source.playback == .playing ? MediaIntent.pause : MediaIntent.play)
        }
        makeButton("next", glyph: .mediaNext, title: "Next Track", row: controlsRow) { [weak self] in self?.send(MediaIntent.nextTrack) }
        makeButton("volume", glyph: .mediaVolume, title: "Adjust Tab Volume", row: controlsRow) { [weak self] in
            guard let self, let id = self.source.tabID else { return }
            if self.source.volume == nil { self.send(MediaIntent.toggleMute) }
            else if self.isExpanded {
                if self.context.mediaDrawers.contains(id) { self.context.mediaDrawers.remove(id) } else { self.context.mediaDrawers.insert(id) }
                self.sync(); self.onHeightChange?()
            }
        }
        makeButton("microphone", glyph: .mediaMicrophone, title: "Toggle Microphone", row: controlsRow) { [weak self] in self?.send(MediaIntent.toggleMicrophone) }
        makeButton("camera", glyph: .mediaCamera, title: "Toggle Camera", row: controlsRow) { [weak self] in self?.send(MediaIntent.toggleCamera) }
        makeButton("volumeLow", glyph: .mediaVolumeLow, title: "Mute", row: drawerRow) { [weak self] in self?.send(MediaIntent.toggleMute) }
        makeButton("volumeHigh", glyph: .mediaVolumeHigh, title: "Set Tab Volume to 100%", row: drawerRow) { [weak self] in self?.setVolume(1) }
        slider.onValue = { [weak self] value in self?.setVolume(value) }; drawerRow.addSubview(slider)
        observation = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.source.playback; _ = self.source.actions; _ = self.source.hasVideo; _ = self.source.kind
            _ = self.source.isMuted
            if self.source.kind == .recording { _ = self.source.microphoneOn; _ = self.source.cameraOn }
            // Track availability too: an EM-2 publication can add volume support.
            _ = self.source.volume
            _ = self.context.focusedSpace?.theme; _ = self.context.systemAppearance
            _ = self.context.mediaDrawers; _ = self.context.forcedMediaHover; _ = self.tab?.displayTitle
        }) { [weak self] in self?.sync(); self?.onHeightChange?() }
        sync()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observation?.cancel() }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isRetiring, isExpanded || level == 0 else { return nil }
        let hit = super.hitTest(point)
        return hit === contentView ? self : hit
    }
    private var tab: Tab? { source.tabID.flatMap { context.model.tab(id: $0) } }
    private func send(_ intent: (ItemID) -> MediaIntent) { if let id = source.tabID { context.send(.media(intent(id))) } }
    private func setVolume(_ value: Double) { if let id = source.tabID { context.send(.media(.setVolume(id, value))) } }
    public func control(named id: String) -> (view: NSView, glyph: Glyph?, tooltip: Tooltip?)? {
        guard let button = buttons[id] else { return nil }
        return (button, button.displayedGlyph, button.tooltip?())
    }
    func configure(expanded: Bool, level: Int) {
        self.level = level
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if !expanded, let id = source.tabID { context.mediaDrawers.remove(id) }
        let start = MediaAnimationStart(layer: titleRow.layer, frame: titleRow.frame)
        titleRowTransition += 1
        let transition = titleRowTransition
        titleRow.isHidden = false; titleRow.alphaValue = expanded ? 1 : 0
        if animatesMediaChanges {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in Task { @MainActor in
                guard let self, self.titleRowTransition == transition, !self.isExpanded else { return }; self.titleRow.isHidden = true
            } }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = start.opacity; fade.toValue = titleRow.alphaValue
            fade.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : (expanded ? Motion.miniPlayerReveal : Motion.miniPlayerDisappear)
            fade.timingFunction = expanded ? Motion.easeOut : CAMediaTimingFunction(name: .easeIn)
            titleRow.layer?.add(fade, forKey: "media.titleRowOpacity")
            CATransaction.commit()
        } else { titleRow.isHidden = !expanded }
        sync(); resizingDrawer = false
    }
    private func makeButton(_ id: String, glyph: Glyph?, title: String, row: NSView, action: @escaping @MainActor () -> Void) {
        let button = MediaControlButton(glyph: glyph); button.context = context
        button.plateRadius = MiniPlayerMetrics.buttonPlateRadius
        button.glyphTint = { enabled in (enabled ? SidebarRole.mediaControlGlyph : SidebarRole.mediaControlGlyphDisabled).nsColor }
        button.accessibleTitle = { title }; button.action = action
        button.setAccessibilityIdentifier("media." + id)
        if id != "favicon" { button.tooltip = { [weak context, weak button] in
            guard let context, let button, button.isEnabled(), let space = context.focusedSpace else { return nil }
            return Tooltip(title: button.accessibleTitle?() ?? title, placement: .beside, style: context.style(for: space), showDelay: MiniPlayerMetrics.tooltipDelay)
        } }
        buttons[id] = button; row.addSubview(button)
    }
    private func sync() {
        let recording = source.kind == .recording
        for id in ["previous", "play", "next", "volume"] { buttons[id]?.isHidden = recording }
        buttons["previous"]?.isEnabled = { [weak source] in source?.actions.contains(.previousTrack) == true }
        buttons["next"]?.isEnabled = { [weak source] in source?.actions.contains(.nextTrack) == true }
        buttons["microphone"]?.isHidden = !recording || !source.actions.contains(.toggleMicrophone)
        buttons["camera"]?.isHidden = !recording || !source.actions.contains(.toggleCamera)
        buttons["pip"]?.isHidden = !source.hasVideo
        if !isExpanded && titleRow.alphaValue == 1 { titleRow.alphaValue = 0; titleRow.isHidden = true }
        buttons["play"]?.setGlyph(source.playback == .playing ? .mediaPause : .mediaPlay)
        buttons["play"]?.accessibleTitle = { [weak source] in source?.playback == .playing ? "Pause" : "Play" }
        buttons["volume"]?.setGlyph(source.isMuted ? .mediaVolumeMuted : .mediaVolume)
        if recording {
            buttons["microphone"]?.setGlyph(source.microphoneOn == false ? .mediaMicrophoneMuted : .mediaMicrophone)
            buttons["camera"]?.setGlyph(source.cameraOn == false ? .mediaCameraOff : .mediaCamera)
        }
        if drawerIsOpen != lastDrawerOpen { resizingDrawer = true; lastDrawerOpen = drawerIsOpen }
        drawerRow.isHidden = !drawerIsOpen
        if drawerIsOpen { slider.value = source.volume ?? 1 }
        let nextTitle = isTitleHovered ? "Back to Tab" : (tab?.displayTitle ?? "")
        if nextTitle != titleText {
            let hadTitle = !titleText.isEmpty; titleText = nextTitle; titleLabel.needsDisplay = true
            if hadTitle && isExpanded && animatesMediaChanges {
                let fade = CATransition(); fade.type = .fade
                fade.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : Motion.miniPlayerTitle
                titleLabel.layer?.add(fade, forKey: "media.titleSwap")
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let space = context.focusedSpace {
            contentView.layer?.backgroundColor = context.style(for: space).miniPlayerFill(context.appearance(for: space)).cgColor
        }
        contentView.layer?.borderWidth = SidebarDiagnostics.mediaIncreasesContrast ? 1 : 0
        contentView.layer?.borderColor = SidebarColors.separator.cgColor(contentAppearance)
        CATransaction.commit()
        titleLabel.needsDisplay = true; needsLayout = true
    }
    public override func setFrameSize(_ newSize: NSSize) {
        if bounds.size != newSize && bounds.size != .zero { previousShadowPath = shadowLayer.presentation()?.shadowPath ?? shadowLayer.shadowPath }
        super.setFrameSize(newSize)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: MiniPlayerMetrics.cornerRadius, cornerHeight: MiniPlayerMetrics.cornerRadius, transform: nil)
        CATransaction.commit()
    }
    public override func layout() {
        super.layout()
        let m = MiniPlayerMetrics.self, w = bounds.width
        let views = [contentView, titleRow, drawerRow, controlsRow, titleLabel, slider] + Array(buttons.values)
        let previous = views.map { $0.frame }
        let starts = views.map { MediaAnimationStart(layer: $0.layer, frame: $0.frame) }
        let oldShadow = shadowLayer.presentation()?.shadowPath ?? previousShadowPath ?? shadowLayer.shadowPath
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentView.frame = bounds
        // Rows keep their on-screen place; the clipped top edge reveals them (§13.6).
        titleRow.frame = CGRect(x: 0, y: bounds.height - m.cardHeight(expanded: true, drawer: drawerIsOpen), width: w, height: m.rowHeight)
        drawerRow.frame = CGRect(x: 0, y: bounds.height - 2 * m.rowHeight, width: w, height: m.rowHeight)
        controlsRow.frame = CGRect(x: 0, y: bounds.height - m.rowHeight, width: w, height: m.rowHeight)
        buttons["close"]?.frame = CGRect(x: w - m.closeTrailing, y: m.buttonY, width: m.button, height: m.button)
        buttons["pip"]?.frame = CGRect(x: w - m.pipTrailing, y: m.buttonY, width: m.button, height: m.button)
        titleLabel.frame = CGRect(x: m.titleX, y: 0, width: max(0, w - (source.hasVideo ? m.pipTrailing : m.closeTrailing) - m.titleX - m.titleGap), height: m.rowHeight)
        let ids = source.kind == .recording ? ["favicon", "microphone", "camera"] : ["favicon", "previous", "play", "next", "volume"]
        for (k, id) in ids.enumerated() {
            buttons[id]?.frame = CGRect(x: m.slotX(k, cardWidth: w, scale: window?.backingScaleFactor ?? 2), y: m.buttonY, width: m.button, height: m.button)
        }
        favicon.frame = CGRect(x: 4, y: 4, width: m.faviconSize, height: m.faviconSize)
        buttons["volumeLow"]?.frame = CGRect(x: m.slotInset, y: m.buttonY, width: m.button, height: m.button)
        buttons["volumeHigh"]?.frame = CGRect(x: w - m.closeTrailing, y: m.buttonY, width: m.button, height: m.button)
        slider.frame = CGRect(x: m.drawerSliderInset, y: 0, width: max(0, w - 2 * m.drawerSliderInset), height: m.rowHeight)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius, transform: nil)
        CATransaction.commit()
        for (index, view) in views.enumerated() where previous[index] != .zero && previous[index] != view.frame {
            animateMediaFrame(view.layer, from: starts[index], to: view.frame, enabled: animatesMediaChanges, drawer: resizingDrawer)
        }
        if animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion, let oldShadow, oldShadow != shadowLayer.shadowPath {
            let a: CABasicAnimation = resizingDrawer ? CABasicAnimation(keyPath: "shadowPath") : Motion.miniPlayerStack.animation(keyPath: "shadowPath")
            if resizingDrawer { a.duration = Motion.miniPlayerResize; a.timingFunction = Motion.easeInOut }
            a.fromValue = oldShadow; a.toValue = shadowLayer.shadowPath
            shadowLayer.add(a, forKey: "media.shadowPath")
        }
        previousShadowPath = nil; resizingDrawer = false
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func hover(_ event: NSEvent, inside: Bool) {
        let hovered = inside && isExpanded && convert(event.locationInWindow, from: nil).y < MiniPlayerMetrics.rowHeight
        if hovered != pointerOnTitle { pointerOnTitle = hovered; sync() }
    }
    public override func mouseEntered(with event: NSEvent) { hover(event, inside: true) }
    public override func mouseMoved(with event: NSEvent) { hover(event, inside: true) }
    public override func mouseExited(with event: NSEvent) { hover(event, inside: false) }
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

/// Empty row areas pass through to the card's body action.
@MainActor private final class MiniPlayerRowView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
}

/// Snapshot before changing any model geometry. AppKit layers normally anchor at zero.
/// A running media animation must retarget from the pixels currently on screen.
@MainActor struct MediaAnimationStart {
    let position: CGPoint
    let size: CGSize
    let opacity: Float
    let wasAnimating: Bool

    init(layer: CALayer?, frame: CGRect) {
        wasAnimating = layer?.animationKeys()?.contains { $0.hasPrefix("media.") } == true
        let visible = wasAnimating ? layer?.presentation() : nil
        let anchor = layer?.anchorPoint ?? .zero
        position = visible?.position ?? CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
        size = visible?.bounds.size ?? frame.size
        opacity = visible?.opacity ?? layer?.opacity ?? 1
    }
}

@MainActor func animateMediaFrame(_ layer: CALayer?, from start: MediaAnimationStart, to target: CGRect, enabled: Bool, drawer: Bool = false) {
    guard enabled else { return }
    if SidebarDiagnostics.mediaReducesMotion {
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = start.wasAnimating ? start.opacity : 0; a.toValue = 1; a.duration = Motion.reducedMedia
        layer?.add(a, forKey: "media.frameFade")
    } else {
        let move: CABasicAnimation = drawer ? CABasicAnimation(keyPath: "position") : Motion.miniPlayerStack.animation(keyPath: "position")
        move.fromValue = start.position; move.toValue = layer?.position
        let size: CABasicAnimation = drawer ? CABasicAnimation(keyPath: "bounds.size") : Motion.miniPlayerStack.animation(keyPath: "bounds.size")
        if drawer { for a in [move, size] { a.duration = Motion.miniPlayerResize; a.timingFunction = Motion.easeInOut } }
        size.fromValue = start.size; size.toValue = target.size
        layer?.add(move, forKey: "media.position"); layer?.add(size, forKey: "media.size")
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
    var value: Double = 1 { didSet { if value != oldValue { needsDisplay = true } } }
    var onValue: ((Double) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 0, y: bounds.midY - MiniPlayerMetrics.drawerTrackHeight / 2, width: bounds.width, height: MiniPlayerMetrics.drawerTrackHeight)
        SidebarRole.mediaControlGlyphDisabled.nsColor.setFill(); NSBezierPath(roundedRect: track, xRadius: MiniPlayerMetrics.drawerTrackRadius, yRadius: MiniPlayerMetrics.drawerTrackRadius).fill()
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
    override func accessibilityPerformIncrement() -> Bool { value = min(1, value + MiniPlayerMetrics.volumeStep); onValue?(value); return true }
    override func accessibilityPerformDecrement() -> Bool { value = max(0, value - MiniPlayerMetrics.volumeStep); onValue?(value); return true }
}
