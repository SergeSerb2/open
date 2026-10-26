import AppKit
import OpenDesign
import OpenMedia
import OpenModel
import OpenSidebar
import OpenWeb

/// PP-5/6/8: native controls above the engine video surface. No polling or idle animation.
@MainActor public final class PiPOverlayView: NSView, NSMenuDelegate {
    public let scrubber: PiPScrubberView
    private let host: any WebPictureInPictureHost
    private let builder: PiPMenuBuilder
    private let hiddenBySite: Set<String>
    private let controls = PiPControlsContainer(), precisionLabel = PiPPrecisionLabel(labelWithString: "")
    private let dim = CALayer(), topScrim = CAGradientLayer(), bottomScrim = CAGradientLayer()
    private var buttons: [String: PiPControlButton] = [:]
    private var tracking: NSTrackingArea?, hideWork: DispatchWorkItem?
    private var visibility: PiPVisibilityObserver?
    private var keyboardFocus = false, accessibilityFocus = false, pointerInside = false
    public private(set) var controlsVisible = true
    public private(set) var menuIsTracking = false
    public var onClose: (() -> Void)?, onMinimize: (() -> Void)?, onBackToTab: (() -> Void)?
    public var hasScheduledHide: Bool { hideWork != nil }
    public var isCompact: Bool { bounds.width < PiPMetrics.compactWidth }
    public init(host: any WebPictureInPictureHost, menuBuilder: PiPMenuBuilder, configuration: PiPSiteRules.Site?) {
        self.host = host; builder = menuBuilder; hiddenBySite = configuration?.hide ?? []
        scrubber = PiPScrubberView(host: host)
        super.init(frame: .zero); wantsLayer = true
        dim.backgroundColor = PiPRole.controlsDim.cgColor(.dark); layer?.addSublayer(dim)
        controls.wantsLayer = true; addSubview(controls)
        topScrim.colors = [PiPRole.topScrim.cgColor(.dark), PiPRole.topScrim.resolved(.dark).withAlpha(0).cgColor]
        bottomScrim.colors = [PiPRole.bottomScrim.resolved(.dark).withAlpha(0).cgColor, PiPRole.bottomScrim.cgColor(.dark)]
        for scrim in [topScrim, bottomScrim] { scrim.startPoint = CGPoint(x: 0.5, y: 0); scrim.endPoint = CGPoint(x: 0.5, y: 1); layer?.insertSublayer(scrim, at: 0) }
        add("close", .pipClose, "Close") { [weak self] in self?.onClose?() }
        add("minimize", .pipMinimize, "Minimize") { [weak self] in self?.onMinimize?() }
        add("settings", .pipSettings, "Options") { [weak self] in self?.showMenu() }
        add("play", .pipPause, "Pause") { [weak self] in self?.host.togglePlayPause(); self?.refresh() }
        add("back", .pipSkipBack, "Skip back 15 seconds") { [weak self] in self?.skip(-PiPMetrics.skipSeconds) }
        add("forward", .pipSkipForward, "Skip ahead 15 seconds") { [weak self] in self?.skip(PiPMetrics.skipSeconds) }
        add("previous", .pipPrevious, "Previous Track") { [weak self] in self?.host.previousTrack() }
        add("next", .pipNext, "Next Track") { [weak self] in self?.host.nextTrack() }
        add("mute", .pipUnmute, "Mute") { [weak self] in guard let self else { return }; self.host.setMuted(!self.host.mediaMuted); self.refresh() }
        add("tab", nil, "Back to Tab") { [weak self] in self?.onBackToTab?() }
        add("ad", nil, "Skip Ad") { [weak self] in self?.host.skipAd() }
        add("microphone", .mediaMicrophone, "Toggle Microphone") { [weak self] in self?.host.toggleMicrophone(); self?.refresh() }
        add("camera", .mediaCamera, "Toggle Camera") { [weak self] in self?.host.toggleCamera(); self?.refresh() }
        add("hangup", .pipHangUp, "Hang Up") { [weak self] in self?.host.hangUp() }
        for id in ["play", "back", "forward", "previous", "next"] { buttons[id]?.showsPlate = false; buttons[id]?.hasGlyphShadow = true }
        controls.addSubview(scrubber); controls.addSubview(precisionLabel)
        precisionLabel.font = Typography.pipPrecision.font; precisionLabel.textColor = PiPRole.secondaryText.nsColor
        precisionLabel.alignment = .center; precisionLabel.wantsLayer = true; precisionLabel.layer?.opacity = 0
        precisionLabel.lineBreakMode = .byTruncatingTail; precisionLabel.maximumNumberOfLines = 1
        precisionLabel.cell?.wraps = false
        scrubber.onDragChanged = { [weak self] _ in self?.showControls(); self?.updateUtilityVisibility(); self?.updatePrecision(); self?.updatePlayGlyph() }
        scrubber.onPrecisionChanged = { [weak self] in self?.updatePrecision(); self?.updatePlayGlyph() }
        scrubber.onKeyboardFocus = { [weak self] value in self?.keyboardFocus = value; self?.showControls() }
        scrubber.onAccessibilityFocus = { [weak self] value in self?.accessibilityFocus = value; self?.showControls() }
        builder.onMuteChanged = { [weak self] in self?.refresh() }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { hideWork?.cancel(); visibility?.invalidate() }
    public override var isFlipped: Bool { true }
    public func control(named id: String) -> (view: NSView, glyph: Glyph?, title: String, pointSize: CGFloat?)? {
        buttons[id].map { ($0, $0.glyph, $0.label, $0.glyphSize ?? $0.glyph?.spec.pointSize) }
    }
    public func makeMenu() -> NSMenu { let menu = builder.build(); menu.delegate = self; return menu }
    private func add(_ id: String, _ glyph: Glyph?, _ title: String, _ action: @escaping () -> Void) {
        let button = PiPControlButton(glyph: glyph, title: title); button.action = action
        button.setAccessibilityIdentifier("pip." + id)
        button.onActivity = { [weak self] in self?.pointerInside = true; self?.showControls() }
        button.onKeyboardFocus = { [weak self] value in self?.keyboardFocus = value; self?.showControls() }
        button.onAccessibilityFocus = { [weak self] value in self?.accessibilityFocus = value; self?.showControls() }
        buttons[id] = button; controls.addSubview(button)
    }
    private func skip(_ delta: Double) {
        let end = host.mediaState.duration ?? .greatestFiniteMagnitude
        host.seekTo(min(end, max(0, scrubber.displayedTime + delta))); scrubber.refresh()
    }
    public func refresh() {
        let state = host.mediaState, actions = state.actions
        let meeting = !actions.intersection([.toggleMicrophone, .toggleCamera, .hangUp]).isEmpty
        buttons["close"]?.isHidden = hiddenBySite.contains("close")
        buttons["play"]?.isHidden = meeting || hiddenBySite.contains("play")
        updatePlayGlyph()
        let finite = state.duration.map { $0.isFinite && $0 > 0 } == true
        for id in ["back", "forward"] { buttons[id]?.isHidden = meeting || hiddenBySite.contains("skip") || !finite }
        scrubber.isHidden = meeting || hiddenBySite.contains("scrub") || !finite
        buttons["previous"]?.isHidden = meeting || isCompact || !actions.contains(.previousTrack)
        buttons["next"]?.isHidden = meeting || isCompact || !actions.contains(.nextTrack)
        buttons["ad"]?.isHidden = !actions.contains(.skipAd)
        buttons["microphone"]?.isHidden = !actions.contains(.toggleMicrophone)
        buttons["camera"]?.isHidden = !actions.contains(.toggleCamera)
        buttons["hangup"]?.isHidden = !actions.contains(.hangUp)
        buttons["microphone"]?.glyph = state.microphoneMuted == true ? .mediaMicrophoneMuted : .mediaMicrophone
        buttons["camera"]?.glyph = state.cameraOn == false ? .mediaCameraOff : .mediaCamera
        buttons["mute"]?.glyph = host.mediaMuted ? .pipMute : .pipUnmute; buttons["mute"]?.label = host.mediaMuted ? "Unmute" : "Mute"
        buttons["forward"]?.isEnabled = !host.endOfMedia
        scrubber.refresh(); needsLayout = true
    }
    public override func layout() {
        super.layout()
        let m = PiPMetrics.self, w = bounds.width, h = bounds.height, p = isCompact ? m.compactPadding : m.regularPadding
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dim.frame = bounds
        controls.frame = bounds; topScrim.frame = CGRect(x: 0, y: 0, width: w, height: m.topScrim)
        bottomScrim.frame = CGRect(x: 0, y: h - m.bottomScrim, width: w, height: m.bottomScrim)
        buttons["close"]?.frame = CGRect(x: p, y: p, width: m.cornerButton, height: m.cornerButton)
        buttons["minimize"]?.frame = CGRect(x: p + (buttons["close"]?.isHidden == true ? 0 : m.cornerPitch), y: p, width: m.cornerButton, height: m.cornerButton)
        buttons["settings"]?.frame = CGRect(x: w - p - m.cornerButton, y: p, width: m.cornerButton, height: m.cornerButton)
        buttons["play"]?.glyphSize = isCompact ? m.compactPlayGlyph : Glyph.pipPlay.spec.pointSize
        buttons["play"]?.frame = CGRect(x: w / 2 - m.playButton / 2, y: h / 2 - m.playButton / 2, width: m.playButton, height: m.playButton)
        let skip = isCompact ? m.compactSkipDistance : m.skipDistance
        for (id, sign) in [("back", CGFloat(-1)), ("forward", CGFloat(1))] {
            buttons[id]?.glyphSize = isCompact ? m.compactSkipGlyph : m.skipGlyph
            buttons[id]?.isHidden = !host.mediaState.actions.intersection([.toggleMicrophone, .toggleCamera, .hangUp]).isEmpty || hiddenBySite.contains("skip") || host.mediaState.duration.map { !$0.isFinite || $0 <= 0 } != false || w < m.minimumSkipWidth
            buttons[id]?.frame = CGRect(x: w / 2 + sign * skip - m.skipButton / 2, y: h / 2 - m.skipButton / 2, width: m.skipButton, height: m.skipButton)
        }
        for (id, sign) in [("previous", CGFloat(-1)), ("next", CGFloat(1))] {
            buttons[id]?.isHidden = isCompact || !host.mediaState.actions.contains(id == "previous" ? .previousTrack : .nextTrack) || !host.mediaState.actions.intersection([.toggleCamera, .toggleMicrophone, .hangUp]).isEmpty
            buttons[id]?.frame = CGRect(x: w / 2 + sign * m.trackDistance - m.trackButton / 2, y: h / 2 - m.trackButton / 2, width: m.trackButton, height: m.trackButton)
        }
        if buttons["play"]?.isHidden == true {
            let tracks = ["previous", "next"].filter { buttons[$0]?.isHidden == false }
            for (i, id) in tracks.enumerated() {
                buttons[id]?.frame.origin.x = w / 2 + (CGFloat(i) - CGFloat(tracks.count - 1) / 2) * (m.trackButton + m.packedTrackGap) - m.trackButton / 2
            }
        }
        let offset = scrubber.isHidden ? 0 : m.bottomControlsOffset
        let centerY = h - p - offset - m.cornerButton / 2
        let tabWidth = buttons["tab"]?.pillWidth ?? 0
        buttons["tab"]?.frame = CGRect(x: p, y: centerY - m.pillHeight / 2, width: tabWidth, height: m.pillHeight)
        buttons["mute"]?.frame = CGRect(x: w - p - m.cornerButton, y: centerY - m.cornerButton / 2, width: m.cornerButton, height: m.cornerButton)
        let adWidth = buttons["ad"]?.pillWidth ?? 0
        buttons["ad"]?.frame = CGRect(x: w - p - adWidth, y: centerY - m.cornerButton / 2 - m.pillHeight - m.expandedControlGap, width: adWidth, height: m.pillHeight)
        let meeting = ["microphone", "camera", "hangup"].filter { buttons[$0]?.isHidden == false }
        let total = CGFloat(meeting.count) * m.meetingButton + CGFloat(max(0, meeting.count - 1)) * m.meetingGap
        var meetingY = centerY - m.meetingButton / 2
        let meetingRect = CGRect(x: (w - total) / 2, y: meetingY, width: total, height: m.meetingButton)
        if let tab = buttons["tab"], let mute = buttons["mute"], meetingRect.intersects(tab.frame) || meetingRect.intersects(mute.frame) {
            meetingY = centerY - m.cornerButton / 2 - m.expandedControlGap - m.meetingButton
        }
        for (i, id) in meeting.enumerated() { buttons[id]?.frame = CGRect(x: (w - total) / 2 + CGFloat(i) * (m.meetingButton + m.meetingGap), y: meetingY, width: m.meetingButton, height: m.meetingButton) }
        scrubber.frame = CGRect(x: p, y: h - p - m.scrubberHeight / 2 - m.scrubberHitHeight / 2, width: max(0, w - 2 * p), height: m.scrubberHitHeight)
        precisionLabel.frame = CGRect(x: p, y: h - p - m.scrubberHeight - m.precisionLabelGap - m.precisionLabelHeight, width: max(0, w - 2 * p), height: m.precisionLabelHeight)
        CATransaction.commit()
    }
    private func updateUtilityVisibility() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in ["tab", "mute", "ad"] {
            guard let button = buttons[id], let layer = button.layer else { continue }
            button.isSuppressed = scrubber.isDragging
            let old = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = scrubber.isDragging ? 0 : 1
            if window?.isVisible == true {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = old; fade.toValue = layer.opacity
                fade.duration = Motion.pipFade; layer.add(fade, forKey: "pip.scrubUtility")
            }
        }
        CATransaction.commit()
    }
    private func updatePlayGlyph() {
        buttons["play"]?.glyph = host.mediaState.playback == .playing ? .pipPause : .pipPlay
        buttons["play"]?.label = host.mediaState.playback == .playing ? "Pause" : "Play"
    }
    private func updatePrecision() {
        precisionLabel.stringValue = scrubber.precisionText
        let target: Float = scrubber.isDragging ? 1 : 0
        guard let layer = precisionLabel.layer, layer.opacity != target else { return }
        let old = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = target
        if window?.isVisible == true {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = old; fade.toValue = target
            fade.duration = Motion.pipFade; layer.add(fade, forKey: "pip.precision")
        }
        CATransaction.commit()
    }
    public func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        controlsVisible = visible; scrubber.controlsAreVisible = visible
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [controls.layer, dim, topScrim, bottomScrim].compactMap({ $0 }) {
            let old = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = visible ? 1 : 0
            if animated && window?.isVisible == true {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = old; fade.toValue = visible ? 1 : 0
                fade.duration = visible ? Motion.pipFade : Motion.pipControlsHide; layer.add(fade, forKey: "pip.controls")
            }
        }
        CATransaction.commit()
    }
    public func showControls() {
        hideWork?.cancel(); hideWork = nil; setControlsVisible(true)
        guard !menuIsTracking && !scrubber.isDragging && !keyboardFocus && !accessibilityFocus else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            self?.hideWork = nil; self?.setControlsVisible(false)
        } }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + PiPMetrics.hideDelay, execute: work)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseMoved(with event: NSEvent) { pointerInside = true; showControls() }
    public override func mouseEntered(with event: NSEvent) { pointerInside = true; showControls() }
    public override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hideWork?.cancel(); hideWork = nil
        if !menuIsTracking && !scrubber.isDragging && !keyboardFocus && !accessibilityFocus { setControlsVisible(false) }
    }
    private func showMenu() {
        guard let button = buttons["settings"] else { return }
        let menu = makeMenu(); menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY), in: button)
    }
    public func menuWillOpen(_ menu: NSMenu) { menuIsTracking = true; showControls() }
    public func menuDidClose(_ menu: NSMenu) {
        menuIsTracking = false
        if pointerInside || keyboardFocus || accessibilityFocus { showControls() } else { setControlsVisible(false) }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); visibility?.invalidate(); visibility = nil
        if let window { visibility = PiPVisibilityObserver(window: window) { [weak self] closing in
            guard let self else { return }
            if closing || !window.isVisible || NSApp.isHidden {
                self.hideWork?.cancel(); self.hideWork = nil; self.setControlsVisible(false, animated: false)
            } else { if !window.isKeyWindow { self.keyboardFocus = false; self.accessibilityFocus = false }; self.showControls() }
        } }
    }
}

