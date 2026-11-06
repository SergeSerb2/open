import AppKit
import OpenModel

@MainActor
public final class IconPickerController {
    public let panel: EditorPopoverPanel
    public let view: IconPickerView
    public var onClose: (@MainActor () -> Void)?
    public private(set) var isClosed = false
    private weak var owner: NSWindow?
    private let anchor: CGRect
    private let onPick: @MainActor (SpaceIcon?) -> Void
    private var notifications: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var loading: Task<Void, Never>?
    private var tonePanel: EditorPopoverPanel?
    private var tones: [String] = []
    private var isShown = false
    public var toneCount: Int { tones.count }
    public var toneWindow: NSWindow? { tonePanel }
    public func toneButton(at index: Int) -> NSButton? {
        tonePanel?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.tag == index }
    }

    public init(target: IconTarget, current: SpaceIcon?, window: NSWindow, anchor: CGRect,
                onPick: @escaping @MainActor (SpaceIcon?) -> Void) {
        owner = window; self.anchor = anchor; self.onPick = onPick
        view = IconPickerView(target: target, current: current)
        let panel = IconPickerPanel(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: IconPickerView.size),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        self.panel = panel; panel.contentView = view
        _ = EditorPopoverPanel.installMaterial(in: view, radius: 20)
        panel.picker = view
        panel.setAccessibilityRole(.popover); panel.setAccessibilityLabel("Choose Icon")
        view.onPick = { [weak self] icon in self?.pick(icon) }
        view.onEscape = { [weak self] in self?.close() }
        view.onTones = { [weak self] entry, cell in self?.showTones(entry, cell: cell) }
    }
    isolated deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        loading?.cancel()
        tonePanel?.orderOut(nil); panel.orderOut(nil)
    }
    public func show() {
        guard !isClosed, !isShown, let owner else { return }; isShown = true
        let rect = owner.convertToScreen(anchor)
        var frame = CGRect(x: rect.minX, y: rect.minY - 6 - 300, width: 246, height: 300)
        if let screen = owner.screen?.visibleFrame {
            if frame.minY < screen.minY + 8 { frame.origin.y = rect.maxY + 6 }
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: false)
        // Offscreen harness owners stay unordered and never touch the desktop.
        if owner.isVisible {
            owner.addChildWindow(panel, ordered: .above); panel.makeKeyAndOrderFront(nil)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window !== self.panel && event.window !== self.tonePanel { self.close() }
                return event
            }
        }
        for (name, object) in [(NSApplication.didResignActiveNotification, nil), (NSWindow.willCloseNotification, owner)] as [(Notification.Name, Any?)] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        panel.makeFirstResponder(view)
        loading = Task { [weak self] in
            do {
                let index = try await EmojiIndexCache.shared.load()
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.view.load(index); self.loading = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.view.loadFailed(); self?.loading = nil
            }
        }
    }
    public func close() {
        guard !isClosed else { return }; isClosed = true
        loading?.cancel(); loading = nil; view.stop()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }; notifications.removeAll()
        closeTones()
        let wasKey = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        if wasKey, owner?.isVisible == true, NSApp.isActive { owner?.makeKey() }
        let callback = onClose; onClose = nil
        // Keep the controller and its panel alive until native event dispatch ends.
        Task { @MainActor [self] in callback?(); _ = self }
    }
    private func pick(_ icon: SpaceIcon?) {
        // A cell callback can release the controller. Finish it after AppKit has
        // returned from the event dispatch, retaining the callback, not the view.
        let callback = onPick
        close()
        Task { @MainActor in callback(icon) }
    }
    private func closeTones() {
        let closing = tonePanel
        if let closing { panel.removeChildWindow(closing); closing.orderOut(nil) }
        tonePanel = nil; tones = []
        // A native tone button can close its own window from its action.
        // Keep that window alive until AppKit finishes the event dispatch.
        if let closing { Task { @MainActor in _ = closing } }
    }
    private func showTones(_ entry: EmojiEntry, cell: NSView) {
        closeTones(); tones = entry.tones
        guard tones.count > 1 else { return }
        let size = CGSize(width: 8 + CGFloat(tones.count) * 30, height: 38)
        let rect = panel.convertToScreen(cell.convert(cell.bounds, to: nil))
        let tonesPanel = TonePanel(contentRect: CGRect(x: rect.minX, y: rect.maxY + 4, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        tonesPanel.onEscape = { [weak self] in self?.close() }
        let body = NSView(frame: CGRect(origin: .zero, size: size))
        _ = EditorPopoverPanel.installMaterial(in: body, radius: 10)
        for (index, tone) in tones.enumerated() {
            let button = NSButton(title: tone, target: self, action: #selector(pickTone(_:)))
            button.isBordered = false; button.font = NSFont(name: "AppleColorEmoji", size: 20)
            button.frame = CGRect(x: 4 + CGFloat(index) * 30, y: 4, width: 30, height: 30); button.tag = index
            button.setAccessibilityLabel("\(entry.name), skin tone \(index)")
            body.addSubview(button)
        }
        tonesPanel.contentView = body
        if let screen = owner?.screen?.visibleFrame {
            var frame = tonesPanel.frame
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
            if frame.maxY > screen.maxY - 8 { frame.origin.y = rect.minY - 4 - frame.height }
            tonesPanel.setFrame(frame, display: false)
        }
        tonePanel = tonesPanel
        if panel.isVisible { panel.addChildWindow(tonesPanel, ordered: .above); tonesPanel.makeKeyAndOrderFront(nil) }
    }
    @objc private func pickTone(_ sender: NSButton) {
        guard tones.indices.contains(sender.tag) else { return }; pick(.emoji(tones[sender.tag]))
    }
}

@MainActor private final class IconPickerPanel: EditorPopoverPanel {
    weak var picker: IconPickerView?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, picker?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { picker?.onEscape?() }
}
@MainActor private final class TonePanel: EditorPopoverPanel {
    var onEscape: (@MainActor () -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
}
