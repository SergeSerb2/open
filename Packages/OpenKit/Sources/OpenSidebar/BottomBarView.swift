import AppKit
import OpenDesign
import OpenModel

/// Bottom bar: Home (Library), the Space switcher, and the plus menu
/// (runtime-observations §1.1, interaction-states §5).
@MainActor
final class BottomBarView: NSView {
    unowned let context: SidebarContext
    let home = PlateButton(glyph: .library)
    let plus = PlateButton(glyph: .bottomPlus)
    private let strip = NSView()
    private(set) var items: [SpaceID: SwitcherItemView] = [:]
    private var loop: ObservationLoop?
    var menus: SidebarMenus

    init(context: SidebarContext, menus: SidebarMenus) {
        self.context = context
        self.menus = menus
        super.init(frame: .zero)
        wantsLayer = true
        strip.wantsLayer = true
        addSubview(strip)
        let style: @MainActor () -> SpaceThemeStyle = { [unowned context] in
            context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        }
        for (b, key) in [(home, SidebarHoverTarget.home), (plus, .plus)] {
            b.context = context
            b.dimsWhenInactive = true
            b.inactiveTint = SidebarRole.bottomGlyphInactive
            b.hoverKey = key
            b.glyphTint = { _ in SidebarRole.bottomGlyph.nsColor }
            addSubview(b)
        }
        home.glyphTint = { _ in SidebarRole.homeGlyph.nsColor }
        home.inactiveTint = SidebarRole.homeGlyphInactive
        home.action = { [unowned context] in context.send(.showLibrary) }
        home.tooltip = { Tooltip(title: "Library", placement: .above, style: style()) }
        plus.menuProvider = { [weak self] in self?.menus.plus() }
        plus.tooltip = { Tooltip(title: "New…", placement: .above, style: style()) }
        loop = ObservationLoop(read: { [weak self] in _ = self?.context.model.spaces.map(\.id) }) { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loop?.cancel() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let m = BottomBarMetrics.self
        let w = bounds.width
        home.frame = CGRect(origin: CGPoint(x: m.homeX, y: m.buttonY), size: m.buttonSize)
        plus.frame = CGRect(origin: CGPoint(x: w - m.plusTrailingInset - m.buttonSize.width, y: m.buttonY), size: m.buttonSize)
        let stripRect = CGRect(x: m.switcherLeading, y: 0, width: max(0, w - m.switcherLeading - m.switcherTrailing), height: m.height)
        strip.frame = stripRect
        let spaces = context.model.spaces
        let live = Set(spaces.map(\.id))
        for (id, v) in items where !live.contains(id) { v.removeFromSuperview(); items[id] = nil }
        // Centered when the items fit (4 Spaces: 136 pt in a 144 pt strip → 4 pt each side).
        let total = CGFloat(spaces.count) * m.switcherPitch
        let x0 = total <= stripRect.width ? (stripRect.width - total) / 2 - 1 : -1
        for (i, space) in spaces.enumerated() {
            let v = items[space.id] ?? {
                let v = SwitcherItemView(context: context, space: space, menus: menus)
                items[space.id] = v
                strip.addSubview(v)
                return v
            }()
            v.index = i
            v.frame = CGRect(x: x0 + CGFloat(i) * m.switcherPitch, y: m.switcherItemY, width: m.switcherItemSize.width, height: m.switcherItemSize.height)
        }
    }
}

/// One Space in the switcher: emoji in color when current, faded and gray otherwise.
@MainActor
final class SwitcherItemView: PlateButton {
    let space: Space
    let icon = SpaceIconView()
    var index = 0
    let menus: SidebarMenus
    private var springLoad: DispatchWorkItem?
    private var springPayload: [ItemID]?
    private var springScheduled = false

    isolated deinit { springLoad?.cancel() }

    init(context: SidebarContext, space: Space, menus: SidebarMenus) {
        self.space = space
        self.menus = menus
        super.init(glyph: nil)
        self.context = context
        hoverKey = .switcher(space.id)
        plateRect = { $0.insetBy(dx: BottomBarMetrics.switcherPlateInset.width, dy: BottomBarMetrics.switcherPlateInset.height) }
        plateRadius = BottomBarMetrics.plateRadius
        icon.space = space
        icon.context = context
        icon.emojiSize = BottomBarMetrics.switcherEmojiSize
        addSubview(icon)
        action = { [unowned context, space] in context.send(.switchSpace(space.id)) }
        menuProvider = nil
        tooltip = { [weak self, unowned context] in
            guard let self else { return nil }
            let keys = self.index < 9 ? ["⌃", "\(self.index + 1)"] : []
            return Tooltip(title: context.title(of: space), keys: keys, placement: .above, style: context.style(for: space))
        }
        registerForDraggedTypes([.sidebarNode, .URL, .fileURL])
        accessibleTitle = { [unowned context, space] in context.title(of: space) }
    }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    override func updateLayer() {
        super.updateLayer()
        guard let context else { return }
        let current = tracked({ context.focusedSpace === space }) { [weak self] in self?.needsDisplay = true }
        icon.desaturated = !current
        icon.alphaValue = current ? 1 : SidebarRole.switcherInactiveOpacity
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menus.space(space), with: event, for: self)
    }

    private func operation(for pb: NSPasteboard) -> NSDragOperation {
        guard let context, context.model.space(id: space.id) != nil else { return [] }
        if let ids = SidebarPasteboard.nodeIDs(from: pb) {
            return !ids.isEmpty && ids.allSatisfy {
                context.model.canMoveNode(id: $0, to: SidebarPasteboard.destination(for: $0, in: space.id, model: context.model))
            } ? .move : []
        }
        return SidebarPasteboard.urls(from: pb).isEmpty ? [] : .copy
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender.draggingPasteboard)
        guard !operation.isEmpty else { cancelSpringLoad(); return [] }
        let ids = SidebarPasteboard.nodeIDs(from: sender.draggingPasteboard)
        if !springScheduled || springPayload != ids {
            cancelSpringLoad()
            springScheduled = true
            springPayload = ids
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.springScheduled, let context = self.context else { return }
                    if let ids, !ids.allSatisfy({ context.model.canMoveNode(id: $0, to: SidebarPasteboard.destination(for: $0, in: self.space.id, model: context.model)) }) { return }
                    context.send(.switchSpace(self.space.id))
                }
            }
            springLoad = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        return operation
    }

    private func cancelSpringLoad() {
        springLoad?.cancel()
        springLoad = nil
        springScheduled = false
        springPayload = nil
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { cancelSpringLoad() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { cancelSpringLoad() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { cancelSpringLoad() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(for: sender.draggingPasteboard).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        cancelSpringLoad()
        guard !operation(for: sender.draggingPasteboard).isEmpty, let context else { return false }
        if let ids = SidebarPasteboard.nodeIDs(from: sender.draggingPasteboard) {
            // Insert in reverse order at zero, keeping each source section's order.
            let moves = ids.map { ($0, SidebarPasteboard.destination(for: $0, in: space.id, model: context.model)) }
            for (id, parent) in moves.reversed() {
                guard context.send(.move(nodeID: id, to: parent, index: 0)) else { return false }
            }
            return true
        }
        let urls = SidebarPasteboard.urls(from: sender.draggingPasteboard)
        for url in urls.reversed() {
            guard context.send(.openURL(url, in: .spaceToday(space.id), index: 0)) else { return false }
        }
        return !urls.isEmpty
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelSpringLoad() }
        super.viewWillMove(toWindow: newWindow)
    }
}
