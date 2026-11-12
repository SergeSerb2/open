import AppKit
import CoreImage
import OpenDesign

/// The panel: body with the Space tint, input row, separator, result list, and the hairline on top.
/// Clipped to a 12 pt continuous corner (plan D3 §2.1).
@MainActor
final class PanelView: NSView {
    let material = MaterialView(frame: .zero)
    let input = InputRowView(frame: .zero)
    let results = ResultsView(frame: .zero)
    /// The (i) privacy footer (CC-42): over the list's bottom, under the edge.
    let footer = PrivacyFooterView(frame: .zero)
    private let separator = CALayer()
    private let edge = EdgeView(frame: .zero)
    /// New Tab card or inline editor geometry.
    var layoutSpec = CommandCardLayout.newTab {
        didSet {
            guard layoutSpec != oldValue else { return }
            input.layoutSpec = layoutSpec; results.layoutSpec = layoutSpec; needsLayout = true
        }
    }
    var theme = CommandBarTheme.default {
        didSet {
            guard theme != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            separator.backgroundColor = theme.separator.cgColor
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = CommandCard.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(material)
        addSubview(input)
        addSubview(results)
        footer.isHidden = true
        addSubview(footer)
        addSubview(edge)
        separator.backgroundColor = theme.separator.cgColor
        separator.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        material.layer?.addSublayer(separator)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var showsFooter = false {
        didSet {
            guard showsFooter != oldValue else { return }
            footer.isHidden = !showsFooter
            input.showsFooter = showsFooter
            needsLayout = true
        }
    }
    /// The separator shows only above rows.
    var showsSeparator = false {
        didSet {
            guard showsSeparator != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            separator.isHidden = !showsSeparator
            CATransaction.commit()
        }
    }

    /// Layout passes since creation (the keystroke bench: at most one per keystroke).
    private(set) var layoutCount = 0

    override func layout() {
        super.layout()
        layoutCount += 1
        let m = CommandBarMetrics.self, l = layoutSpec
        material.frame = bounds
        edge.frame = bounds
        input.frame = CGRect(x: 0, y: 0, width: bounds.width, height: l.inputRowHeight)
        // The list keeps its frame under the footer; only its visible part ends at the band (S2 18/0044:
        // the AX table frame is the same with and without the footer, and 5 rows show 4).
        let footerTop = bounds.height - m.footerHeight
        let listHeight = max(0, bounds.height - l.listTop - l.listPaddingBottom - (showsFooter ? grownHeight : 0))
        results.frame = CGRect(x: 0, y: l.listTop, width: bounds.width, height: listHeight)
        results.occludedBottom = showsFooter ? max(0, results.frame.maxY - footerTop) : 0
        footer.frame = CGRect(x: 0, y: footerTop, width: bounds.width, height: m.footerHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.isHidden = !showsSeparator
        separator.frame = CGRect(x: 0, y: l.inputRowHeight - m.separatorHeight, width: bounds.width, height: m.separatorHeight)
        CATransaction.commit()
    }

    /// The height a short panel gained for the footer (`CommandBarMetrics.panelHeight`).
    private var grownHeight: CGFloat {
        let m = CommandBarMetrics.self
        let rows = results.rows.count
        return rows < m.footerGrowthRowLimit ? m.footerHeight : 0
    }
}

/// The card body: an opaque fill (Light `#F9F9F9`, Dark `#30302E`) and a horizontal Space tint from
/// the left edge to 30 % of the width (plan D3 §2.1). Static layers: nothing runs per frame.
@MainActor
final class MaterialView: NSView {
    private let bodyLayer = CALayer()
    private let tintLayer = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [bodyLayer, tintLayer] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        tintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        tintLayer.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.frame = bounds
        tintLayer.frame = bounds
        CATransaction.commit()
        applyTint()
    }

    /// Embedded Little Open has its own window shadow and a fixed solid fill.
    func applySolid(_ color: RGBA) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.backgroundColor = color.cgColor
        tintLayer.isHidden = true
        CATransaction.commit()
    }

    /// Where the tint lies, in card points: `.overSidebar(edge)` (the sidebar's right edge in card x, New Tab card),
    /// `.uniform` (inline editor), or `.none` (no sidebar behind the card).
    enum TintExtent: Equatable { case none, uniform, overSidebar(CGFloat) }
    var tintExtent = TintExtent.none { didSet { if tintExtent != oldValue { applyTint() } } }
    private var theme: CommandBarTheme?

    /// The card: body plus the Space tint.
    func apply(_ theme: CommandBarTheme) {
        self.theme = theme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.backgroundColor = theme.body.cgColor
        CATransaction.commit()
        applyTint()
    }

    private func applyTint() {
        guard let theme else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tint = theme.tint, w = max(1, bounds.width)
        switch tintExtent {
        case .none:
            tintLayer.isHidden = true
        case .uniform:
            let c = tint.withAlpha(tint.alpha * CommandCard.inlineTintShare).cgColor
            tintLayer.colors = [c, c]; tintLayer.locations = [0, 1]; tintLayer.isHidden = false
        case .overSidebar(let edge):
            // Full tint up to the sidebar edge, then a premultiplied fade (the tint's own color at alpha 0) over 60 pt.
            let fadeEnd = edge + CommandCard.tintFade
            guard fadeEnd > 0 else { tintLayer.isHidden = true; return }
            let start = edge > 0 ? tint : tint.withAlpha(tint.alpha * Double(fadeEnd / CommandCard.tintFade))
            let solid = max(0, min(edge, w)) / w, end = min(fadeEnd, w) / w
            tintLayer.colors = [start.cgColor, start.cgColor, tint.withAlpha(0).cgColor, tint.withAlpha(0).cgColor]
            tintLayer.locations = [0, NSNumber(value: Double(solid)), NSNumber(value: Double(max(solid, end))), 1]
            tintLayer.isHidden = false
        }
    }
}

/// The card's 0.5 pt black 22 % hairline (plan D3 §2.1), drawn on top of the clipped content.
@MainActor
final class EdgeView: NSView {
    private let outer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outer.borderWidth = CommandCard.hairlineWidth
        outer.borderColor = CommandCard.hairline.cgColor
        outer.cornerCurve = .continuous
        outer.actions = ["position": NSNull(), "bounds": NSNull(), "borderColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(outer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.frame = bounds
        outer.cornerRadius = CommandCard.cornerRadius
        CATransaction.commit()
    }
}
