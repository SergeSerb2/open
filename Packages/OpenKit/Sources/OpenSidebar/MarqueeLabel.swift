import AppKit
import OpenDesign
import QuartzCore

/// Layer-only marquee (PP-17). No timer or display link; one animation only while eligible.
@MainActor public final class MarqueeLabel: NSView {
    private let moving = CALayer()
    private let first = CATextLayer(), second = CATextLayer()
    private let fade = CAGradientLayer()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibilityObservation: NSKeyValueObservation?
    private var text = ""
    private var color = NSColor.labelColor
    private var measuredWidth: CGFloat = 0
    public var isExposed = true { didSet { if oldValue != isExposed { refreshAnimation() } } }
    public var isPlaying = false { didSet { if oldValue != isPlaying { refreshAnimation() } } }
    public var isTitleHovered = false { didSet { if oldValue != isTitleHovered { refreshAnimation() } } }
    public var isOverflowing: Bool { measuredWidth > bounds.width }
    public var isRunning: Bool { moving.animation(forKey: "media.marquee") != nil }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = true; layer?.addSublayer(moving); layer?.mask = fade
        moving.addSublayer(first); moving.addSublayer(second)
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        for text in [first, second] { text.font = Typography.miniPlayerTitle.font; text.fontSize = Typography.miniPlayerTitle.size }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { visibilityObservation?.invalidate(); observers.forEach { $0.0.removeObserver($0.1) } }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public func configure(text: String, color: NSColor, playing: Bool, titleHovered: Bool) {
        let changed = self.text != text || self.color != color
        let hoverChanged = self.isTitleHovered != titleHovered
        self.text = text; self.color = color
        isPlaying = playing; isTitleHovered = titleHovered
        if changed { needsLayout = true }
        if hoverChanged && animatesMediaChanges {
            let fade = CATransition(); fade.type = .fade
            fade.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : Motion.miniPlayerTitle
            moving.add(fade, forKey: "media.titleTransition")
        }
        refreshAnimation()
    }
    public override func layout() {
        super.layout()
        let font = Typography.miniPlayerTitle.font
        measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        moving.frame = bounds; fade.frame = bounds
        let y = MiniPlayerMetrics.titleBaseline - font.ascender
        for (i, textLayer) in [first, second].enumerated() {
            textLayer.contentsScale = window?.backingScaleFactor ?? 2
            textLayer.string = text; textLayer.foregroundColor = color.cgColor
            textLayer.frame = CGRect(x: CGFloat(i) * (measuredWidth + MiniPlayerMetrics.marqueeSpacing), y: y,
                                     width: measuredWidth + 1, height: ceil(font.ascender - font.descender + font.leading))
        }
        CATransaction.commit(); refreshAnimation()
    }
    private var canRun: Bool {
        let visible = window?.isVisible == true && window?.isMiniaturized == false && (window?.occlusionState.contains(.visible) == true || SidebarDiagnostics.forceAnimations)
        return visible && !NSApp.isHidden && isExposed && !isHiddenOrHasHiddenAncestor && isPlaying && !isTitleHovered && isOverflowing && !SidebarDiagnostics.mediaReducesMotion
    }
    public func refreshAnimation() {
        let run = canRun
        CATransaction.begin(); CATransaction.setDisableActions(true)
        second.isHidden = !run
        let w = max(bounds.width, 1), left = run ? min(MiniPlayerMetrics.marqueeLeftFade / w, 0.4) : 0
        let right = max(0.6, 1 - MiniPlayerMetrics.marqueeRightFade / w)
        fade.colors = [run ? CGColor(gray: 0, alpha: 0) : CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, NSNumber(value: Double(left)), NSNumber(value: Double(right)), 1]
        CATransaction.commit()
        guard run else { moving.removeAnimation(forKey: "media.marquee"); return }
        let distance = measuredWidth + MiniPlayerMetrics.marqueeSpacing
        if let group = moving.animation(forKey: "media.marquee") as? CAAnimationGroup,
           let previous = group.animations?.first as? CABasicAnimation, previous.toValue as? Double == -Double(distance) { return }
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = 0; scroll.toValue = -Double(distance)
        scroll.beginTime = MiniPlayerMetrics.marqueeDelay
        scroll.duration = Double(distance / MiniPlayerMetrics.marqueeSpeed)
        scroll.fillMode = .backwards
        let group = CAAnimationGroup(); group.animations = [scroll]
        group.duration = MiniPlayerMetrics.marqueeDelay + scroll.duration; group.repeatCount = .infinity
        moving.add(group, forKey: "media.marquee")
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObservation?.invalidate(); visibilityObservation = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers = []
        guard let window else { moving.removeAllAnimations(); return }
        // An already-occluded window can order out without changing occlusionState.
        visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshAnimation() }
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification {
                        self?.visibilityObservation?.invalidate(); self?.visibilityObservation = nil
                        self?.moving.removeAllAnimations()
                    } else { self?.refreshAnimation() }
                }
            }))
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAnimation() }
            }))
        }
        observers.append((NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAnimation() }
        }))
        refreshAnimation()
    }
    public override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    public override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }
}
