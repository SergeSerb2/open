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
        if isPresented && self.anchor != anchor { dismiss(reason: .anchor,animated: false) }
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
        if event.keyCode == 53 { dismiss(reason: .escape); return true }
        if event.modifierFlags.contains(.command) { dismiss(reason: .command, animated: false); return false }
        return false
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
