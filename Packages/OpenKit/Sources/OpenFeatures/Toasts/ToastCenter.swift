import AppKit
import OpenDesign
import OpenSidebar

/// What one toast shows (page-platform §4.1.3).
public struct ToastContent: Sendable, Equatable {
    public enum Accessory: Sendable, Equatable {
        case none
        /// A 32 × 27 icon button (Share, Undo, Stop, …).
        case button(symbol: String, accessibilityLabel: String)
        /// "⌘", "⇧" plates before the title.
        case keycaps([String])
    }
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    public var accessory: Accessory
    /// nil: `ToastMetrics.lifetime`, or `accessoryLifetime` with an accessory.
    public var lifetime: TimeInterval?
    /// Same-key toasts still make a new view (PG-1.8); the key names the family for checks.
    public var coalescingKey: String?
    /// Stays until dismissed (trace recording, capture in progress).
    public var isSticky: Bool

    public init(title: String, subtitle: String? = nil, symbol: String? = nil, accessory: Accessory = .none,
                lifetime: TimeInterval? = nil, coalescingKey: String? = nil, isSticky: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.accessory = accessory
        self.lifetime = lifetime; self.coalescingKey = coalescingKey; self.isSticky = isSticky
    }
    public static let undoButton = Accessory.button(symbol: "arrow.uturn.backward", accessibilityLabel: "Undo")
    public static let shareButton = Accessory.button(symbol: "square.and.arrow.up", accessibilityLabel: "Share")
    /// A toast with Undo that lasts as long as its source can undo.
    public static func undo(_ title: String, lifetime: TimeInterval) -> ToastContent {
        ToastContent(title: title, accessory: undoButton, lifetime: lifetime)
    }
    /// The scheduled lifetime (nil for sticky toasts).
    public var effectiveLifetime: TimeInterval? {
        guard !isSticky else { return nil }
        return lifetime ?? (accessory == .none ? ToastMetrics.lifetime : ToastMetrics.accessoryLifetime)
    }
    /// A short name of the accessory for automation ("none", "undo", "share", a symbol, "keycaps").
    public var accessoryName: String {
        switch accessory {
        case .none: "none"
        case .keycaps: "keycaps"
        case .button(_, let label): label.lowercased()
        }
    }
}

/// One-shot deadlines for toasts. The system clock schedules work items on the main queue (no
/// repeating timer); checks pass a fake clock and fire deadlines themselves.
@MainActor
public protocol ToastClock: AnyObject {
    var now: CFTimeInterval { get }
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ToastTimer
}

@MainActor
public final class ToastTimer {
    private var onCancel: (() -> Void)?
    public init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
}

@MainActor
public final class SystemToastClock: ToastClock {
    public init() {}
    public var now: CFTimeInterval { CACurrentMediaTime() }
    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ToastTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return ToastTimer { item.cancel() }
    }
}

/// A shown toast. Methods on a toast that already left do nothing.
@MainActor
public final class ToastHandle {
    fileprivate weak var center: ToastCenter?
    public let id: Int
    fileprivate init(center: ToastCenter, id: Int) { self.center = center; self.id = id }
    /// The toast is on screen and not leaving.
    public var isVisible: Bool { center?.entry(id)?.isExiting == false }
    /// Same view, new text (trace timer, the async quote offer). The deadline stays.
    public func update(_ content: ToastContent) { center?.update(id, content) }
    public func dismiss() { center?.exit(id) }
    /// Keeps the toast while something it opened is up (the share picker), then restarts its
    /// timer like the pointer leaving it.
    public func hold(_ held: Bool) { center?.hold(id, held) }
    /// The toast's button while it shows (the share picker anchors to it).
    public var accessoryButton: NSView? { center?.entry(id).flatMap { $0.isExiting ? nil : $0.view.accessoryButton } }
}

