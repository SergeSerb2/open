import AppKit
import QuartzCore
import OpenModel
import OpenDesign
import OpenBoosts

@MainActor
public final class SiteControlController: NSObject, NSMenuDelegate {
    public let view = SiteControlView(frame: .zero)
    public private(set) var isPresented = false
    public private(set) var tabID: ItemID?
    public private(set) var anchor: SiteControlAnchor?
    public private(set) var mode = SiteControlPresentationMode.standard
    public var geometry: ((SiteControlAnchor) -> SiteControlGeometry?)?
    public var onDismiss: ((SiteControlDismissReason) -> Void)?
    public var onUnavailable: ((ItemID) -> Void)?
    /// Observes the native menu after it opens; it does not replace presentation.
    public var onMenu: ((NSMenu, String?) -> Void)?
    public private(set) var preferredMenuItemTitle: String?
    private let source: SiteControlDataSource
    private let actions: SiteControlActions
    private weak var previousResponder: NSResponder?
    private var unavailableTabs: Set<ItemID> = []
    private var changeObserver: SiteControlObservationToken?
    private var presentationGeneration = 0
    private var activeMenu: NSMenu?
    private var menuActionInvoked = false

    public init(source: SiteControlDataSource, actions: SiteControlActions) {
        self.source = source; self.actions = actions
        super.init(); view.isHidden = true
        view.onOutside = { [weak self] in self?.dismiss(reason: .outside, animated: false) }
        view.onAnchor = { [weak self] in self?.dismiss(reason: .anchor, animated: false) }
        view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        view.panel.onAction = { [weak self] action, rect in self?.performAction(action, rect: rect) }
        view.panel.onMore = { [weak self] button in self?.showMenu(from: button) }
        view.panel.onToggle = { [weak self] tile in
            guard let self, let tabID = self.tabID else { return }
            if tile.state == .unavailable {
                self.actions.openAdBlockSettings(tabID: tabID)
            } else {
                self.actions.toggle(tile, tabID: tabID); self.view.panel.showsReload = true
                self.refreshView(animated: true)
            }
        }
        view.panel.onBoostEnabled = { [weak self] id, enabled in
            guard let self, let tabID = self.tabID else { return }
            self.actions.setBoostEnabled(id, enabled: enabled, tabID: tabID)
        }
        view.panel.onEdit = { [weak self] id in
            guard let self, let tabID = self.tabID else { return }
            self.dismiss(reason: .action, animated: false)
            self.actions.openEditor(boostID: id, tabID: tabID, mode: .simple)
        }
        view.panel.onSection = { [weak self] section in
            guard let self, let tabID = self.tabID else { return }
            self.dismiss(reason: .action, animated: false)
            if section == "settings" { self.openSiteSettings(tabID: tabID) }
            else { self.actions.perform(command: section == "boosts" ? "view-boosts" : "manage-extensions", tabID: tabID, anchor: nil) }
        }
        view.panel.onReload = { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.dismiss(reason: .action, animated: false); self.actions.reload(tabID: tabID)
        }
        view.panel.onSecurity = { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.actions.showSecurityDetails(tabID: tabID)
        }
        changeObserver = source.observeChanges { [weak self] changed in
            guard let self, self.isPresented, self.tabID == changed else { return }
            self.refreshView(animated: true)
        }
    }
    isolated deinit { if let changeObserver { source.removeChangeObserver(changeObserver) } }
    public func toggle(anchor: SiteControlAnchor, tabID: ItemID, animated: Bool = true) {
        if isPresented && self.anchor == anchor && self.tabID == tabID { dismiss(reason: .anchor, animated: animated) }
        else { present(anchor: anchor, tabID: tabID, mode: .standard, animated: animated) }
    }
    public func present(anchor: SiteControlAnchor, tabID: ItemID, mode: SiteControlPresentationMode = .standard, animated: Bool = true) {
        guard let snapshot = source.snapshot(for: tabID), geometry?(anchor) != nil else { reportUnavailable(tabID); return }
        if !isPresented { previousResponder = view.window?.firstResponder }
        self.anchor = anchor; self.tabID = tabID
        self.mode = mode
        preferredMenuItemTitle = mode == .extensionPicker && !view.panel.extensionsSectionVisible ? "Add Extension…" : nil
        presentationGeneration += 1
        isPresented = true; view.isHidden = false; view.isActive = true
        view.clearStructureAnimations()
        view.panel.showsReload = false
        view.panel.apply(snapshot); configureKeys(); layout()
        guard isPresented else { return }
        unavailableTabs.remove(tabID)
        view.window?.makeFirstResponder(view)
        if mode == .extensionPicker {
            if view.panel.extensionsSectionVisible {
                // Picker item focus lands with OpenExtensionsUI.
                // The harness deliberately fails until that focus path is wired.
            } else { view.panel.focus(view.panel.more) }
        }
        animateOpen(animated)
    }
    public func layout() {
        guard let anchor, let tabID else { return }
        guard let g = geometry?(anchor) else { reportUnavailable(tabID); return }
        view.anchorFrame = g.anchor
        let m = SiteControlMetrics.self
        let h = min(view.panel.preferredHeight, m.maxHeight, max(0, view.bounds.height - 2 * m.windowMargin))
        let w = m.width
        let point: CGPoint
        switch anchor {
        case .urlField:
            point = CGPoint(x: g.sidebarMaxX + m.sidebarPanelGap,
                            y: min(max(g.anchor.midY - m.anchorAlignmentY, m.windowMargin), max(m.windowMargin, view.bounds.height - h - m.windowMargin)))
        case .paneBar:
            point = CGPoint(x: min(max(g.anchor.maxX + m.windowMargin - w, m.windowMargin), max(m.windowMargin, view.bounds.width - w - m.windowMargin)),
                            y: min(g.anchor.maxY + m.panePanelGap, max(m.windowMargin, view.bounds.height - h - m.windowMargin)))
        case .contentTopLeading:
            point = CGPoint(x: g.content.minX + m.contentAnchorInset, y: g.content.minY + m.contentAnchorInset)
        }
        view.panel.frame = CGRect(origin: point, size: CGSize(width: w, height: h))
        view.panel.needsLayout = true; view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
    }
    private func reportUnavailable(_ tabID: ItemID) {
        if isPresented { dismiss(reason: .sourceUnavailable, animated: false) }
        guard unavailableTabs.insert(tabID).inserted else { return }
        FileHandle.standardError.write(Data("SiteControl: snapshot or geometry unavailable for tab \(tabID)\n".utf8))
        onUnavailable?(tabID)
    }
    public func dismiss(reason: SiteControlDismissReason, animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        activeMenu?.cancelTrackingWithoutAnimation()
        view.panel.controls.forEach { TooltipController.shared.cancel(for: $0) }
        presentationGeneration += 1
        let generation = presentationGeneration
        view.isActive = false
        view.window?.makeFirstResponder(previousResponder)
        animateClose(animated) { [weak self] in
            guard let self, self.presentationGeneration == generation, !self.isPresented else { return }
            self.view.isHidden = true; self.view.presentationLayers.forEach { $0.removeAllAnimations() }
        }
        onDismiss?(reason)
    }
    @discardableResult public func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if let menu = activeMenu {
            if event.keyCode == 53 { dismiss(reason: .menuCancelled,animated: false); return true }
            if event.keyCode == 36, let item = menu.highlightedItem, item.isEnabled {
                menu.performActionForItem(at: menu.index(of: item)); menu.cancelTrackingWithoutAnimation(); return true
            }
        }
        if event.keyCode == 53 { dismiss(reason: .escape); return true }
        if event.modifierFlags.contains(.command) { dismiss(reason: .command, animated: false); return false }
        let controls = view.panel.focusableControls
        guard !controls.isEmpty else { return false }
        let current = controls.firstIndex { view.window?.firstResponder === $0 }
        if event.keyCode == 48 {
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            let index = current.map { ($0 + delta + controls.count) % controls.count } ?? (delta > 0 ? 0 : controls.count - 1)
            view.panel.focus(controls[index]); return true
        }
        if event.keyCode == 36 && view.panel.editFocusedBoost() { return true }
        if event.keyCode == 36 || event.keyCode == 49 {
            guard let current else { return false }; controls[current].showsKeyboardFocus = true; controls[current].performClick(nil); return true
        }
        if [123, 124, 125, 126].contains(event.keyCode), let current {
            let button = controls[current], id = button.controlID
            let group: [SiteControlButton]
            let step: Int
            let backwards = event.keyCode == 123 || event.keyCode == 126
            if id.hasPrefix("action.") { group = controls.filter { $0.controlID.hasPrefix("action.") }; step = 1 }
            else if id.hasPrefix("permission.") || id == "contentBlocking" || id.hasPrefix("content.") {
                group = controls.filter { $0 is SiteControlTileButton }; step = [125, 126].contains(event.keyCode) ? 2 : 1
            } else if id.hasPrefix("boost.") {
                group = controls.filter { $0.controlID.hasPrefix("boost.") }; step = [125, 126].contains(event.keyCode) ? 2 : 1
            } else { group = controls; step = 1 }
            if let position = group.firstIndex(where: { $0 === button }) {
                let index = max(0, min(group.count - 1, position + (backwards ? -step : step)))
                view.panel.focus(group[index])
            }
            return true
        }
        return false
    }
    private func configureKeys() { view.panel.configureKeys { [weak self] in self?.handleKey($0) ?? false } }
    private func refreshView(animated: Bool) {
        guard let tabID else { return }
        guard let snapshot = source.snapshot(for: tabID) else { reportUnavailable(tabID); return }
        let focusedID = (view.window?.firstResponder as? NSView)?.identifier?.rawValue
        let oldHeight = view.panel.frame.height
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let structure = animated && !reduceMotion ? view.captureStructure() : []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.panel.apply(snapshot); configureKeys(); layout()
        guard isPresented else { return }
        if let focusedID {
            if let button = view.panel.control(id: focusedID), button.isEnabled { view.panel.focus(button,keyboard: button.showsKeyboardFocus) }
            else { view.window?.makeFirstResponder(view) }
        }
        if animated, oldHeight != view.panel.frame.height {
            // Resolve layer geometry and paths before assigning animation
            // destinations. Keep display and animations in one transaction.
            view.displayIfNeeded()
            if reduceMotion {
                for layer in view.presentationLayers {
                    let fade = CATransition(); fade.type = .fade; fade.duration = Motion.rowStructure
                    fade.timingFunction = Motion.easeInOut; layer.add(fade, forKey: "rows.fade")
                }
            } else { structure.forEach { $0.animate() } }
        }
    }

    public func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let snapshot = view.panel.snapshot else { return menu }
        func item(_ title: String, _ id: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.isEnabled = enabled; menu.addItem(item)
        }
        func separator() { if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) } }
        if snapshot.context.isWebsite {
            if snapshot.capabilities.contains(.clearCache) { item("Clear Cache", "clearCache") }
            item("Clear Cookies", "clearCookies")
        }
        if !view.panel.boostsSectionVisible {
            separator(); item("Manage Boosts…", "view-boosts")
            if snapshot.canCreateBoost { item("New Boost…", "newBoost") }
        }
        separator(); item("Manage Extensions…", "manage-extensions"); item("Add Extension…", "add-extension")
        if snapshot.context.isWebsite { separator(); item("All Site Settings…", "siteSettings") }
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let id = sender.representedObject as? String, let tabID else { return }
        menuActionInvoked = true
        switch id {
        case "clearCache", "clearCookies":
            actions.clearSiteData(id == "clearCache" ? .cache : .cookies, tabID: tabID)
            view.panel.showsReload = true; refreshView(animated: true)
        case "newBoost":
            dismiss(reason: .action, animated: false); actions.openEditor(boostID: nil, tabID: tabID, mode: .simple)
        case "siteSettings": dismiss(reason: .action, animated: false); openSiteSettings(tabID: tabID)
        default: dismiss(reason: .action, animated: false); actions.perform(command: id, tabID: tabID, anchor: nil)
        }
    }
    public func menuWillOpen(_ menu: NSMenu) { onMenu?(menu, preferredMenuItemTitle) }
    private func showMenu(from button: NSView) {
        guard button.window?.isVisible == true else { return }
        let menu = makeMenu(); menu.delegate = self
        activeMenu = menu; menuActionInvoked = false
        let selected = menu.popUp(positioning: menu.items.first { $0.title == preferredMenuItemTitle } ?? menu.items.first { $0.isEnabled && !$0.isSeparatorItem },
                                  at: CGPoint(x: button.bounds.minX, y: button.bounds.maxY), in: button)
        activeMenu = nil
        if !selected && !menuActionInvoked && isPresented { dismiss(reason: .menuCancelled, animated: false) }
    }
    private func openSiteSettings(tabID: ItemID) {
        guard let context = source.snapshot(for: tabID)?.context,
              var origin = URLComponents(url: context.url, resolvingAgainstBaseURL: false) else { return }
        origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
        var url = URLComponents(string: "chrome://settings/content/siteDetails")!
        url.queryItems = [URLQueryItem(name: "site", value: origin.string)]
        if let url = url.url { actions.openURLInNewTab(url, tabID: tabID) }
    }
    private func performAction(_ id: String, rect: NSRect) {
        guard let tabID else { return }
        dismiss(reason: .action, animated: false)
        if id == "newBoost" { actions.openEditor(boostID: nil, tabID: tabID, mode: .simple); return }
        let commands = ["share": "share-page", "copyURL": "copy-url", "capture": "capture-page", "captureFull": "capture-full-page", "capturePortrait": "capture-portrait"]
        if let command = commands[id] { actions.perform(command: command, tabID: tabID, anchor: rect) }
    }
    private func animateOpen(_ animated: Bool) {
        for layer in view.presentationLayers {
            layer.removeAllAnimations(); layer.opacity = 1; layer.transform = CATransform3DIdentity
            guard animated else { continue }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.duration = Motion.popoverOpen; fade.timingFunction = Motion.easeOut; layer.add(fade, forKey: "open.opacity")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = CABasicAnimation(keyPath: "transform")
                scale.fromValue = NSValue(caTransform3D: transform(scale: SiteControlMetrics.openScale, layer: layer))
                scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                scale.duration = Motion.popoverOpen; scale.timingFunction = Motion.easeOut; layer.add(scale, forKey: "open.scale")
            }
        }
    }
    private func transform(scale: CGFloat, layer: CALayer) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }
    private func animateClose(_ animated: Bool, completion: @escaping @MainActor () -> Void) {
        guard animated else { completion(); return }
        CATransaction.begin(); CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        for layer in view.presentationLayers {
            layer.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            fade.duration = Motion.popoverClose; fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.opacity = 0; layer.add(fade, forKey: "close.opacity")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = CABasicAnimation(keyPath: "transform"); scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                let target = transform(scale: SiteControlMetrics.closeScale, layer: layer)
                scale.toValue = NSValue(caTransform3D: target)
                scale.duration = Motion.popoverClose; scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
                layer.transform = target; layer.add(scale, forKey: "close.scale")
            }
        }
        CATransaction.commit()
    }
}