/// Own plates and SF/vector glyph drawing (AGENTS 1). Tooltip delay is PP-6.
@MainActor final class PiPControlButton: NSView {
    var glyph: Glyph? { didSet { if glyph != oldValue { needsDisplay = true } } }
    var glyphSize: CGFloat? { didSet { if glyphSize != oldValue { needsDisplay = true } } }
    var label: String { didSet { if label != oldValue { needsDisplay = true } } }
    var action: (() -> Void)?, onActivity: (() -> Void)?, onKeyboardFocus: ((Bool) -> Void)?, onAccessibilityFocus: ((Bool) -> Void)?
    var showsPlate = true, growsOnHover = true, documentStyle = false, hasGlyphShadow = false
    var isSuppressed = false
    var isEnabled = true { didSet {
        alphaValue = isEnabled ? 1 : PiPMetrics.disabledControlOpacity; needsDisplay = true
        if !isEnabled {
            pressed = false; layer?.removeAnimation(forKey: "pip.hover")
            CATransaction.begin(); CATransaction.setDisableActions(true); layer?.setAffineTransform(.identity); CATransaction.commit()
        }
    } }
    private var hovered = false, pressed = false
    private var tracking: NSTrackingArea?
    var pillWidth: CGFloat { ceil((label as NSString).size(withAttributes: [.font: Typography.pipPill.font]).width) + 2 * PiPMetrics.pillPadding }
    init(glyph: Glyph?, title: String) { self.glyph = glyph; label = title; super.init(frame: .zero); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { isSuppressed ? nil : super.hitTest(point) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { onKeyboardFocus?(true); return true }
    override func resignFirstResponder() -> Bool { onKeyboardFocus?(false); return true }
    override func setAccessibilityFocused(_ focused: Bool) { super.setAccessibilityFocused(focused); onAccessibilityFocus?(focused) }
    override func draw(_ dirtyRect: NSRect) {
        let fill = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? PiPRole.plateHighContrast : (pressed ? PiPRole.platePressed : (hovered ? PiPRole.plateHover : PiPRole.plate))
        (documentStyle ? (pressed ? PiPRole.documentButtonPressed : PiPRole.documentButtonHover) : (glyph == .pipHangUp ? PiPRole.hangUp : fill)).nsColor.setFill()
        let radius = documentStyle ? PiPMetrics.documentButtonRadius : (glyph == nil ? bounds.height / 2 : min(bounds.width, bounds.height) / 2)
        if isEnabled && (showsPlate || hovered || pressed) { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
        if let glyph, var image = glyph.image {
            if let size = glyphSize, let replacement = NSImage(systemSymbolName: glyph.spec.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: glyph.spec.weight)) { image = replacement }
            let rect = CGRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            if hasGlyphShadow { cg.setShadow(offset: .zero, blur: PiPMetrics.centerGlyphShadowRadius, color: PiPRole.centerGlyphShadow.cgColor(.dark)) }
            cg.beginTransparencyLayer(in: rect.insetBy(dx: -PiPMetrics.centerGlyphShadowRadius * 2, dy: -PiPMetrics.centerGlyphShadowRadius * 2), auxiliaryInfo: nil)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cg.setBlendMode(.sourceIn); cg.setFillColor((documentStyle && !hovered ? PiPRole.secondaryText : PiPRole.glyph).cgColor(.dark)); cg.fill(rect); cg.endTransparencyLayer(); cg.restoreGState()
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: Typography.pipPill.font, .foregroundColor: PiPRole.glyph.nsColor]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true; onActivity?()
        let style = SpaceThemeStyle(theme: SpaceTheme(), system: .dark)
        var tooltip = Tooltip(title: label, placement: .above, style: style, showDelay: MiniPlayerMetrics.tooltipDelay)
        tooltip.fill = PiPRole.platePressed.resolved(.dark); tooltip.text = PiPRole.glyph.resolved(.dark)
        TooltipController.shared.schedule(tooltip, for: self)
        if isEnabled && growsOnHover && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = PiPMetrics.hoverScale; grow.duration = Motion.pipFade
            layer?.setAffineTransform(CGAffineTransform(scaleX: PiPMetrics.hoverScale, y: PiPMetrics.hoverScale)); layer?.add(grow, forKey: "pip.hover")
        }
    }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; TooltipController.shared.cancel(for: self); layer?.setAffineTransform(.identity) }
    override func mouseDown(with event: NSEvent) { guard isEnabled && !isSuppressed else { return }; pressed = true; needsDisplay = true; onActivity?(); TooltipController.shared.cancel(for: self) }
    override func mouseUp(with event: NSEvent) { if isEnabled && !isSuppressed && pressed && bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }; pressed = false; needsDisplay = true; onActivity?() }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityHelp() -> String? { label }
    override func isAccessibilityEnabled() -> Bool { isEnabled && !isSuppressed }
    override func accessibilityPerformPress() -> Bool { guard isEnabled && !isSuppressed else { return false }; onActivity?(); action?(); return action != nil }
}

@MainActor private final class PiPControlsContainer: NSView { override var isFlipped: Bool { true } }

/// The fading seek hint never intercepts the utility controls under its band.
@MainActor private final class PiPPrecisionLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { (layer?.opacity ?? 0) > 0 }
}
