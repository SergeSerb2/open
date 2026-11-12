import AppKit
import QuartzCore
import OpenModel
import OpenDesign
import OpenBoosts
import OpenExtensionsUI
import os

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
    /// Optional until the App wiring step. Refresh explicitly on engine action events.
    public var extensionsUIContext: ExtensionsUIContext? {
        didSet {
            view.panel.extensionsContext = extensionsUIContext
            configureExtensions()
            if isPresented { configureKeys(); layout() }
        }
    }
    public func refreshExtensions() {
        let restoreFocus = extensionsUIContext != nil && view.window?.firstResponder === view.panel.extensionsBody
        view.panel.reloadExtensions(); configureKeys(); if isPresented { layout() }
        // Removing/reinserting the document's section makes AppKit drop its responder.
        // The shared body retains the selected ID across action updates.
        if restoreFocus && isPresented { view.window?.makeFirstResponder(view.panel.extensionsBody) }
    }
    /// Automation opt-in: forces native display/submission for the receipt.
    /// Nil in the shipping App, which keeps AppKit's normal draw scheduling.
    public var onFirstDraw: ((Double) -> Void)?
    /// Automation only: the first draw's phase split, in ms from the request (LEAD 17:40 P1 investigation).
    public var onFirstDrawPhases: (([String: Double]) -> Void)?
    private static let performanceLog = OSLog(subsystem: "io.github.sergeserb2.open", category: "SiteControl")
    public var onMenu: ((NSMenu,String?) -> Void)?
    public private(set) var preferredMenuItemTitle: String?
    private var activeMenu: NSMenu?
    private var menuActionInvoked = false
    private let source: SiteControlDataSource
    private let actions: SiteControlActions
    private weak var previousResponder: NSResponder?
    private var unavailableTabs: Set<ItemID> = []
    private var presentationGeneration = 0
    private var changeObserver: SiteControlObservationToken?

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
                let generation = self.presentationGeneration
                self.actions.toggle(tile, tabID: tabID)
                guard self.isPresented,self.tabID == tabID,self.presentationGeneration == generation else { return }
                self.view.panel.showsReload = true; self.refreshView(animated: true)
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
        view.panel.onAddExtension = { [weak self] in
            guard let self,let tabID = self.tabID else { return }
            self.dismiss(reason: .action,animated: false)
            self.actions.perform(command: "add-extension",tabID: tabID,anchor: nil)
        }
        view.panel.onSecurity = { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.dismiss(reason: .action, animated: false)
            self.actions.showSecurityDetails(tabID: tabID)
        }
        changeObserver = source.observeChanges { [weak self] changed in
            guard let self, self.isPresented, self.tabID == changed else { return }
            self.refreshView(animated: true)
        }
    }
    private func configureExtensions() {
        guard extensionsUIContext != nil else { return }
        view.panel.extensionsBody.onClose = { [weak self] in self?.dismiss(reason: .escape, animated: false) }
        view.panel.extensionsBody.onUnhandledKey = { [weak self] in self?.handleKey($0) ?? false }
        view.panel.extensionsBody.onIntent = { [weak self] intent in
            guard let self, self.isPresented, let context = self.extensionsUIContext else { return }
            switch intent {
            case let .run(id, anchor):
                self.dismiss(reason: .action, animated: false); context.run?(id, .menuEntry, anchor)
            case let .togglePin(id): context.togglePin?(id)
            case let .contextMenu(id, anchor, event): context.contextMenu?(id, anchor, event)
            case .addExtension:
                if let add = context.addExtension { self.dismiss(reason: .action, animated: false); add() }
                else { self.view.panel.onAddExtension?() }
            }
        }
    }
    isolated deinit { if let changeObserver { source.removeChangeObserver(changeObserver) } }
    public func toggle(anchor: SiteControlAnchor, tabID: ItemID, animated: Bool = true) {
        if isPresented && self.anchor == anchor && self.tabID == tabID { dismiss(reason: .anchor, animated: animated) }
        else { present(anchor: anchor, tabID: tabID, mode: .standard, animated: animated) }
    }
    public func present(anchor: SiteControlAnchor, tabID: ItemID, mode: SiteControlPresentationMode = .standard, animated: Bool = true) {
        let requestedAt = CACurrentMediaTime()
        let signpost = OSSignpostID(log: Self.performanceLog)
        let measureFirstDraw = onFirstDraw
        var phases: [String: Double] = [:]
        func mark(_ name: String) { if measureFirstDraw != nil { phases[name] = (CACurrentMediaTime() - requestedAt) * 1000 } }
        os_signpost(.begin, log: Self.performanceLog, name: "ClickToFirstDraw", signpostID: signpost)
        defer { os_signpost(.end, log: Self.performanceLog, name: "ClickToFirstDraw", signpostID: signpost) }
        guard let snapshot = source.snapshot(for: tabID), geometry?(anchor) != nil else { reportUnavailable(tabID); return }
        mark("snapshot")
        if isPresented && self.anchor != anchor { dismiss(reason: .anchor,animated: false) }
        if !isPresented { previousResponder = view.window?.firstResponder }
        self.anchor = anchor; self.tabID = tabID
        self.mode = mode
        if extensionsUIContext != nil { view.panel.extensionsBody.pickerMode = false }
        presentationGeneration += 1
        isPresented = true; view.isHidden = false; view.isActive = true
        view.panel.showsReload = false
        view.panel.apply(snapshot)
        if extensionsUIContext != nil { view.panel.reloadExtensions() }
        mark("apply")
        configureKeys(); layout()
        mark("layout")
        guard isPresented else { return }
        unavailableTabs.remove(tabID)
        view.window?.makeFirstResponder(view)
        if self.mode == .extensionPicker { view.panel.focusExtensionPickerItem() }
        animateOpen(animated)
        mark("focusAndAnimation")
        if let measureFirstDraw {
            // The automation callback is installed only by OPEN_AUTOMATION.
            view.layoutSubtreeIfNeeded()
            mark("subtreeLayout")
            view.displayIfNeeded()
            mark("display")
            CATransaction.flush()
            mark("flush")
            measureFirstDraw((CACurrentMediaTime() - requestedAt) * 1000)
            onFirstDrawPhases?(phases)
        }
    }
    public func layout() { layout(preservingStructureMotion: false) }
    private func layout(preservingStructureMotion: Bool) {
        if !preservingStructureMotion { view.clearStructureAnimations() }
        guard let anchor, let tabID else { return }
        guard let g = geometry?(anchor) else { reportUnavailable(tabID); return }
        view.anchorFrame = g.anchor
        let m = SiteControlMetrics.self
        let width = m.width
        let hasArrow = anchor != .contentTopLeading
        let tipY = hasArrow ? g.anchor.maxY+m.arrowTipBelowAnchor : g.content.minY+m.contentAnchorInset
        let bodyTop = tipY+(hasArrow ? m.arrowHeight : 0)
        let height = min(view.panel.preferredHeight,m.maxHeight,max(0,view.bounds.maxY-m.windowMargin-bodyTop))
        let idealX = hasArrow ? g.anchor.midX-width/2 : g.content.minX+m.contentAnchorInset
        let x = min(max(idealX,m.windowMargin),max(m.windowMargin,view.bounds.maxX-width-m.windowMargin))
        let limit = m.cornerRadius+(m.arrowBaseWidth+2*m.arrowBaseFillet)/2
        view.panel.arrowX = hasArrow ? min(max(g.anchor.midX-x,limit),width-limit) : nil
        view.panel.frame = CGRect(x: x,y: tipY,width: width,height: height+(hasArrow ? m.arrowHeight : 0))
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
        isPresented = false; view.isActive = false
        activeMenu?.cancelTrackingWithoutAnimation()
        view.panel.controls.forEach { TooltipController.shared.cancel(for: $0) }
        presentationGeneration += 1; let generation = presentationGeneration
        view.window?.makeFirstResponder(previousResponder)
        let finish = { [weak self] in
            guard let self, self.presentationGeneration == generation, !self.isPresented else { return }
            self.view.isHidden = true; self.view.presentationLayers.forEach { $0.removeAllAnimations() }
        }
        if animated {
            view.prepareAnimationAnchor()
            CATransaction.begin(); CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            for layer in view.presentationLayers {
                let displayedOpacity = (layer.presentation() ?? layer).opacity
                let displayedScale = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
                layer.removeAllAnimations(); let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = displayedOpacity; fade.toValue = 0
                fade.duration = Motion.popoverClose; fade.timingFunction = CAMediaTimingFunction(name: .easeIn); layer.opacity = 0; layer.add(fade,forKey: "close.opacity")
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = displayedScale; scale.toValue = SiteControlMetrics.closeScale
                    scale.duration = Motion.popoverClose; scale.timingFunction = CAMediaTimingFunction(name: .easeIn); layer.add(scale,forKey: "close.scale")
                }
            }
            CATransaction.commit()
        } else { finish() }
        onDismiss?(reason)
    }
    @discardableResult public func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.modifierFlags.contains(.command) { dismiss(reason: .command,animated: false); return false }
        if let menu = activeMenu {
            if event.keyCode == 53 { dismiss(reason: .menuCancelled,animated: false); return true }
            if event.keyCode == 36, let item = menu.highlightedItem, item.isEnabled {
                menu.performActionForItem(at: menu.index(of: item)); menu.cancelTrackingWithoutAnimation(); return true
            }
        }
        if event.keyCode == 53 { dismiss(reason: .escape); return true }
        let controls = view.panel.focusableControls
        guard !controls.isEmpty else { return false }
        let current = controls.firstIndex { view.window?.firstResponder === $0 }
        if event.keyCode == 48 {
            let backwards = event.modifierFlags.contains(.shift)
            if view.panel.hasExtensionItems, let section = controls.firstIndex(where: { $0.controlID == "section.extensions" }) {
                if view.window?.firstResponder === view.panel.extensionsBody {
                    view.panel.focus(controls[min(controls.count - 1, section + (backwards ? 0 : 1))]); return true
                }
                if current == section && !backwards || current == section + 1 && backwards {
                    view.panel.focusExtensionPickerItem(); return true
                }
            }
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            let index = current.map { ($0 + delta + controls.count) % controls.count } ?? (delta > 0 ? 0 : controls.count - 1)
            view.panel.focus(controls[index]); return true
        }
        if event.keyCode == 36 || event.keyCode == 49 {
            guard let current else { return false }; view.panel.focus(controls[current]); controls[current].performClick(nil); return true
        }
        if [123, 124, 125, 126].contains(event.keyCode), let current {
            let button = controls[current], id = button.controlID
            let group: [SiteControlButton]
            let step: Int
            let backwards = event.keyCode == 123 || event.keyCode == 126
            if id.hasPrefix("action.") { group = controls.filter { $0.controlID.hasPrefix("action.") }; step = 1 }
            else if id.hasPrefix("extension.") {
                group = controls.filter { $0.controlID.hasPrefix("extension.") }; step = [125,126].contains(event.keyCode) ? 4 : 1
            } else if button is SiteControlRow && !id.hasPrefix("boost.") {
                group = controls.filter { $0 is SiteControlRow && !$0.controlID.hasPrefix("boost.") }; step = 1
            } else if id.hasPrefix("boost.") {
                group = controls.filter { $0.controlID.hasPrefix("boost.") }; step = 1
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
        let focused = view.window?.firstResponder as? SiteControlButton
        // apply() rebuilds the document and reinserts the shared extensions body, which makes
        // AppKit drop its responder (as in refreshExtensions). The body keeps its focused ID.
        let extensionsFocused = extensionsUIContext != nil && view.window?.firstResponder === view.panel.extensionsBody
        let oldHeight = view.panel.frame.height
        let structure = view.panel.captureStructure(extra: [view.panelShadow])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.panel.apply(snapshot); configureKeys(); layout(preservingStructureMotion: true)
        guard isPresented else { CATransaction.commit(); return }
        if let focused {
            if let control = view.panel.focusableControls.first(where: { $0.controlID == focused.controlID }) {
                view.panel.focus(control,keyboard: focused.showsKeyboardFocus)
            } else { view.window?.makeFirstResponder(view) }
        } else if extensionsFocused, view.panel.extensionsBody.superview != nil {
            view.window?.makeFirstResponder(view.panel.extensionsBody)
        }
        view.prepareAnimationAnchor()
        if animated,oldHeight != view.panel.frame.height {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for layer in view.presentationLayers { let fade = CATransition(); fade.type = .fade; fade.duration = Motion.heightGrow; layer.add(fade,forKey: "rows.fade") }
            } else { structure.animate(growing: view.panel.frame.height>oldHeight,newRows: view.panel.structureRows) }
        }
        CATransaction.commit()
    }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let snapshot = view.panel.snapshot else { return menu }
        func item(_ title: String, _ id: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = SiteControlMenuCommand(id: id,tabID: snapshot.context.tabID,generation: presentationGeneration); item.isEnabled = enabled; menu.addItem(item)
        }
        func separator() { if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) } }
        if snapshot.context.isWebsite {
            if snapshot.capabilities.contains(.clearCache) { item("Clear Cache", "clearCache") }
            item("Clear Cookies", "clearCookies")
        }
        separator(); item("Manage Boosts…","view-boosts",enabled: !snapshot.context.isIncognito)
        item("New Boost…","newBoost",enabled: snapshot.canCreateBoost)
        separator(); item("Manage Extensions…", "manage-extensions"); item("Add Extension…", "add-extension")
        if snapshot.context.isWebsite { separator(); item("All Site Settings…", "siteSettings") }
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard isPresented,sender.isEnabled,let request = sender.representedObject as? SiteControlMenuCommand,
              let tabID,request.tabID == tabID,request.generation == presentationGeneration else { return }
        let id = request.id
        menuActionInvoked = true
        switch id {
        case "clearCache", "clearCookies":
            actions.clearSiteData(id == "clearCache" ? .cache : .cookies, tabID: tabID)
            guard isPresented,self.tabID == tabID,presentationGeneration == request.generation else { return }
            view.panel.showsReload = true; refreshView(animated: true)
        case "newBoost":
            dismiss(reason: .action, animated: false); actions.openEditor(boostID: nil, tabID: tabID, mode: .simple)
        case "siteSettings": dismiss(reason: .action, animated: false); openSiteSettings(tabID: tabID)
        default: dismiss(reason: .action, animated: false); actions.perform(command: id, tabID: tabID, anchor: nil)
        }
    }
    public func menuWillOpen(_ menu: NSMenu) { onMenu?(menu, preferredMenuItemTitle) }
    private func showMenu(from button: SiteControlButton) {
        guard button.window?.isVisible == true else { return }
        let menu = makeMenu(); menu.delegate = self
        activeMenu = menu; menuActionInvoked = false
        let keyboardItem = button.activationPoint == nil ? menu.items.first { $0.isEnabled && !$0.isSeparatorItem } : nil
        // NSMenu.h: nil aligns the menu content frame's corner at the pointer;
        // a selected item aligns that item's corner for keyboard presentation.
        let selected = menu.popUp(positioning: keyboardItem,
                                  at: button.activationPoint ?? CGPoint(x: button.bounds.minX,y: button.bounds.maxY),in: button)
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
        let commands = ["share": "share-page", "capture": "capture-page", "captureFull": "capture-full-page"]
        if let command = commands[id] { actions.perform(command: command, tabID: tabID, anchor: rect) }
    }
    private func animateOpen(_ animated: Bool) {
        view.prepareAnimationAnchor()
        for layer in view.presentationLayers {
            layer.removeAllAnimations(); layer.opacity = 1; layer.transform = CATransform3DIdentity
            guard animated else { continue }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.duration = Motion.popoverOpenFade; fade.timingFunction = Motion.easeOut; layer.add(fade, forKey: "open.opacity")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = Motion.popoverOpen.animation(keyPath: "transform.scale"); scale.fromValue = SiteControlMetrics.openScale; scale.toValue = 1
                scale.duration = SiteControlMetrics.openSettle; layer.add(scale,forKey: "open.scale")
            }
        }
    }
}

/// A retained native menu cannot act on a later panel/tab generation.
private struct SiteControlMenuCommand {
    let id: String
    let tabID: ItemID
    let generation: Int
}