/// One per browser window and per Little Open window (page-platform D-1, §4.1). Toasts are views
/// in one overlay; a new toast appears at the anchor above the others and every older toast starts
/// its exit at once (PG-1.8). Lifetimes are one-shot deadlines; nothing runs while no toast shows.
@MainActor
public final class ToastCenter {
    public let overlay: ToastOverlayView
    public var clock: any ToastClock
    private let style: @MainActor () -> SpaceThemeStyle
    /// Animate only on screen (offscreen renders and checks see the final state).
    public var animates: @MainActor () -> Bool
    public var reducesMotion: @MainActor () -> Bool = { Motion.reducesMotion }
    /// Title of the newest toast ever shown (checks and `window-state`).
    public private(set) var lastTitle = ""
    public private(set) var shownCount = 0
    /// The last scheduled animations by key ("in.transform", "in.opacity", "out.transform", "out.opacity").
    public private(set) var lastAnimations: [String: CAAnimation] = [:]
    fileprivate final class Entry {
        let id: Int
        var content: ToastContent
        let view: ToastView
        var onAccessory: ((ToastHandle) -> Void)?
        let shownAt: CFTimeInterval
        var isExiting = false
        var isHovered = false
        var isHeld = false
        var deadline: CFTimeInterval?
        var timer: ToastTimer?
        init(id: Int, content: ToastContent, view: ToastView, shownAt: CFTimeInterval) {
            self.id = id; self.content = content; self.view = view; self.shownAt = shownAt
        }
    }
    private var entries: [Entry] = []   // oldest first; the last is on top
    private var nextID = 1
    private var dispatchingAccessory = 0

    public init(overlay: ToastOverlayView, style: @escaping @MainActor () -> SpaceThemeStyle, clock: any ToastClock = SystemToastClock()) {
        self.overlay = overlay; self.style = style; self.clock = clock
        self.animates = { [weak overlay] in overlay?.window?.isVisible == true || SidebarDiagnostics.forceAnimations }
        overlay.onResize = { [weak self] in self?.relayout() }
    }

    @discardableResult
    public func show(_ content: ToastContent, onAccessory: ((ToastHandle) -> Void)? = nil) -> ToastHandle {
        let view = ToastView(content: content, style: style())
        let entry = Entry(id: nextID, content: content, view: view, shownAt: clock.now)
        nextID += 1; shownCount += 1; lastTitle = content.title
        entry.onAccessory = onAccessory
        let handle = ToastHandle(center: self, id: entry.id)
        let id = entry.id
        view.onAccessory = { [weak self] in
            guard let self, let entry = self.entry(id), !entry.isExiting else { return }
            // The handler may dismiss this toast (Undo) or show another one: views that leave
            // during the button's own action are detached on the next run-loop turn.
            self.dispatchingAccessory += 1
            defer { self.dispatchingAccessory -= 1 }
            entry.onAccessory?(ToastHandle(center: self, id: id))
        }
        view.onHover = { [weak self] inside in self?.hover(id, inside) }
        // Older toasts leave at once; at most `maxVisible` views exist (the oldest goes first).
        for older in entries where !older.isExiting { exit(older.id) }
        entries.append(entry)
        while entries.count > ToastMetrics.maxVisible { remove(entries[0].id) }
        overlay.isHidden = false
        overlay.addSubview(view)
        view.frame = ToastMetrics.frame(size: view.frame.size, in: overlay.bounds)
        animateIn(view)
        schedule(entry, after: content.effectiveLifetime)
        announce(content)
        return handle
    }

