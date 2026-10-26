import AppKit
import QuartzCore
import OpenModel
import OpenDesign

@MainActor
public final class SiteControlController: NSObject {
    public let view = SiteControlView(frame: .zero)
    public private(set) var isPresented = false
    public private(set) var tabID: ItemID?
    public private(set) var anchor: SiteControlAnchor?
    public private(set) var mode = SiteControlPresentationMode.standard
    public var geometry: ((SiteControlAnchor) -> SiteControlGeometry?)?
    public var onDismiss: ((SiteControlDismissReason) -> Void)?
    public var onUnavailable: ((ItemID) -> Void)?
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
        view.panel.onSecurity = { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.actions.showSecurityDetails(tabID: tabID)
        }
        changeObserver = source.observeChanges { [weak self] changed in
            guard let self, self.isPresented, self.tabID == changed else { return }
            guard let snapshot = self.source.snapshot(for: changed) else {
                self.reportUnavailable(changed); return
            }
            self.view.panel.apply(snapshot); self.layout()
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
        self.anchor = anchor; self.tabID = tabID; self.mode = mode
        presentationGeneration += 1
        isPresented = true; view.isHidden = false; view.isActive = true
        view.panel.apply(snapshot); layout()
        guard isPresented else { return }
        unavailableTabs.remove(tabID)
        view.window?.makeFirstResponder(view)
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
        isPresented = false; view.isActive = false
        presentationGeneration += 1; let generation = presentationGeneration
        view.window?.makeFirstResponder(previousResponder)
        let finish = { [weak self] in
            guard let self, self.presentationGeneration == generation, !self.isPresented else { return }
            self.view.isHidden = true; self.view.presentationLayers.forEach { $0.removeAllAnimations() }
        }
        if animated {
            CATransaction.begin(); CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            for layer in view.presentationLayers {
                layer.removeAllAnimations(); let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = (layer.presentation() ?? layer).opacity; fade.toValue = 0
                fade.duration = Motion.popoverClose; layer.opacity = 0; layer.add(fade,forKey: "close.opacity")
            }
            CATransaction.commit()
        } else { finish() }
        onDismiss?(reason)
    }
    @discardableResult public func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.keyCode == 53 { dismiss(reason: .escape); return true }
        if event.modifierFlags.contains(.command) { dismiss(reason: .command, animated: false); return false }
        return false
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
                let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.66; scale.toValue = 1
                scale.duration = Motion.popoverOpen; scale.timingFunction = Motion.easeOut; layer.add(scale, forKey: "open.scale")
            }
        }
    }
}
