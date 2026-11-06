import AppKit
import QuartzCore
import CoreText
import OpenDesign
import OpenBoosts
import OpenExtensionsUI

@MainActor
public final class SiteControlView: NSView {
    public let panel = SiteControlPanelView(frame: .zero)
    public var onOutside: (() -> Void)?
    public var onAnchor: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var anchorFrame: CGRect = .zero
    let panelShadow = CALayer()
    public var isActive = false
    public var presentationLayers: [CALayer] { [panel.layer,panelShadow].compactMap { $0 } }
    public var panelFrame: CGRect { panel.convert(panel.bodyRect,to: self) }
    public var visibleArrowTip: CGPoint { panel.convert(panel.animationAnchor,to: self) }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        panelShadow.shadowColor = NSColor.black.cgColor
        panelShadow.shadowOpacity = PopoverMaterial.shadowOpacity
        panelShadow.shadowRadius = PopoverMaterial.shadowRadius
        layer?.addSublayer(panelShadow); addSubview(panel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive && !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let inside = panel.shape.contains(panel.convert(local,from: self))
        return inside ? super.hitTest(point) : self
    }
    func prepareAnimationAnchor() {
        layoutSubtreeIfNeeded(); window?.displayIfNeeded(); CATransaction.flush()
        positionLayers()
    }
    func clearStructureAnimations() {
        func clear(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("rows.") { layer.removeAnimation(forKey: key) }
            if let mask = layer.mask { clear(mask) }; layer.sublayers?.forEach(clear)
        }
        if let layer { clear(layer) }
    }
    public override func layout() { super.layout(); positionLayers() }
    private func positionLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let anchor = panel.animationAnchor
        let unit = CGPoint(x: anchor.x/max(1,panel.bounds.width),y: anchor.y/max(1,panel.bounds.height))
        let position = CGPoint(x: panel.frame.minX+anchor.x,y: panel.frame.minY+anchor.y)
        panel.layer?.anchorPoint = unit; panel.layer?.position = position
        panelShadow.bounds = panel.bounds; panelShadow.anchorPoint = unit; panelShadow.position = position
        panelShadow.shadowPath = panel.shape
        panelShadow.shadowOffset = CGSize(width: 0,height: PopoverMaterial.shadowOffsetY)
        CATransaction.commit()
    }
    public override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    public override func mouseDown(with event: NSEvent) { forwardOutside(event) }
    public override func rightMouseDown(with event: NSEvent) { forwardOutside(event) }
    public override func otherMouseDown(with event: NSEvent) { forwardOutside(event) }
    private func forwardOutside(_ event: NSEvent) {
        let point = convert(event.locationInWindow,from: nil)
        if anchorFrame.contains(point) { onAnchor?(); return }
        guard !panel.shape.contains(panel.convert(point,from: self)),let window else { return }
        onOutside?()
        if !isActive { window.sendEvent(event) }
    }
}