    /// Removes every toast now (window close, sheet over the page).
    public func dismissAll() {
        for entry in entries { entry.timer?.cancel(); entry.view.removeFromSuperview() }
        entries.removeAll(); overlay.isHidden = true
    }
    /// Toasts on screen and not leaving, newest first.
    public var visible: [ToastContent] { visibleEntries.map(\.content) }
    public struct Snapshot: Sendable {
        public var content: ToastContent
        /// Frame in the overlay (flipped, top-left origin).
        public var frame: CGRect
        public var accessoryFrame: CGRect?
        public var age: TimeInterval
        public var lifetime: TimeInterval?
        /// Scheduled exit time on the center's clock (nil while sticky, hovered, or held).
        public var deadline: CFTimeInterval?
        public var isExiting: Bool
        public var isHovered: Bool
    }
    /// Every toast view (exiting ones too), newest first.
    public var snapshots: [Snapshot] {
        entries.reversed().map { e in
            Snapshot(content: e.content, frame: e.view.frame,
                     accessoryFrame: e.view.accessoryButton.map { e.view.convert($0.frame, to: overlay) },
                     age: clock.now - e.shownAt, lifetime: e.content.effectiveLifetime, deadline: e.deadline,
                     isExiting: e.isExiting, isHovered: e.isHovered)
        }
    }
    /// The views, newest first (checks render and probe them).
    public var views: [ToastView] { entries.reversed().map(\.view) }
    /// Clicks the accessory button of the visible toast at `index` (newest first) through the real
    /// button. False when that toast has no button.
    @discardableResult public func performAccessory(at index: Int) -> Bool {
        let shown = visibleEntries
        guard shown.indices.contains(index), let button = shown[index].view.accessoryButton else { return false }
        button.performClick(nil)
        return true
    }
    /// The pointer enters (true) or leaves (false) the visible toast at `index`, newest first: the
    /// same pause and resume as the toast's tracking area (automation and checks).
    @discardableResult public func setHovered(at index: Int, _ inside: Bool) -> Bool {
        let shown = visibleEntries
        guard shown.indices.contains(index) else { return false }
        hover(shown[index].id, inside)
        return true
    }
    /// Clicks the newest visible Undo button. False when none shows.
    @discardableResult public func performUndo() -> Bool {
        guard let entry = visibleEntries.first(where: { $0.content.accessory == ToastContent.undoButton }),
              let button = entry.view.accessoryButton else { return false }
        button.performClick(nil)
        return true
    }

    // MARK: Internals

    private var visibleEntries: [Entry] { entries.reversed().filter { !$0.isExiting } }
    fileprivate func entry(_ id: Int) -> Entry? { entries.first { $0.id == id } }

    fileprivate func update(_ id: Int, _ content: ToastContent) {
        guard let entry = entry(id), !entry.isExiting else { return }
        let wasSticky = entry.content.isSticky
        entry.content = content
        entry.view.apply(content, style: style())
        entry.view.frame = ToastMetrics.frame(size: entry.view.frame.size, in: overlay.bounds)
        lastTitle = content.title
        if wasSticky != content.isSticky, !entry.isHovered, !entry.isHeld { schedule(entry, after: content.effectiveLifetime) }
    }

    fileprivate func hold(_ id: Int, _ held: Bool) {
        guard let entry = entry(id), !entry.isExiting, entry.isHeld != held else { return }
        entry.isHeld = held
        resumeOrPause(entry)
    }

    private func hover(_ id: Int, _ inside: Bool) {
        guard let entry = entry(id), !entry.isExiting, entry.isHovered != inside else { return }
        entry.isHovered = inside
        resumeOrPause(entry)
    }

    /// The pointer over a toast (or a held toast) pauses its timer; afterwards it restarts with
    /// `hoverResumeLifetime` left (page-platform §4.1.1, Open choice).
    private func resumeOrPause(_ entry: Entry) {
        if entry.isHovered || entry.isHeld { entry.timer?.cancel(); entry.timer = nil; entry.deadline = nil; return }
        guard entry.content.effectiveLifetime != nil else { return }
        schedule(entry, after: ToastMetrics.hoverResumeLifetime)
    }

    private func schedule(_ entry: Entry, after lifetime: TimeInterval?) {
        entry.timer?.cancel(); entry.timer = nil; entry.deadline = nil
        guard let lifetime else { return }
        let id = entry.id
        entry.deadline = clock.now + lifetime
        entry.timer = clock.schedule(after: lifetime) { [weak self] in self?.exit(id) }
    }

