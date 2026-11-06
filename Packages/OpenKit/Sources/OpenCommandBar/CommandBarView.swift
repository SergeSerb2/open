import AppKit
import OpenDesign

public enum CommandBarPresentation: Sendable, Equatable {
    case overlay
    case embedded(width: CGFloat)
    var isEmbedded: Bool { if case .embedded = self { true } else { false } }
}

/// The overlay. The App adds it above the web content and the sidebar, filling the
/// window's content view. It is transparent: Arc does not dim the page (interaction-states
/// §9.1); only the panel's wide shadow darkens it. A click outside the panel closes the bar.
@MainActor
public final class CommandBarView: NSView {
    public internal(set) var presentation: CommandBarPresentation = .overlay {
        didSet {
            container.drawsShadow = !presentation.isEmbedded
            panel.input.embedded = presentation.isEmbedded
            needsLayout = true
        }
    }
    /// Little Open's page overlay keeps 20 pt margins (§9.3); all other callers use the existing layout.
    public var overlayPanelWidth: CGFloat? { didSet { needsLayout = true } }
    let container = PanelContainerView(frame: .zero)
    var panel: PanelView { container.panel }
    /// Called for a mouse-down outside the panel.
    var onClickOutside: (() -> Void)?
    var onMoveToWindow: (() -> Void)?
    /// False while hidden: the overlay then passes every event through.
    var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    /// Visible rows; sets the panel height.
    var visibleRowCount = 0 { didSet { if visibleRowCount != oldValue { needsLayout = true } } }
    /// The (i) privacy footer (CC-42). It can make a short panel taller.
    var showsFooter = false {
        didSet {
            guard showsFooter != oldValue else { return }
            panel.showsFooter = showsFooter
            needsLayout = true
        }
    }

    public var panelFrame: CGRect {
        if case .embedded(let width) = presentation { return CGRect(x: 0, y: 0, width: width, height: bounds.height) }
        var frame = CommandBarMetrics.panelFrame(windowSize: bounds.size, rows: visibleRowCount, footer: showsFooter)
        if let width = overlayPanelWidth { frame.size.width = width; frame.origin.x = (bounds.width - width) / 2 }
        return frame
    }