@MainActor
public final class SiteControlPanelView: NSView {
    public private(set) var snapshot: SiteControlSnapshot?
    public private(set) var controls: [SiteControlButton] = []
    public var onAction: ((String,NSRect) -> Void)?
    public var onMore: ((SiteControlButton) -> Void)?
    public var onSecurity: (() -> Void)?
    public var onToggle: ((SiteSettingTile) -> Void)?
    public var onBoostEnabled: ((BoostID,Bool) -> Void)?
    public var onEdit: ((BoostID) -> Void)?
    public var onSection: ((String) -> Void)?
    public var onAddExtension: (() -> Void)?
    public var onReload: (() -> Void)?
    public var showsReload = false
    private var renderedReload = false
    public let scroll = NSScrollView()
    private let body = SiteControlBodyView()
    private var bodyHeight: CGFloat = 202
    private var rowButtons: [String: SiteControlRow] = [:]
    private var boostRows: [BoostID: SiteControlBoostRow] = [:]
    private var headers: [String: SiteControlSectionButton] = [:]
    private let addExtension = SiteControlButton(id: "extension.add",label: "Add Extension",symbol: "plus",pointSize: 14)
    private var actions: [SiteControlButton] = []
    public var extensionsSectionVisible: Bool { true }
    /// App supplies the same per-window context used by its strips; no second store.
    public var extensionsContext: ExtensionsUIContext? { didSet { reloadExtensions() } }
    public private(set) lazy var extensionsBody = ExtensionsSectionBody(frame: .zero)
    public var hasExtensionItems: Bool { extensionsContext?.actions.isEmpty == false }
    public func reloadExtensions() {
        guard let snapshot else { return }
        rebuildSections(snapshot, animated: false); needsLayout = true
    }
    public var boostsSectionVisible: Bool { snapshot?.boosts.isEmpty == false }
    public private(set) var extensionPickerFocusResolved = false
    public var arrowX: CGFloat? { didSet { needsLayout = true } }
    public var bodyRect: CGRect { CGRect(x: 0,y: arrowX == nil ? 0 : SiteControlMetrics.arrowHeight,width: bounds.width,height: max(0,bounds.height-(arrowX == nil ? 0 : SiteControlMetrics.arrowHeight))) }
    public var animationAnchor: CGPoint { CGPoint(x: arrowX ?? bounds.midX,y: 0) }
    private var cachedShapeBounds: CGRect?
    private var cachedShapeArrow: CGFloat?
    private var cachedShape: CGPath?
    public var shape: CGPath {
        if cachedShapeBounds == bounds,cachedShapeArrow == arrowX,let cachedShape { return cachedShape }
        let path = PopoverShape.path(body: bodyRect,arrowTip: arrowX.map { CGPoint(x: $0,y: 0) },radius: SiteControlMetrics.cornerRadius)
        cachedShapeBounds = bounds; cachedShapeArrow = arrowX; cachedShape = path; return path
    }
    public var preferredHeight: CGFloat {
        let m = SiteControlMetrics.self
        return m.padding+m.actionButton.height+bodyHeight+m.separatorHeight+m.gapAfterSeparator+m.footerHeight+m.padding
    }
    /// Harness supplies a fitted bitmap only where WindowServer blur is unavailable.
    public var offscreenMaterial: CGImage? { didSet { material.isHidden = offscreenMaterial != nil; fallback.contents = offscreenMaterial } }
    public var offscreenMaterialFrame: CGRect? { didSet { needsLayout = true } }
    private let material = NSVisualEffectView()
    private let fallback = CALayer(), materialTint = CALayer(), surfaceMask = CAShapeLayer(), rim = CAShapeLayer(), separator = CAShapeLayer()
    private let security = SiteControlButton(id: "security",label: "Connection",symbol: "lock.fill",pointSize: SiteControlMetrics.pillLockGlyph)
    public let more = SiteControlButton(id: "more",label: "More",symbol: "ellipsis",pointSize: SiteControlMetrics.moreGlyph,weight: .bold)
    public override var isFlipped: Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.mask = surfaceMask
        setAccessibilityElement(true); setAccessibilityRole(.popover); setAccessibilityTitle("Site Control Center")
        material.material = PopoverMaterial.material; material.blendingMode = PopoverMaterial.blending; material.state = .active
        material.setAccessibilityElement(false); material.wantsLayer = true; addSubview(material)
        material.layer?.addSublayer(materialTint)
        layer?.addSublayer(fallback); layer?.addSublayer(rim); layer?.addSublayer(separator)
        let actionSpecs = [("share","Share","square.and.arrow.up"),("newBoost","New Boost",BoostGlyph.outline),("capture","Capture a portion of this page","camera"),("captureFull","Capture the full page","text.viewfinder")]
        for (id,label,symbol) in actionSpecs {
            let b = SiteControlButton(id: "action."+id,label: label,symbol: symbol,pointSize: SiteControlMetrics.actionGlyph)
            b.symbolInk = SiteControlMetrics.actionInk[controls.count]; b.style = .action; b.tooltipTitle = label; b.tooltipKeys = id == "capture" ? ["⇧","⌘","2"] : []
            b.sparkles = id == "newBoost" ? .outline : .none
            b.invoke = { [weak self,weak b] in guard let self,let b else { return }; self.onAction?(id,b.convert(b.bounds,to: nil)) }
            controls.append(b); actions.append(b); addSubview(b)
        }
        security.symbolInk = SiteControlMetrics.pillLockInk; security.style = .pill; security.invoke = { [weak self] in self?.onSecurity?() }
        more.symbolInk = SiteControlMetrics.moreInk; more.style = .more; more.isEnabled = true
        more.invoke = { [weak self] in guard let self else { return }; self.onMore?(self.more) }
        more.setAccessibilityRole(.menuButton)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.wantsLayer = true; scroll.layer?.masksToBounds = true
        scroll.setAccessibilityLabel("Site settings and Boosts"); scroll.documentView = body
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector: #selector(refreshVisibleContent),name: NSView.boundsDidChangeNotification,object: scroll.contentView)
        addSubview(scroll); addSubview(security); addSubview(more); controls += [security,more]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func apply(_ snapshot: SiteControlSnapshot) {
        guard self.snapshot != snapshot || renderedReload != showsReload else { return }
        let animated = self.snapshot != nil
        renderedReload = showsReload
        self.snapshot = snapshot; setAccessibilityLabel(snapshot.context.displayHost)
        for b in actions {
            b.isHidden = false
            if b.controlID == "action.newBoost" { b.isEnabled = snapshot.canCreateBoost }
            else if !snapshot.context.isWebsite { b.isEnabled = b.controlID == "action.share" }
            else {
                let command = ["action.share":"share-page","action.capture":"capture-page","action.captureFull":"capture-full-page"][b.controlID]!
                b.isEnabled = snapshot.commandsEnabled[command] ?? (b.controlID == "action.share")
            }
        }
        let scheme = snapshot.context.url.scheme?.lowercased(), secure = scheme == "https"
        security.isHidden = scheme != "https" && scheme != "http"
        security.title = secure ? "Secure" : "Insecure"; security.symbol = secure ? "lock.fill" : "lock.open.fill"
        security.tint = secure ? SiteControlColors.label : CommandBarColors.lockInsecure
        security.setAccessibilityLabel("Connection: "+security.title)
        security.isEnabled = snapshot.capabilities.contains(.certificateViewer); security.statusOnly = !security.isEnabled
        security.setAccessibilityRole(security.isEnabled ? .button : .staticText)
        rebuildSections(snapshot,animated: animated)
        setAccessibilityChildren(actions + [scroll] + [security,more].filter { !$0.isHidden }); needsLayout = true
    }
    public override func layout() {
        super.layout(); let m = SiteControlMetrics.self, body = bodyRect, scale = window?.backingScaleFactor ?? 1, path = shape
        CATransaction.begin(); CATransaction.setDisableActions(true)
        material.frame = bounds; fallback.frame = bounds
        materialTint.frame = material.bounds
        materialTint.backgroundColor = SiteControlColors.liveMaterialTint.cgColor(contentAppearance)
        surfaceMask.frame = bounds; surfaceMask.path = path
        // The effect view supplies only the material. Probe/calibration is Step 3;
        // the explicit inner rim is the one rim, shared with the fitted fallback.
        rim.frame = bounds; rim.path = path; rim.fillColor = nil; rim.strokeColor = SiteControlColors.rim.cgColor(contentAppearance); rim.lineWidth = 2/scale
        for (i,b) in actions.enumerated() { b.frame = CGRect(x: m.padding+CGFloat(i)*(m.actionButton.width+m.actionGap),y: body.minY+m.padding,width: m.actionButton.width,height: m.actionButton.height) }
        let footerY = body.maxY-m.padding-m.footerHeight
        scroll.frame = CGRect(x: 0,y: body.minY+m.padding+m.actionButton.height,width: body.width,height: max(0,footerY-m.gapAfterSeparator-m.separatorHeight-(body.minY+m.padding+m.actionButton.height)))
        security.frame = CGRect(x: m.padding,y: footerY,width: security.intrinsicContentSize.width,height: m.footerHeight)
        more.frame = CGRect(x: body.maxX-m.padding-m.moreButton,y: footerY,width: m.moreButton,height: m.moreButton)
        let line = CGMutablePath(), y = footerY-m.gapAfterSeparator-1/scale/2
        line.move(to: CGPoint(x: m.padding,y: y)); line.addLine(to: CGPoint(x: body.maxX-m.padding,y: y))
        separator.compositingFilter = contentAppearance == .dark ? "plusL" : nil
        separator.path = line; separator.strokeColor = SiteControlColors.separator.cgColor(contentAppearance); separator.lineWidth = 1/scale
        CATransaction.commit()
    }
}

