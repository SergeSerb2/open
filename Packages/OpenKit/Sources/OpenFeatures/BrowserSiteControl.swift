import AppKit
import OpenModel
import OpenDesign
import OpenSidebar
import OpenSiteControl

extension BrowserWindowController {
    /// Resolve the actual visible control. A hidden sidebar's sliding card uses
    /// the same view and conversion, so the arrow follows its real position.
    public func visibleSiteControlAnchor(tabID: ItemID) -> NSView? {
        if let bar = container.slots.first(where: { $0.tabID == tabID })?.paneChrome,
           !bar.siteControlsAnchor.isHiddenOrHasHiddenAncestor { return bar.siteControlsAnchor }
        if tabID == splitController.focusedTab?.id, !sidebar.isHidden, sidebar.urlFieldVisible,
           !sidebar.siteControlsAnchor.isHiddenOrHasHiddenAncestor { return sidebar.siteControlsAnchor }
        return nil
    }
    func siteControlGeometry(_ anchor: SiteControlAnchor) -> SiteControlGeometry? {
        guard !(hasPeekController && peekController.isShown) else { return nil }
        let content = container.convert(container.bounds, to: root)
        if anchor == .contentTopLeading { return .init(anchor: .zero, content: content) }
        let view: NSView?
        switch anchor {
        case .urlField: view = !sidebar.isHidden && sidebar.urlFieldVisible ? sidebar.siteControlsAnchor : nil
        case .paneBar(let id): view = container.slots.first(where: { $0.tabID == id })?.paneChrome?.siteControlsAnchor
        case .contentTopLeading: view = nil
        }
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return .init(anchor: view.convert(view.bounds, to: root), content: content)
    }
    public func toggleSiteControls(anchor: SiteControlAnchor, tabID: ItemID) {
        guard let siteControl, !(hasPeekController && peekController.isShown) else { return }
        if splitController.focusedTab?.id != tabID { splitController.focus(tabID) }
        siteControlSpace = context.focusedSpace?.id
        let appearance = context.focusedSpace.map { context.style(for: $0).windowColorScheme } ?? context.systemAppearance
        siteControl.view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        applySiteControlBackdrop(siteControl.view)
        siteControl.view.frame = root.bounds
        siteControl.toggle(anchor: anchor, tabID: tabID)
        refreshSiteControlButtons()
    }
    @discardableResult public func presentExtensionPicker() -> Bool {
        guard let siteControl, let id = splitController.focusedTab?.id,
              !(hasPeekController && peekController.isShown) else { return false }
        if siteControl.isPresented && siteControl.mode == .extensionPicker {
            siteControl.dismiss(reason: .command, animated: false)
            return true
        }
        let anchor: SiteControlAnchor
        if let bar = container.slots.first(where: { $0.tabID == id })?.paneChrome, !bar.siteControlsAnchor.isHiddenOrHasHiddenAncestor {
            anchor = .paneBar(id)
        } else if !sidebar.isHidden && sidebar.urlFieldVisible {
            // Keyboard entry has a visible anchor even without sidebar hover.
            sidebar.siteControlState = .open; sidebar.refreshExtensionsLayout(); anchor = .urlField
        } else { anchor = .contentTopLeading }
        siteControlSpace = context.focusedSpace?.id; siteControl.view.frame = root.bounds
        let appearance = context.focusedSpace.map { context.style(for: $0).windowColorScheme } ?? context.systemAppearance
        siteControl.view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        applySiteControlBackdrop(siteControl.view)
        siteControl.present(anchor: anchor, tabID: id, mode: .extensionPicker)
        refreshSiteControlButtons(); return siteControl.isPresented
    }
    /// The Space accent, the sidebar colour, and the sidebar edge the panel's tint follows (LEAD 12:05).
    func applySiteControlBackdrop(_ view: SiteControlView) {
        let style = context.focusedSpace.map { context.style(for: $0) } ?? .defaultTheme(system: context.systemAppearance)
        view.panel.accent = SpaceAccent(style: style)
        view.panel.sidebarColor = SpaceAccent.sidebarTop(style: style)
        view.panel.sidebarContent = style.resolvedAppearance(system: context.systemAppearance)
        view.sidebarMaxX = sidebar.isHidden ? nil : sidebar.convert(sidebar.bounds, to: root).maxX
    }
    public func refreshSiteControlButtons() {
        let ids = Set(container.slots.map(\.tabID) + [splitController.focusedTab?.id].compactMap { $0 })
        let states = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            siteControlSource.map { (id, $0.buttonState(for: id)) }
        })
        if siteControlSource != nil {
            sidebar.siteControlsAvailable = splitController.focusedTab.map { states[$0.id]?.available == true } == true
                && !(hasPeekController && peekController.isShown)
        }
        func state(_ id: ItemID?) -> SiteControlButtonState {
            let boosted = id.flatMap { states[$0] }?.boosted == true
            let open = siteControl?.isPresented == true && siteControl?.tabID == id
            return open ? (boosted ? .openBoosted : .open) : (boosted ? .boosted : .rest)
        }
        sidebar.siteControlState = state(splitController.focusedTab?.id)
        for slot in container.slots { slot.paneChrome?.siteControlState = state(slot.tabID) }
    }
    func scheduleSiteControlButtonsRefresh() {
        guard !siteControlButtonsRefreshPending else { return }
        siteControlButtonsRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.siteControlButtonsRefreshPending = false
            self.refreshSiteControlButtons()
        }
    }
}