    /// Shows or hides the whole overlay in one frame: Arc's bar appears and goes between two
    /// video frames, with no scale or fade (CC-44, D12). No implicit layer animation runs.
    func setShown(_ shown: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = !shown
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let f = panelFrame
        guard container.frame != f else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = f
        CATransaction.commit()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        if container.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) { onClickOutside?() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Diagnostics (renders and checks)

    /// The trailing item: "info", "hint <Site>", "hint+space <Site>", or "none".
    public var debugTrailing: String {
        switch panel.input.embedded ? CommandBarTrailing.none : panel.input.input.trailing {
        case .info: "info"
        case .siteSearchHint(let name, let space): "\(space ? "hint+space" : "hint") \(name)"
        case .none: "none"
        }
    }
    /// The input row as drawn.
    public var debugCloseFrame: CGRect { panel.input.closeButton.frame }
    public var debugHasCloseButton: Bool { !panel.input.closeButton.isHiddenOrHasHiddenAncestor }
    public var inputField: NSTextField { panel.input.field }
    public var debugInput: CommandBarInput { panel.input.input }
    /// Row draw passes since creation.
    public var debugRowDrawCount: Int { panel.results.rowDrawCount }
    /// True when the input is being edited by the bar's own field editor.
    public var debugUsesOwnFieldEditor: Bool { window?.firstResponder === panel.input.editor }
    /// True while the (i) privacy footer shows.
    public var debugShowsFooter: Bool { showsFooter && !panel.footer.isHidden }
    /// Visible part of the result list (its frame minus what the footer covers), in list points.
    public var debugVisibleListHeight: CGFloat { panel.results.visibleHeight }
    public var debugListScrollOffset: CGFloat { panel.results.scrollOffset }
    /// Panel layout passes since creation.
    public var debugPanelLayoutCount: Int { panel.layoutCount }
    /// Text field frame in panel points.
    public var debugFieldFrame: CGRect { panel.input.field.frame }
    /// The scope chip's capsule in input-row points (zero without a chip), and whether it is hovered.
    public var debugChipFrame: CGRect { panel.input.input.chip == nil ? .zero : panel.input.chipRect }
    public var debugChipHovered: Bool { panel.input.chipHovered }
    /// Presses a bar control through its accessibility action, the same path as VoiceOver and
    /// a click: "info", "searchSettings", "dismiss", or "privacyLink". False when it is not shown.
    public func debugPress(_ control: String) -> Bool {
        let target: NSView?
        switch control {
        case "info": target = panel.input.infoButton
        case "close": target = panel.input.closeButton
        case "searchSettings": target = panel.footer.settingsButton
        case "dismiss": target = panel.footer.dismissButton
        case "privacyLink": target = panel.footer.link
        default: target = nil
        }
        guard let target, !target.isHiddenOrHasHiddenAncestor else { return false }
        return target.accessibilityPerformPress()
    }
    /// The panel's on-screen opacity (its presentation layer): 1 at once after `present` (CC-44).
    public var debugPanelPresentationOpacity: Float {
        guard let layer = container.layer else { return 0 }
        return isHidden ? 0 : (layer.presentation() ?? layer).opacity
    }
    /// Animation keys on the overlay's layers as "key@owner" (none: the bar never animates, CC-44).
    /// The text caret (`NSTextInsertionIndicator`) blinks by itself in a key window, as in Arc, so its
    /// layers are left out.
    public var debugAnimationKeys: [String] {
        func keys(_ layer: CALayer) -> [String] {
            let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            guard !owner.contains("InsertionIndicator") else { return [] }
            return (layer.animationKeys() ?? []).map { "\($0)@\(owner)" } + (layer.sublayers ?? []).flatMap(keys)
        }
        return layer.map(keys) ?? []
    }
    /// Every animation key, the caret included (diagnostics).
    public var debugAllAnimationKeys: [String] {
        func keys(_ layer: CALayer) -> [String] {
            let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            return (layer.animationKeys() ?? []).map { "\($0)@\(owner)" } + (layer.sublayers ?? []).flatMap(keys)
        }
        return layer.map(keys) ?? []
    }
}

/// Holds the shadow and the panel. Nothing in it animates: present and dismiss change the
/// panel in one frame (CC-44, D12).
@MainActor
final class PanelContainerView: NSView {
    let panel = PanelView(frame: .zero)
    var drawsShadow = true { didSet { shadowLayer.isHidden = !drawsShadow } }
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.shadowOpacity = CommandBarShadow.opacity
        shadowLayer.shadowRadius = CommandBarShadow.radius
        shadowLayer.actions = ["position": NSNull(), "bounds": NSNull(), "shadowPath": NSNull()]
        shadowMask.fillRule = .evenOdd
        shadowMask.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        shadowLayer.mask = shadowMask
        layer?.addSublayer(shadowLayer)
        addSubview(panel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = bounds
        // The shadow never darkens what shows through the translucent panel: the mask cuts the panel out
        // (Arc's fill over a white page is uniform up to the edge, A0120).
        let r = CommandBarMetrics.cornerRadius
        let path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        // Downward in the flipped view (checked: the comparison measures the bottom and top shadow, ΔE ≤ 0.5).
        shadowLayer.shadowOffset = CGSize(width: 0, height: (shadowLayer.isGeometryFlipped || layer?.isGeometryFlipped == true) ? -CommandBarShadow.offsetY : CommandBarShadow.offsetY)
        let margin = CommandBarShadow.radius * 4 + CommandBarShadow.offsetY
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds.insetBy(dx: -margin, dy: -margin))
        maskPath.addPath(path)
        shadowMask.frame = bounds
        shadowMask.path = maskPath
        CATransaction.commit()
    }
}