extension SiteControlPanelView {
    private func rebuildSections(_ snapshot: SiteControlSnapshot,animated: Bool) {
        let m = SiteControlMetrics.self, oldOrigin = scroll.contentView.bounds.origin
        body.subviews.forEach { $0.removeFromSuperview() }
        controls = actions
        // Document begins immediately after actions. Its leading gap is the
        // measured 37 pt. Header baseline is exactly item top minus 14 pt.
        var y = m.gapAfterActions
        func header(_ id: String,_ title: String,_ accessory: String) {
            let button = headers[id] ?? SiteControlSectionButton(id: "section."+id,caption: title,accessory: accessory)
            headers[id] = button
            button.frame = CGRect(x: 0,y: y-m.labelBaselineAboveContent-21,width: m.width,height: m.labelRowHeight)
            button.invoke = { [weak self] in self?.onSection?(id) }
            body.addSubview(button); controls.append(button)
        }
        header("extensions","Extensions","Manage")
        if let context = extensionsContext, !context.actions.isEmpty {
            _ = extensionsBody.setActions(context.actions)
            // guess (child), S-5/S-11: the required 236 pt grid uses the SCC's
            // complete 236 pt width; rows retain the SCC's existing 10 pt inset.
            let x: CGFloat = extensionsBody.isGrid ? 0 : m.padding
            extensionsBody.frame = CGRect(x: x, y: y, width: m.width - 2 * x, height: extensionsBody.intrinsicContentSize.height)
            body.addSubview(extensionsBody); y += extensionsBody.frame.height
        } else {
            _ = extensionsBody.setActions([])
            // With no installed actions, use the plan's 48 x 32 Add tile.
            let add = addExtension
            add.style = .extensionTile; add.tooltipTitle = "Add Extension"
            add.frame = CGRect(x: m.padding,y: y,width: m.extensionTile.width,height: m.extensionTile.height)
            add.invoke = { [weak self] in self?.onAddExtension?() }; body.addSubview(add); controls.append(add)
            y += m.extensionTile.height
        }
        var nextBoosts: [BoostID: SiteControlBoostRow] = [:]
        if snapshot.context.isWebsite,!snapshot.boosts.isEmpty {
            y += m.sectionGap; header("boosts","Boosts","Manage")
            if !snapshot.boostsGloballyEnabled {
                let note = SiteControlBaselineLabel("Boosts are off. Turn them on in Settings.",multiline: true)
                note.frame = CGRect(x: m.padding,y: y,width: m.width-2*m.padding,height: m.globalOffHeight)
                body.addSubview(note); y += m.globalOffHeight
            }
            for (i,boost) in snapshot.boosts.enumerated() {
                if i>0 { y += m.rowPitch-m.rowIcon }
                let row: SiteControlBoostRow
                if let existing = boostRows[boost.id] {
                    row = existing; row.apply(boost,enabled: snapshot.boostsGloballyEnabled && !snapshot.context.isIncognito,globallyEnabled: snapshot.boostsGloballyEnabled,incognito: snapshot.context.isIncognito)
                } else { row = SiteControlBoostRow(boost,enabled: snapshot.boostsGloballyEnabled && !snapshot.context.isIncognito,globallyEnabled: snapshot.boostsGloballyEnabled,incognito: snapshot.context.isIncognito) }
                row.frame = CGRect(x: 0,y: y,width: m.width,height: m.rowIcon)
                row.toggle.invoke = { [weak self] in self?.onBoostEnabled?(boost.id,!boost.isEnabled) }
                row.invoke = { [weak self] in self?.onEdit?(boost.id) }
                body.addSubview(row); controls += [row.toggle,row]; nextBoosts[boost.id] = row; y += m.rowIcon
            }
        }
        boostRows = nextBoosts
        var nextRows: [String: SiteControlRow] = [:]
        if snapshot.context.isWebsite {
            y += m.sectionGap; header("settings","Settings","More")
            for (i,tile) in snapshot.tiles.enumerated() {
                if i>0 { y += m.rowPitch-m.rowIcon }
                let row: SiteControlRow
                if let existing = rowButtons[tile.id] { row = existing; row.apply(tile,animated: animated) }
                else { row = SiteControlRow(tile) }
                row.frame = CGRect(x: 0,y: y,width: m.width,height: m.rowIcon)
                row.invoke = { [weak self,weak row] in guard let row else { return }; self?.onToggle?(row.tile) }
                body.addSubview(row); controls.append(row); nextRows[tile.id] = row; y += m.rowIcon
            }
            if showsReload {
                y += m.reloadGap
                let label = SiteControlBaselineLabel("Reload to apply changes.")
                label.frame = CGRect(x: m.padding,y: y,width: 162,height: m.reloadRowHeight)
                let reload = SiteControlReloadButton(); reload.frame = CGRect(x: m.width-m.padding-44,y: y,width: 44,height: m.reloadRowHeight)
                reload.invoke = { [weak self] in self?.onReload?() }
                body.addSubview(label); body.addSubview(reload); controls.append(reload); y += m.reloadRowHeight
            }
        }
        rowButtons = nextRows
        bodyHeight = y+m.gapBeforeSeparator
        body.frame = CGRect(x: 0,y: 0,width: m.width,height: bodyHeight)
        controls += [security,more]
        scroll.contentView.scroll(to: CGPoint(x: 0,y: min(oldOrigin.y,max(0,bodyHeight-scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func refreshVisibleContent() {
        // Keep every row visible to AX and keyboard navigation. Defer only its
        // drawing work until its native clip view exposes it.
        let visible = scroll.documentVisibleRect
        for child in body.subviews where child.frame.intersects(visible) {
            child.needsDisplay = true
            child.subviews.forEach { $0.needsDisplay = true }
        }
    }
    public var focusableControls: [SiteControlButton] {
        controls.filter { control in
            guard control.isEnabled else { return false }
            var ancestor: NSView? = control
            while let view = ancestor { if view.isHidden { return false }; ancestor = view.superview }
            return true
        }
    }
    public var focusOrder: [String] { focusableControls.map(\.controlID) }
    public func control(id: String) -> SiteControlButton? { controls.first { $0.controlID == id } }
    func configureKeys(_ handler: @escaping (NSEvent) -> Bool) { controls.forEach { $0.onKey = handler } }
    public func focus(_ control: SiteControlButton,keyboard: Bool = true) {
        if extensionsContext != nil { extensionsBody.pickerMode = false }
        controls.forEach { $0.showsKeyboardFocus = $0 === control && keyboard }
        control.scrollToVisible(control.bounds.insetBy(dx: -2,dy: -4)); window?.makeFirstResponder(control); control.needsDisplay = true
    }
    func focusExtensionPickerItem() {
        extensionPickerFocusResolved = false
        if hasExtensionItems {
            controls.forEach { $0.showsKeyboardFocus = false }
            extensionPickerFocusResolved = extensionsBody.focusFirst()
            extensionsBody.scrollToVisible(extensionsBody.bounds.insetBy(dx: -2, dy: -2))
        } else if let add = control(id: "extension.add") {
            focus(add); extensionPickerFocusResolved = true
        }
    }
    var structureRows: [CALayer] { body.subviews.compactMap { $0.layer } }
    func captureStructure(extra: [CALayer]) -> SiteControlStructure {
        let layers = [layer,material.layer,fallback,surfaceMask,rim,separator,scroll.layer,security.layer,more.layer].compactMap { $0 }
        return SiteControlStructure(layers: layers+extra,rows: body.subviews)
    }
}

@MainActor
struct SiteControlStructure {
    struct State {
        let layer: CALayer
        let values: [String: Any]
        init(_ layer: CALayer) {
            self.layer = layer
            let shown = layer.presentation() ?? layer
            var keys = ["bounds","position"]
            if layer is CAShapeLayer { keys.append("path") }
            if layer.shadowPath != nil { keys.append("shadowPath") }
            values = keys.reduce(into: [:]) { $0[$1] = shown.value(forKeyPath: $1) }
        }
    }
    let states: [State]
    let rows: [NSView]
    init(layers: [CALayer],rows: [NSView]) { states = layers.map(State.init); self.rows = rows }
    func animate(growing: Bool,newRows: [CALayer]) {
        let duration = growing ? Motion.heightGrow : Motion.heightShrink
        let timing = CAMediaTimingFunction(name: growing ? .easeOut : .default)
        for state in states {
            for (key,old) in state.values {
                let next = state.layer.value(forKeyPath: key)
                if let oldObject = old as? NSObject,let nextObject = next as? NSObject,oldObject.isEqual(nextObject) { continue }
                let animation = CABasicAnimation(keyPath: key); animation.fromValue = old; animation.toValue = next
                animation.duration = duration; animation.timingFunction = timing; state.layer.add(animation,forKey: "rows."+key)
            }
        }
        let newIDs = Set(newRows.map(ObjectIdentifier.init)), oldIDs = Set(rows.compactMap { $0.layer }.map(ObjectIdentifier.init))
        for row in newRows where !oldIDs.contains(ObjectIdentifier(row)) {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.beginTime = CACurrentMediaTime()+max(0,duration-0.12); fade.duration = 0.12; fade.fillMode = .backwards; row.add(fade,forKey: "rows.add")
        }
        for view in rows {
            guard let row = view.layer,!newIDs.contains(ObjectIdentifier(row)) else { continue }
            // Keep removed presentation layers until their first 80 ms fade has
            // completed. They carry no view or hit target after the data change.
            guard let parent = newRows.first?.superlayer else { continue }
            parent.addSublayer(row)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = (row.presentation() ?? row).opacity; fade.toValue = 0; fade.duration = 0.08
            CATransaction.begin(); CATransaction.setCompletionBlock { [view] in MainActor.assumeIsolated { view.layer?.removeFromSuperlayer() } }; row.opacity = 0; row.add(fade,forKey: "rows.remove"); CATransaction.commit()
        }
    }
}

public enum SiteControlButtonStyle { case plain, action, pill, more, circle, extensionTile }
public enum SiteControlSparkles { case none, outline, boost }

/// Native target/action and AX control; all visible content is owned layers.
@MainActor
public class SiteControlButton: NSButton {
    public let controlID: String
    private var captionText = ""
    // NSButtonCell must stay untitled: its native text would duplicate the
    // caption layer. Keep native target/action and AX, and own the caption.
    public override var title: String {
        get { captionText }
        set { guard captionText != newValue else { return }; captionText = newValue; needsDisplay = true; invalidateIntrinsicContentSize() }
    }
    public var symbolPhase = CGPoint.zero { didSet { needsDisplay = true } }
    public var symbolInk: CGSize? { didSet { needsDisplay = true } }
    public var symbol: String { didSet { needsDisplay = true } }
    public var tint = SiteControlColors.glyph { didSet { needsDisplay = true } }
    public var style = SiteControlButtonStyle.plain { didSet { needsDisplay = true } }
    public var sparkles = SiteControlSparkles.none { didSet { needsDisplay = true } }
    public var circleOn = true { didSet { if oldValue != circleOn { animateCircleChange = true }; needsDisplay = true } }
    private var animateCircleChange = false
    public var invoke: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public private(set) var activationPoint: CGPoint?
    public var disabledOpacity: CGFloat = SiteControlMetrics.disabledAlpha
    public var statusOnly = false
    public var tooltipTitle: String?
    public var tooltipKeys: [String] = []
    public var showsKeyboardFocus = false { didSet { needsDisplay = true } }
    private let pointSize: CGFloat, weight: NSFont.Weight
    private var trackingPress = false, hovered = false
    // Custom row/section subclasses draw their own layers. Keep default-button
    // decoration lazy so constructing a long panel does not allocate hundreds
    // of unused gradient, shadow, text, and focus layers for those controls.
    private var layersAttached = false
    private var circleLayersAttached = false
    private lazy var wellShadow = CALayer()
    private lazy var gradient = CAGradientLayer()
    private lazy var gradientMask = CAShapeLayer()
    private lazy var ring = CAShapeLayer()
    private lazy var highlight = CAShapeLayer()
    private lazy var glyph = CALayer()
    private lazy var text = CALayer()
    private lazy var focus = CAShapeLayer()
    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public init(id: String,label: String,symbol: String,pointSize: CGFloat,weight: NSFont.Weight = .regular) {
        controlID = id; self.symbol = symbol; self.pointSize = pointSize; self.weight = weight
        super.init(frame: .zero); super.title = ""; symbolPhase = SiteControlMetrics.symbolRasterPhase[symbol] ?? .zero; title = ""; isBordered = false; focusRingType = .none
        setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label); identifier = .init(id)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
    public override var intrinsicContentSize: NSSize {
        let m = SiteControlMetrics.self
        return CGSize(width: m.pillPadding*2+(symbolInk?.width ?? m.pillLockGlyph)+m.pillLockGap+(title as NSString).size(withAttributes: [.font: Typography.siteControlPill.font]).width,height: m.footerHeight)
    }
    public override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds,options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner: self)) }
    public override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true
        if let tooltipTitle { TooltipController.shared.schedule(Tooltip(title: tooltipTitle,keys: tooltipKeys,style: .defaultTheme(system: contentAppearance)),for: self) }
    }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; TooltipController.shared.cancel(for: self) }
    public override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; TooltipController.shared.cancel(for: self); activationPoint = convert(event.locationInWindow,from: nil); showsKeyboardFocus = false; trackingPress = true; isHighlighted = true; needsDisplay = true }
    public override func mouseUp(with event: NSEvent) { let activate = trackingPress && bounds.contains(convert(event.locationInWindow,from: nil)); trackingPress = false; isHighlighted = false; needsDisplay = true; if activate && isEnabled { sendAction(action,to: target) } }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func keyDown(with event: NSEvent) { activationPoint = nil; if onKey?(event) == true { return }; if !event.modifierFlags.contains(.command) && [36,49].contains(event.keyCode) { showsKeyboardFocus = true; performClick(nil) } else { super.keyDown(with: event) } }
    public override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        if style == .circle {
            updateCircleLayers()
            return
        }
        if !layersAttached {
            for item in [wellShadow,gradient,ring,highlight,glyph,text,focus] { layer?.addSublayer(item) }
            gradient.mask = gradientMask; layersAttached = true
        }
        for item in [wellShadow,gradient,ring,highlight,text] { item.isHidden = false }
        let m = SiteControlMetrics.self, appearance = contentAppearance, scale = window?.backingScaleFactor ?? 1
        let radius = style == .more || style == .circle ? bounds.height/2 : style == .pill ? m.pillRadius : m.actionRadius
        let path = SiteControlShape.path(in: bounds,radius: radius)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gradient.frame = bounds; gradientMask.frame = bounds; gradientMask.path = style == .more ? CGPath(ellipseIn: bounds,transform: nil) : path
        ring.frame = bounds; ring.fillColor = nil; ring.lineWidth = m.actionRingWidth; ring.path = SiteControlShape.path(in: bounds.insetBy(dx: -m.actionRingWidth/2,dy: -m.actionRingWidth/2),radius: radius)
        wellShadow.frame = bounds; wellShadow.shadowPath = path; wellShadow.shadowColor = NSColor.black.cgColor; wellShadow.shadowOffset = CGSize(width: 0,height: m.actionShadowOffsetY); wellShadow.shadowRadius = m.actionShadowRadius
        wellShadow.shadowOpacity = style == .action ? Float(SiteControlColors.actionShadow.resolved(appearance).alpha) : 0
        var top = NSColor.clear, bottom = NSColor.clear
        if style == .action { top = SiteControlColors.actionFillTop.resolved(appearance).nsColor; bottom = SiteControlColors.actionFillBottom.resolved(appearance).nsColor }
        if style == .pill { top = SiteControlColors.pillFill.resolved(appearance).nsColor; bottom = top }
        if style == .more { top = SiteControlColors.moreFill.resolved(appearance).nsColor; bottom = top }
        if style == .extensionTile { top = SiteControlColors.tileFill.resolved(appearance).nsColor; bottom = top }
        if isHighlighted && style == .action { top = SiteControlGlyphRenderer.adjust(top,levels: m.actionPressedLevels); bottom = SiteControlGlyphRenderer.adjust(bottom,levels: m.actionPressedLevels) }
        gradient.colors = [top.cgColor,bottom.cgColor]; gradient.startPoint = CGPoint(x: 0.5,y: 0); gradient.endPoint = CGPoint(x: 0.5,y: 1)
        ring.strokeColor = style == .action ? SiteControlColors.actionRing.cgColor(appearance) : nil
        let line = CGMutablePath(); line.move(to: CGPoint(x: radius,y: m.actionHighlightHeight/2)); line.addLine(to: CGPoint(x: bounds.width-radius,y: m.actionHighlightHeight/2))
        highlight.path = line; highlight.lineWidth = m.actionHighlightHeight
        let highlightColor = style == .action ? (hovered && isEnabled ? SiteControlColors.actionHighlightHover : SiteControlColors.actionHighlight).cgColor(appearance) : nil
        if let previous = highlight.strokeColor,let next = highlightColor,previous != next {
            let fade = CABasicAnimation(keyPath: "strokeColor"); fade.fromValue = highlight.presentation()?.strokeColor ?? previous; fade.toValue = next; fade.duration = Motion.hoverFade
            highlight.add(fade,forKey: "hover")
        }
        highlight.strokeColor = highlightColor
        let resolved = tint.resolved(appearance).nsColor, alpha = isEnabled || statusOnly ? 1 : disabledOpacity
        let color = resolved.withAlphaComponent(resolved.alphaComponent*alpha)
        if let image = SiteControlGlyphRenderer.symbol(symbol,size: pointSize,weight: weight,color: color,sparkles: sparkles,scale: scale,fit: symbolInk,phase: symbolPhase) {
            let x = title.isEmpty ? ((bounds.width-image.ink.width)/2*scale).rounded()/scale-image.ink.minX : m.pillPadding-image.ink.minX
            let y = ((bounds.height-image.ink.height)/2*scale).rounded()/scale-image.ink.minY
            glyph.frame = CGRect(x: x,y: y,width: image.size.width,height: image.size.height); glyph.contents = image.image
        }
        glyph.contentsScale = scale
        text.isHidden = title.isEmpty
        if !title.isEmpty { let rect = CGRect(x: m.pillPadding+(symbolInk?.width ?? m.pillLockGlyph)+m.pillLockGap,y: 0,width: max(1,bounds.width-m.pillPadding*2-(symbolInk?.width ?? m.pillLockGlyph)-m.pillLockGap),height: bounds.height); text.frame = rect; text.contents = SiteControlGlyphRenderer.caption(title,size: rect.size,font: Typography.siteControlPill.font,color: color,scale: scale); text.contentsScale = scale }
        let focusRect = bounds.insetBy(dx: -m.focusOutset,dy: -m.focusOutset)
        focus.frame = bounds; focus.path = style == .circle || style == .more ? CGPath(ellipseIn: focusRect,transform: nil) : SiteControlShape.path(in: focusRect,radius: radius+m.focusOutset)
        focus.fillColor = nil; focus.lineWidth = m.focusWidth; focus.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(appearance) : nil
    }
    private func updateCircleLayers() {
        // A Boost toggle needs two layers, not an unused action-button well,
        // gradient, mask, rim, highlight, shadow and caption for every row.
        if !circleLayersAttached {
            layer?.addSublayer(glyph); layer?.addSublayer(focus); circleLayersAttached = true
        }
        let m = SiteControlMetrics.self, appearance = contentAppearance, scale = window?.backingScaleFactor ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        if layersAttached { for item in [wellShadow,gradient,ring,highlight,text] { item.isHidden = true } }
        var disc = (circleOn ? SiteControlColors.circleOn : SiteControlColors.circleOff).resolved(appearance).nsColor
        if isHighlighted { disc = SiteControlGlyphRenderer.adjust(disc,levels: m.circlePressedLevels) }
        let previous = glyph.contents
        glyph.frame = bounds; glyph.contentsScale = scale
        glyph.contents = SiteControlGlyphRenderer.circle(symbol: symbol,size: bounds.size,pointSize: pointSize,disc: disc,sparkles: sparkles,scale: scale,phase: symbolPhase)
        if animateCircleChange,let previous {
            let fade = CABasicAnimation(keyPath: "contents"); fade.fromValue = previous; fade.toValue = glyph.contents; fade.duration = Motion.selectionFade; glyph.add(fade,forKey: "toggle")
        }
        animateCircleChange = false
        focus.frame = bounds; focus.path = CGPath(ellipseIn: bounds.insetBy(dx: -m.focusOutset,dy: -m.focusOutset),transform: nil)
        focus.fillColor = nil; focus.lineWidth = m.focusWidth
        focus.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(appearance) : nil
    }
}