    fileprivate func exit(_ id: Int) {
        guard let entry = entry(id), !entry.isExiting else { return }
        entry.isExiting = true
        entry.timer?.cancel(); entry.timer = nil; entry.deadline = nil
        entry.view.accessoryButton?.isEnabled = false
        guard animates() else { remove(id); return }
        animateOut(entry.view)
        entry.timer = clock.schedule(after: Motion.toastOut) { [weak self] in self?.remove(id) }
    }

    private func remove(_ id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.timer?.cancel()
        if dispatchingAccessory > 0 {
            let view = entry.view
            view.isHidden = true
            DispatchQueue.main.async { view.removeFromSuperview() }
        } else { entry.view.removeFromSuperview() }
        if entries.isEmpty { overlay.isHidden = true }
    }

    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for entry in entries {
            let frame = ToastMetrics.frame(size: entry.view.frame.size, in: overlay.bounds)
            if entry.view.frame != frame { entry.view.frame = frame }
        }
        CATransaction.commit()
    }

    /// Scale about the top center of the toast (PG-14: it grows from, and shrinks back to, a small
    /// pill at the top center of its frame). The overlay is flipped, so its layers' y axis points down.
    public static func topCenterScale(_ scale: CGFloat, size: CGSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(size.width / 2, 0, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -size.width / 2, 0, 0)
    }

    private func animateIn(_ view: ToastView) {
        guard animates(), let layer = view.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.rasterizationScale = view.window?.backingScaleFactor ?? 1
        layer.shouldRasterize = true
        CATransaction.setCompletionBlock { [weak layer] in
            MainActor.assumeIsolated {
                if layer?.animation(forKey: "toastOut.opacity") == nil { layer?.shouldRasterize = false }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = Motion.toastFadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        preferDisplayRefresh(fade, for: view)
        layer.add(fade, forKey: "toastIn.opacity")
        lastAnimations = ["in.opacity": fade]
        guard !reducesMotion() else { return }
        let grow = Motion.toastIn.animation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Self.topCenterScale(Motion.toastInScale, size: view.bounds.size))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        preferDisplayRefresh(grow, for: view)
        layer.add(grow, forKey: "toastIn.transform")
        lastAnimations["in.transform"] = grow
    }

    private func animateOut(_ view: ToastView) {
        guard let layer = view.layer else { return }
        // Start from what is on screen (an exit during the appear spring does not snap).
        let presentation = layer.presentation()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.removeAnimation(forKey: "toastIn.opacity")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation?.opacity ?? layer.opacity; fade.toValue = 0
        fade.duration = Motion.toastOut; fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        preferDisplayRefresh(fade, for: view)
        layer.add(fade, forKey: "toastOut.opacity")
        lastAnimations["out.opacity"] = fade
        guard !reducesMotion() else { return }
        let end = Self.topCenterScale(Motion.toastOutScale, size: view.bounds.size)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: presentation?.transform ?? layer.transform); shrink.toValue = NSValue(caTransform3D: end)
        shrink.duration = Motion.toastOut; shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.removeAnimation(forKey: "toastIn.transform")
        layer.transform = end
        preferDisplayRefresh(shrink, for: view)
        layer.add(shrink, forKey: "toastOut.transform")
        lastAnimations["out.transform"] = shrink
    }

    /// Ask the render server to use this window's display cadence only while
    /// the toast moves. No display link or main-thread frame callback is needed.
    private func preferDisplayRefresh(_ animation: CAAnimation, for view: NSView) {
        guard let screen = view.window?.screen else { return }
        let rate = Float(screen.maximumFramesPerSecond)
        guard rate > 0 else { return }
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    private func announce(_ content: ToastContent) {
        let text = [content.title, content.subtitle].compactMap { $0 }.joined(separator: ", ")
        guard !text.isEmpty, let element = overlay.window else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
