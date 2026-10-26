import AppKit
import OpenDesign
import OpenWeb
import QuartzCore

/// PP-7: real mouse scrubbing with a click jump, upward precision and pause/resume.
@MainActor public final class PiPScrubberView: NSView {
    private let host: any WebPictureInPictureHost
    private var startPoint = CGPoint.zero, startTime: Double = 0, dragTime: Double = 0
    private var wasPlaying = false, hovered = false
    private var tracking: NSTrackingArea?
    private var visibility: PiPVisibilityObserver?
    private var displayLink: CADisplayLink?
    private let linkTarget = PiPDisplayLinkTarget()
    public private(set) var isDragging = false
    public private(set) var precision: Double = 1
    public var onDragChanged: ((Bool) -> Void)?
    public var onPrecisionChanged: (() -> Void)?
    public var onKeyboardFocus: ((Bool) -> Void)?, onAccessibilityFocus: ((Bool) -> Void)?
    public var controlsAreVisible = true { didSet { if controlsAreVisible != oldValue { updateDisplayLink() } } }
    public var precisionText: String { precision < 2 ? "Drag upwards to seek precisely" : "Seeking at \(Int(precision))× precision" }
    public var hasDisplayLink: Bool { displayLink != nil }
    public init(host: any WebPictureInPictureHost) {
        self.host = host; super.init(frame: .zero)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay; linkTarget.owner = self
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { displayLink?.invalidate(); visibility?.invalidate() }
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { onKeyboardFocus?(true); return true }
    public override func resignFirstResponder() -> Bool { onKeyboardFocus?(false); return true }
    public override func setAccessibilityFocused(_ focused: Bool) { super.setAccessibilityFocused(focused); onAccessibilityFocus?(focused) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var duration: Double? { host.mediaState.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    public var displayedTime: Double {
        if isDragging { return dragTime }
        let advance = host.mediaState.playback == .playing && !host.endOfMedia ? max(0, Date().timeIntervalSince(host.positionUpdatedAt)) * host.playbackRate : 0
        return min(duration ?? .greatestFiniteMagnitude, max(0, host.currentTime.isFinite ? host.currentTime + advance : 0))
    }
    public override func draw(_ dirtyRect: NSRect) {
        let height = hovered ? PiPMetrics.scrubberHoverHeight : PiPMetrics.scrubberHeight
        let track = CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
        PiPRole.scrubberTrack.nsColor.setFill(); NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        var fill = track; fill.size.width *= CGFloat(duration.map { displayedTime / $0 } ?? 0)
        PiPRole.scrubberFill.nsColor.setFill(); NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    public override func mouseDown(with event: NSEvent) {
        guard let duration, bounds.width > 0 else { return }
        startPoint = convert(event.locationInWindow, from: nil)
        startTime = min(duration, max(0, Double(startPoint.x / bounds.width) * duration)); dragTime = startTime; precision = 1
        wasPlaying = host.mediaState.playback == .playing
        isDragging = true; onDragChanged?(true)
        if wasPlaying { host.togglePlayPause() }
        host.scrubTo(startTime); onPrecisionChanged?(); needsDisplay = true; updateDisplayLink()
    }
    public override func mouseDragged(with event: NSEvent) {
        guard isDragging, let duration else { return }
        let point = convert(event.locationInWindow, from: nil), dy = point.y - startPoint.y
        precision = min(PiPMetrics.maximumPrecision, 1 + floor(Double(max(0, -dy) / PiPMetrics.precisionStep)))
        dragTime = min(duration, max(0, startTime + Double((point.x - startPoint.x) / max(1, bounds.width)) * duration / precision))
        host.scrubTo(dragTime); onPrecisionChanged?(); needsDisplay = true
    }
    public override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        host.seekTo(dragTime)
        if wasPlaying && host.mediaState.playback != .playing { host.togglePlayPause() }
        isDragging = false; onDragChanged?(false); onPrecisionChanged?(); needsDisplay = true; updateDisplayLink()
    }
    public func refresh() { needsDisplay = true; updateDisplayLink() }
    private func updateDisplayLink() {
        let run = controlsAreVisible && !isDragging && !isHiddenOrHasHiddenAncestor && window?.isVisible == true &&
            window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden && host.mediaState.playback == .playing && duration != nil
        if run && displayLink == nil, let window {
            let link = window.displayLink(target: linkTarget, selector: #selector(PiPDisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        } else if !run { displayLink?.invalidate(); displayLink = nil }
    }
    fileprivate func tick() { updateDisplayLink(); if displayLink != nil { needsDisplay = true } }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); visibility?.invalidate(); visibility = nil
        if let window { visibility = PiPVisibilityObserver(window: window) { [weak self] closing in
            if closing { self?.displayLink?.invalidate(); self?.displayLink = nil } else { self?.updateDisplayLink() }
        } }
        updateDisplayLink()
    }
    public override func viewDidHide() { super.viewDidHide(); updateDisplayLink() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateDisplayLink() }
    public override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityLabel() -> String? { "Playback position" }
    public override func accessibilityValue() -> Any? {
        func stamp(_ value: Double) -> String { let t = max(0, Int(min(Double(Int.max / 2), value))); return String(t / 60) + String(format: ":%02d", t % 60) }
        return stamp(displayedTime) + " of " + stamp(duration ?? 0)
    }
}

@MainActor private final class PiPDisplayLinkTarget: NSObject {
    weak var owner: PiPScrubberView?
    @objc func tick(_ link: CADisplayLink) { owner?.tick() }
}

/// No polling: visible, occluded, minimized, hidden-app and closed-window events.
@MainActor final class PiPVisibilityObserver {
    private var visible: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    init(window: NSWindow, changed: @escaping @MainActor (Bool) -> Void) {
        visible = window.observe(\.isVisible, options: [.new]) { _, _ in MainActor.assumeIsolated { changed(false) } }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let closing = name == NSWindow.willCloseNotification
                    if closing { self?.invalidate() }; changed(closing)
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { changed(false) } })
        }
    }
    func invalidate() { visible?.invalidate(); visible = nil; observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
    isolated deinit { invalidate() }
}