@MainActor
enum SiteControlGlyphRenderer {
    struct Image { let image: CGImage; let size: CGSize; let ink: CGRect }
    private static var circles: [String: CGImage] = [:]
    private static var captions: [String: CGImage] = [:]
    private static var symbols: [String: Image] = [:]
    static func adjust(_ color: NSColor,levels: CGFloat) -> NSColor { let c = color.usingColorSpace(.sRGB)!; return NSColor(srgbRed: min(1,max(0,c.redComponent+levels/255)),green: min(1,max(0,c.greenComponent+levels/255)),blue: min(1,max(0,c.blueComponent+levels/255)),alpha: c.alphaComponent) }
    static func canvas(_ size: CGSize,scale: CGFloat,_ draw: (CGContext) -> Void) -> CGImage? {
        guard size.width > 0,size.height > 0,let c = CGContext(data: nil,width: Int(ceil(size.width*scale)),height: Int(ceil(size.height*scale)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: scale,y: scale); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: false); draw(c); NSGraphicsContext.restoreGraphicsState(); return c.makeImage()
    }
    static func sparkle(_ c: CGContext,at p: CGPoint,size: CGFloat,alpha: CGFloat) { let path = CGMutablePath(); path.move(to: CGPoint(x: p.x,y: p.y-size/2)); path.addQuadCurve(to: CGPoint(x: p.x+size/2,y: p.y),control: p); path.addQuadCurve(to: CGPoint(x: p.x,y: p.y+size/2),control: p); path.addQuadCurve(to: CGPoint(x: p.x-size/2,y: p.y),control: p); path.addQuadCurve(to: CGPoint(x: p.x,y: p.y-size/2),control: p); c.setAlpha(alpha); c.addPath(path); c.fillPath(); c.setAlpha(1) }
    static func symbol(_ name: String,size: CGFloat,weight: NSFont.Weight,color: NSColor,sparkles: SiteControlSparkles,scale: CGFloat,fit: CGSize? = nil,phase: CGPoint = .zero,symbolScale: NSImage.SymbolScale? = nil) -> Image? {
        let baseKey = "\(name)|\(size)|\(weight.rawValue)|\(color)|\(sparkles)|\(scale)|\(String(describing: fit))|\(phase)"
        let key = symbolScale.map { baseKey+"|\($0.rawValue)" } ?? baseKey
        if let cached = symbols[key] { return cached }
        let configuration = symbolScale.map { NSImage.SymbolConfiguration(pointSize: size,weight: weight,scale: $0) } ?? .init(pointSize: size,weight: weight)
        guard let source = NSImage(systemSymbolName: name,accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let nativeSize = CGSize(width: ceil(source.size.width),height: ceil(source.size.height))
        func draw(_ c: CGContext) {
            source.draw(in: CGRect(origin: .zero,size: source.size),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: false,hints: nil)
            c.setBlendMode(.sourceIn); c.setFillColor(color.cgColor); c.fill(CGRect(origin: .zero,size: nativeSize)); c.setBlendMode(.normal)
            if sparkles != .none { c.setFillColor(color.cgColor); sparkle(c,at: CGPoint(x: 3,y: nativeSize.height-4),size: 4,alpha: 1) }
        }
        var extent = nativeSize, ink = CGRect(origin: .zero,size: nativeSize)
        if let fit,let probe = canvas(nativeSize,scale: 4,draw),let data = probe.dataProvider?.data,let bytes = CFDataGetBytePtr(data) {
            var minX = probe.width,minY = probe.height,maxX = 0,maxY = 0
            let peak = stride(from: 3,to: CFDataGetLength(data),by: 4).map { bytes[$0] }.max() ?? 255
            for y in 0..<probe.height { for x in 0..<probe.width where Int(bytes[y*probe.bytesPerRow+x*4+3])*2 >= Int(peak) {
                minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x+1); maxY = max(maxY,y+1)
            } }
            if maxX>minX && maxY>minY { ink = CGRect(x: CGFloat(minX)/4,y: nativeSize.height-CGFloat(maxY)/4,width: CGFloat(maxX-minX)/4,height: CGFloat(maxY-minY)/4); extent = CGSize(width: fit.width+4,height: fit.height+4) }
        }
        let compensation = fit == nil ? CGSize.zero : SiteControlMetrics.symbolRasterCompensation[name] ?? .zero
        if fit != nil { extent.width += compensation.width; extent.height += compensation.height }
        guard let image = canvas(extent,scale: scale,{ c in
            if let fit { c.translateBy(x: 2+phase.x,y: 2+phase.y); c.scaleBy(x: (fit.width+compensation.width)/ink.width,y: (fit.height+compensation.height)/ink.height); c.translateBy(x: -ink.minX,y: -ink.minY) }
            draw(c)
        }) else { return nil }
        if symbols.count > 256 { symbols.removeAll(keepingCapacity: true) }; let value = Image(image: image,size: extent,ink: alphaBounds(image,scale: scale)); symbols[key] = value; return value
    }
    private static func alphaBounds(_ image: CGImage,scale: CGFloat) -> CGRect {
        guard let data = image.dataProvider?.data,let bytes = CFDataGetBytePtr(data) else { return .zero }
        var minX = image.width,minY = image.height,maxX = 0,maxY = 0,peak: UInt8 = 0
        for y in 0..<image.height { for x in 0..<image.width { peak = max(peak,bytes[y*image.bytesPerRow+x*4+3]) } }
        for y in 0..<image.height { for x in 0..<image.width where Int(bytes[y*image.bytesPerRow+x*4+3])*2>=Int(peak) {
            minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x+1); maxY = max(maxY,y+1)
        } }
        return maxX>minX && maxY>minY ? CGRect(x: CGFloat(minX)/scale,y: CGFloat(minY)/scale,width: CGFloat(maxX-minX)/scale,height: CGFloat(maxY-minY)/scale) : .zero
    }
    static func circle(symbol name: String,size: CGSize,pointSize: CGFloat,disc: NSColor,sparkles: SiteControlSparkles,scale: CGFloat,phase: CGPoint = .zero) -> CGImage? {
        let key = "\(name)|\(size)|\(pointSize)|\(disc)|\(sparkles)|\(scale)|\(phase)"
        if let image = circles[key] { return image }
        let image = canvas(size,scale: scale) { c in
            c.setFillColor(disc.cgColor); c.fillEllipse(in: CGRect(origin: .zero,size: size))
            c.setBlendMode(.destinationOut)
            let fit: CGSize? = name == "gearshape.fill" ? SiteControlMetrics.gearInk : nil
            if let icon = symbol(name,size: pointSize,weight: .regular,color: .white,sparkles: .none,scale: scale,fit: fit,phase: phase) {
                let rect = CGRect(x: ((size.width-icon.ink.width)/2*scale).rounded()/scale-icon.ink.minX+(name == "gearshape.fill" ? -1/scale : 0),y: ((size.height-icon.ink.height)/2*scale).rounded()/scale-icon.ink.minY,width: icon.size.width,height: icon.size.height)
                c.draw(icon.image,in: rect)
            }
            if sparkles == .boost { c.setFillColor(NSColor.white.cgColor); sparkle(c,at: CGPoint(x: 9,y: 23),size: 4,alpha: SiteControlMetrics.sparkleOpacity.topLeft); sparkle(c,at: CGPoint(x: 24,y: 24),size: 4,alpha: SiteControlMetrics.sparkleOpacity.topRight); sparkle(c,at: CGPoint(x: 24,y: 8),size: 4,alpha: SiteControlMetrics.sparkleOpacity.bottomRight) }
        }
        if circles.count > 256 { circles.removeAll(keepingCapacity: true) }; circles[key] = image; return image
    }
    static func caption(_ text: String,size: CGSize,font: NSFont,color: NSColor,scale: CGFloat) -> CGImage? {
        let key = "\(text)|\(size)|\(font)|\(color)|\(scale)"
        if let image = captions[key] { return image }
        let image = canvas(size,scale: scale) { c in let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [.font: font,.foregroundColor: color])); c.textPosition = CGPoint(x: 0,y: (size.height-font.ascender-font.descender)/2); CTLineDraw(line,c) }
        if captions.count > 128 { captions.removeAll(keepingCapacity: true) }; captions[key] = image; return image
    }
}
