import AppKit
import OpenDesign

/// The download start animation: a file icon flies from the page to the sidebar Library button
/// (capture PB1-b; values and maths in `OpenDesign.DownloadFlight`). One click-through overlay view
/// per flight; it removes itself when the flight ends. Reduce Motion plays nothing.
@MainActor
public final class DownloadFlightView: NSView {
    public let flight: DownloadFlight
    public let iconLayer = CALayer()
    /// Keyframe times (0…1 of `flight.duration`) the animations were built from.
    public private(set) var keyTimes: [NSNumber] = []
    var onFinish: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public init(frame: NSRect, flight: DownloadFlight, icon: NSImage) {
        self.flight = flight
        super.init(frame: frame)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("downloads.flight")
        setAccessibilityElement(false)
        iconLayer.contents = icon
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.opacity = 0
        layer?.addSublayer(iconLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Starts after `DownloadFlight.startDelay`; position and size follow the model at 60 samples/s.
    public func play() {
        let duration = flight.duration
        guard duration > 0 else { finish(); return }
        let steps = max(2, Int((duration * 60).rounded(.up)))
        var positions: [NSValue] = [], sizes: [NSValue] = []
        keyTimes = []
        for i in 0...steps {
            let t = duration * Double(i) / Double(steps)
            let p = flight.position(at: t), s = flight.size(at: t)
            keyTimes.append(NSNumber(value: Double(i) / Double(steps)))
            positions.append(NSValue(point: p)); sizes.append(NSValue(rect: CGRect(x: 0, y: 0, width: s, height: s)))
        }
        let begin = CACurrentMediaTime() + DownloadFlight.startDelay
        func keyframes(_ keyPath: String, _ values: [NSValue]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = values; a.keyTimes = keyTimes; a.duration = duration; a.beginTime = begin
            a.calculationMode = .linear; a.fillMode = .backwards; a.isRemovedOnCompletion = true
            return a
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Model values = the end state, hidden: after the flight nothing is left on screen.
        iconLayer.position = flight.position(at: duration)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: DownloadFlight.endSize, height: DownloadFlight.endSize)
        CATransaction.commit()
        let visible = CAKeyframeAnimation(keyPath: "opacity")
        visible.values = [1, 1]; visible.keyTimes = [0, 1]; visible.duration = duration; visible.beginTime = begin
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        iconLayer.add(keyframes("position", positions), forKey: "downloads.flight.position")
        iconLayer.add(keyframes("bounds", sizes), forKey: "downloads.flight.bounds")
        iconLayer.add(visible, forKey: "downloads.flight.opacity")
        CATransaction.commit()
    }

    private func finish() {
        removeFromSuperview()
        let done = onFinish; onFinish = nil; done?()
    }
}

extension BrowserWindowController {
    /// Plays the download flight from `start` (window content points, top-left origin; nil = the
    /// middle of the page area's top third) to the Library button. Returns the view, or nil when
    /// nothing plays: Reduce Motion, a hidden sidebar (no target on screen), or a hidden window.
    /// GUESS: Arc with a hidden sidebar is not captured.
    @discardableResult
    public func playDownloadFlight(from start: CGPoint? = nil, icon: NSImage) -> DownloadFlightView? {
        guard !Motion.reducesMotion, let target = sidebar.libraryButtonFrame(in: contentView) else { return nil }
        // contentView is not flipped: convert to top-left points for the model.
        let height = contentView.bounds.height
        func flipped(_ p: CGPoint) -> CGPoint { contentView.isFlipped ? p : CGPoint(x: p.x, y: height - p.y) }
        let page = container.frame
        let origin = start ?? flipped(CGPoint(x: page.midX, y: contentView.isFlipped ? page.minY + page.height / 3 : page.maxY - page.height / 3))
        let end = flipped(CGPoint(x: target.midX, y: target.midY))
        let view = DownloadFlightView(frame: contentView.bounds, flight: DownloadFlight(start: origin, target: end), icon: icon)
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view, positioned: .above, relativeTo: nil)
        view.play()
        return view
    }
}
