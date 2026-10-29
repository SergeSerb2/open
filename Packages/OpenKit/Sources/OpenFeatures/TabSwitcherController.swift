import AppKit
import OpenDesign
import OpenModel

/// A frozen ordering for one hold-Control session. Only commit changes the model.
/// One drawing view renders the visible slice; there are no per-tab NSViews,
/// repeating timers or snapshot jobs after a session ends. Presentation uses
/// one cancellable 100 ms delay. A modifier monitor exists only during a session.
@MainActor
public final class TabSwitcherController {
    public struct Item {
        public let id: ItemID
        public let title: String
        public let subtitle: String
        public init(id: ItemID, title: String, subtitle: String) {
            self.id = id; self.title = title; self.subtitle = subtitle
        }
    }
    public private(set) var items: [Item] = []
    public private(set) var selectedIndex = 0
    public private(set) var view: TabSwitcherView?
    public var isActive: Bool { !items.isEmpty }
    public var isPresented: Bool { view?.isHidden == false }
    public var selectedID: ItemID? { items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil }
    public var visibleIDs: [ItemID] { visibleRange.map { items[$0].id } }
    public var icon: ((ItemID) -> NSImage?)?
    /// Existing hosts only. The caller must never load a tab for a preview.
    public var snapshot: ((ItemID) async -> NSImage?)?
    public var pendingSnapshotCount: Int { snapshotTasks.count }
    private var snapshotTasks: [ItemID: Task<Void, Never>] = [:]
    private var snapshots: [ItemID: NSImage] = [:]
    private var modifierMonitor: Any?
    public var isMonitoringModifiers: Bool { modifierMonitor != nil }
    private var generation = 0
    private var presentationTask: Task<Void, Never>?
    private var snapshotAttempts: Set<ItemID> = []
    private var onCommit: ((ItemID) -> Void)?
    private weak var parent: NSView?
    private var visibleRange: Range<Int> {
        let count = min(TabSwitcherTokens.maximumVisible, items.count)
        let start = max(0, min(selectedIndex - count / 2, items.count - count))
        return start..<(start + count)
    }
    public init() {}
    isolated deinit { if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) } }

    public func advance(by delta: Int, items: [Item], current: ItemID?, in parent: NSView,
                        commit: @escaping (ItemID) -> Void) {
        if !isActive {
            guard items.count > 1 else { return }
            self.items = items; selectedIndex = items.firstIndex { $0.id == current } ?? -delta
            self.parent = parent; onCommit = commit
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.parent?.window else { return }
                    self.handle(event)
                }
                return event
            }
            generation += 1
            let surface = TabSwitcherView(); surface.owner = self; surface.isHidden = true
            view = surface; parent.addSubview(surface, positioned: .above, relativeTo: nil)
            // Anchor to the key request, not to when this job gets main-actor time.
            let deadline = ContinuousClock.now.advanced(by: TabSwitcherTokens.presentationDelay)
            presentationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.presentationTask = nil; self.view?.isHidden = false
                self.loadVisibleSnapshots()
            }
        }
        selectedIndex = (selectedIndex + delta % self.items.count + self.items.count) % self.items.count
        layout(); view?.needsDisplay = true
        view?.setAccessibilityValue(self.items[selectedIndex].title)
        if isPresented { loadVisibleSnapshots() }
    }
    private func loadVisibleSnapshots() {
        if let snapshot {
            let generation = generation
            for id in visibleIDs where snapshotAttempts.insert(id).inserted {
                snapshotTasks[id] = Task { @MainActor [weak self] in
                    let image = await snapshot(id)
                    guard !Task.isCancelled, let self, self.generation == generation, self.isActive else { return }
                    self.snapshots[id] = image; self.snapshotTasks[id] = nil; self.view?.needsDisplay = true
                }
            }
        }
    }
    public func layout() {
        guard let parent, let view else { return }
        let count = min(TabSwitcherTokens.maximumVisible, items.count)
        let width = min(parent.bounds.width - 32, CGFloat(count) * (TabSwitcherTokens.itemWidth + TabSwitcherTokens.gap)
                        - TabSwitcherTokens.gap + TabSwitcherTokens.inset * 2)
        let height = TabSwitcherTokens.itemHeight + TabSwitcherTokens.headingHeight + TabSwitcherTokens.inset * 2
        view.frame = CGRect(x: (parent.bounds.width - width) / 2, y: (parent.bounds.height - height) / 2,
                            width: width, height: height)
    }
    @discardableResult public func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.control) { finish(commit: true) }
            return false
        }
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 53: finish(commit: false); return true
        case 36: finish(commit: true); return true
        default: return false
        }
    }
    public func cancel() { if isActive { finish(commit: false) } }
    private func finish(commit: Bool) {
        let id = selectedID, action = onCommit
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }; modifierMonitor = nil
        generation += 1
        presentationTask?.cancel(); presentationTask = nil
        for task in snapshotTasks.values { task.cancel() }; snapshotTasks.removeAll()
        snapshots.removeAll(); snapshotAttempts.removeAll()
        view?.removeFromSuperview(); view = nil; parent = nil
        items.removeAll(keepingCapacity: false); icon = nil; snapshot = nil; onCommit = nil
        if commit, let id { action?(id) }
    }
    fileprivate func draw(in bounds: CGRect) {
        TabSwitcherTokens.background.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: TabSwitcherTokens.corner, yRadius: TabSwitcherTokens.corner).fill()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: TabSwitcherTokens.foreground.nsColor]
        ("Recent Items" as NSString).draw(at: CGPoint(x: TabSwitcherTokens.inset, y: TabSwitcherTokens.inset), withAttributes: heading)
        let range = visibleRange
        let width = (bounds.width - TabSwitcherTokens.inset * 2 - CGFloat(max(0, range.count - 1)) * TabSwitcherTokens.gap) / CGFloat(max(1, range.count))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = .center
        for (offset, index) in range.enumerated() {
            let item = items[index]
            let rect = CGRect(x: TabSwitcherTokens.inset + CGFloat(offset) * (width + TabSwitcherTokens.gap),
                              y: TabSwitcherTokens.inset + TabSwitcherTokens.headingHeight,
                              width: width, height: TabSwitcherTokens.itemHeight)
            if index == selectedIndex {
                TabSwitcherTokens.selection.nsColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            }
            if let preview = snapshots[item.id] {
                preview.draw(in: CGRect(x: rect.minX + 8, y: rect.minY + 8, width: width - 16, height: 68),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [TabSwitcherTokens.foreground.nsColor]))
                let image = icon?(item.id) ?? fallback
                image?.draw(in: CGRect(x: rect.midX - 24, y: rect.minY + 18, width: 48, height: 48),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            (item.title as NSString).draw(in: CGRect(x: rect.minX + 8, y: rect.minY + 83, width: width - 16, height: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: TabSwitcherTokens.foreground.nsColor, .paragraphStyle: paragraph])
            (item.subtitle as NSString).draw(in: CGRect(x: rect.minX + 8, y: rect.minY + 105, width: width - 16, height: 17),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: TabSwitcherTokens.secondary.nsColor, .paragraphStyle: paragraph])
        }
    }
    fileprivate func click(at point: CGPoint) {
        let range = visibleRange
        guard let view, !range.isEmpty, point.y >= TabSwitcherTokens.inset + TabSwitcherTokens.headingHeight else { return }
        let pitch = (view.bounds.width - TabSwitcherTokens.inset * 2 + TabSwitcherTokens.gap) / CGFloat(range.count)
        let offset = Int(floor((point.x - TabSwitcherTokens.inset) / pitch))
        guard (0..<range.count).contains(offset) else { return }
        selectedIndex = range.lowerBound + offset; finish(commit: true)
    }
}

@MainActor
public final class TabSwitcherView: NSView {
    fileprivate weak var owner: TabSwitcherController?
    public override var isFlipped: Bool { true }
    public override init(frame: CGRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityRole(.group); setAccessibilityLabel("Recent Items"); setAccessibilityElement(true)
    }
    public convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func draw(_ dirtyRect: CGRect) { owner?.draw(in: bounds) }
    public override func mouseDown(with event: NSEvent) { owner?.click(at: convert(event.locationInWindow, from: nil)) }
}
