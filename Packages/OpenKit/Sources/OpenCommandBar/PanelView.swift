import AppKit
import CoreImage
import OpenDesign

/// The panel: material, input row, separator, result list, and the edge on top.
/// Clipped to a 12 pt continuous corner.
@MainActor
final class PanelView: NSView {
    let material = MaterialView(frame: .zero)
    let input = InputRowView(frame: .zero)
    let results = ResultsView(frame: .zero)
    /// The (i) privacy footer (CC-42): over the list's bottom, under the edge.
    let footer = PrivacyFooterView(frame: .zero)
    private let separator = CALayer()
    private let edge = EdgeView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = CommandBarMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(material)
        addSubview(input)
        addSubview(results)
        footer.isHidden = true
        addSubview(footer)
        addSubview(edge)
        separator.backgroundColor = CommandBarRole.separator.cgColor
        separator.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        material.layer?.addSublayer(separator)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var backdropIsDark = true { didSet { if backdropIsDark != oldValue { edge.overDark = backdropIsDark } } }
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
        let m = CommandBarMetrics.self
        material.frame = bounds
        edge.frame = bounds
        input.frame = CGRect(x: 0, y: 0, width: bounds.width, height: m.inputRowHeight)
        // The list keeps its frame under the footer; only its visible part ends at the band (S2 18/0044:
        // the AX table frame is the same with and without the footer, and 5 rows show 4).
        let footerTop = bounds.height - m.footerHeight
        let listHeight = max(0, bounds.height - m.listTop - m.bottomPadding - (showsFooter ? grownHeight : 0))
        results.frame = CGRect(x: 0, y: m.listTop, width: bounds.width, height: listHeight)
        results.occludedBottom = showsFooter ? max(0, results.frame.maxY - footerTop) : 0
        footer.frame = CGRect(x: 0, y: footerTop, width: bounds.width, height: m.footerHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.isHidden = !showsSeparator
        separator.frame = CGRect(x: 1, y: m.inputRowHeight, width: bounds.width - 2, height: m.separatorHeight)
        CATransaction.commit()
    }

    /// The height a short panel gained for the footer (`CommandBarMetrics.panelHeight`).
    private var grownHeight: CGFloat {
        let m = CommandBarMetrics.self
        let rows = results.rows.count
        return rows < m.footerGrowthRowLimit ? m.footerHeight : 0
    }
}

/// The panel material: a dark tint at 88.5 % over a blurred, saturated copy of the
/// backdrop (docs/commandbar.md §3). With a uniform backdrop color the result is one
/// flat color, computed once. With a snapshot, Core Image blurs and saturates the area
/// under the panel once per presentation; nothing runs per frame.
@MainActor
final class MaterialView: NSView {
    private let backdropLayer = CALayer()
    private let tintLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [backdropLayer, tintLayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
        }
        tintLayer.backgroundColor = CommandBarMaterial.tint.withAlpha(CommandBarMaterial.tintAlpha).cgColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Size of the processed backdrop: the tallest panel, so rows arriving later never stretch it.
    private var backdropSize: CGSize?

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = CGRect(origin: .zero, size: backdropSize ?? bounds.size)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    /// Embedded Little Open has its own window shadow and a fixed solid fill.
    func applySolid(_ color: RGBA) {
        backdropLayer.contents = nil; backdropLayer.backgroundColor = nil; backdropSize = nil
        tintLayer.backgroundColor = color.cgColor
    }

    /// Uniform backdrop: a single precomputed fill.
    func apply(color: RGBA) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.contents = nil
        backdropLayer.backgroundColor = nil
        backdropSize = nil
        tintLayer.backgroundColor = CommandBarMaterial.fill(over: color).cgColor
        CATransaction.commit()
    }

    /// Snapshot backdrop: `image` covers the window; `rect` is the tallest panel in window points.
    func apply(image: CGImage, imageScale: CGFloat, panelRect rect: CGRect, fallback: RGBA) {
        guard let processed = Self.process(image, scale: imageScale, rect: rect) else { apply(color: fallback); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropSize = rect.size
        backdropLayer.frame = CGRect(origin: .zero, size: rect.size)
        backdropLayer.backgroundColor = nil
        backdropLayer.contents = processed
        backdropLayer.contentsGravity = .resize
        tintLayer.backgroundColor = CommandBarMaterial.tint.withAlpha(CommandBarMaterial.tintAlpha).cgColor
        CATransaction.commit()
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Crop (with a margin for the blur), blur, saturate around Rec. 709 luma, crop to the panel.
    static func process(_ image: CGImage, scale: CGFloat, rect: CGRect) -> CGImage? {
        let r = CommandBarMaterial.blurRadius
        // Core Image's origin is bottom-left.
        let h = CGFloat(image.height)
        let px = CGRect(x: rect.minX * scale, y: h - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        var ci = CIImage(cgImage: image).clampedToExtent()
        ci = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r * scale])
        // Saturation s around luma: c' = Y + s (c − Y), as a color matrix.
        let s = CGFloat(CommandBarMaterial.saturation)
        let lr: CGFloat = 0.2126, lg: CGFloat = 0.7152, lb: CGFloat = 0.0722
        func row(_ i: Int) -> CIVector {
            let base = [(1 - s) * lr, (1 - s) * lg, (1 - s) * lb]
            var v = base
            v[i] += s
            return CIVector(x: v[0], y: v[1], z: v[2], w: 0)
        }
        ci = ci.applyingFilter("CIColorMatrix", parameters: ["inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2)])
        ci = ci.cropped(to: px)
        return context.createCGImage(ci, from: px)
    }
}

/// The panel edge. Over a dark backdrop: 1 pt black (0.93) and a 1 pt light inner ring
/// (white 0.21). Otherwise one gray line (docs/commandbar.md §3, `CommandBarMaterial`).
@MainActor
final class EdgeView: NSView {
    private let outer = CALayer()
    private let inner = CALayer()
    var overDark = true { didSet { if overDark != oldValue { apply() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [outer, inner] {
            l.borderWidth = 1
            l.cornerCurve = .continuous
            l.actions = ["position": NSNull(), "bounds": NSNull(), "borderColor": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.borderColor = (overDark ? CommandBarRole.outerEdgeOverDark : CommandBarRole.edgeOverLight).cgColor
        inner.borderColor = CommandBarRole.innerEdgeOverDark.cgColor
        inner.isHidden = !overDark
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = CommandBarMetrics.cornerRadius
        outer.frame = bounds
        outer.cornerRadius = r
        inner.frame = bounds.insetBy(dx: 1, dy: 1)
        inner.cornerRadius = r - 1
        CATransaction.commit()
    }
}
