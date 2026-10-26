import AppKit
import OpenDesign

@MainActor
final class ActionButton: NSButton {
    var perform: (() -> Void)?
    var circleFill: NSColor? { didSet { needsDisplay = true } }
    var glyphPointSize: CGFloat = 16
    var glyphOffset = CGSize.zero
    init(symbol: String, title: String, action: @escaping () -> Void) {
        super.init(frame: .zero); isBordered = false; image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imageScaling = .scaleProportionallyDown; self.title = ""; toolTip = title
        setAccessibilityLabel(title); target = self; self.action = #selector(invoke); perform = action
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let circleFill {
            circleFill.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: (bounds.width - bounds.height) / 2, dy: 0)).fill()
        }
        guard let source = image, let context = NSGraphicsContext.current?.cgContext else { return }
        let symbol = source.withSymbolConfiguration(.init(pointSize: glyphPointSize, weight: .regular)) ?? source
        let size = symbol.size
        let rect = backingAlignedRect(CGRect(x: (bounds.width - size.width) / 2 + glyphOffset.width,
                                             y: (bounds.height - size.height) / 2 + glyphOffset.height,
                                             width: size.width, height: size.height), options: .alignAllEdgesNearest)
        let tint = (contentTintColor ?? .black).withAlphaComponent(isEnabled ? (contentTintColor?.alphaComponent ?? 1) : 0.24)
        context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(tint.cgColor); context.fill(rect)
        context.endTransparencyLayer(); context.restoreGState()
    }
}

@MainActor
public final class PaneChromeView: NSView {
    weak var host: (any WebContentHost)?
    var onClose: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onURL: (() -> Void)?
    var onCopy: (() -> Void)?
    let label = NSTextField(labelWithString: "")
    private var buttons: [ActionButton] = []
    public var isFocused = false { didSet { update() } }
    public init() {
        super.init(frame: .zero); wantsLayer = true
        let specs = [("arrow.left", "Go back"), ("arrow.right", "Go forward"), ("arrow.clockwise", "Reload"),
                     ("link", "Copy Current URL"), ("slider.horizontal.3", "Site Control Center"),
                     ("square.split.2x1", "Split View Menu"), ("xmark", "Close This Pane")]
        for (i, spec) in specs.enumerated() {
            let button = ActionButton(symbol: spec.0, title: spec.1) { [weak self] in self?.press(i) }
            button.contentTintColor = NSColor.black.withAlphaComponent(0.55)
            if i == 0 || i == 1 { button.glyphPointSize = 14; button.glyphOffset = CGSize(width: 1, height: 1) }
            if i == 2 { button.glyphPointSize = 17; button.glyphOffset = CGSize(width: 0, height: 1) }
            if i == 5 { button.glyphOffset = CGSize(width: 0, height: 1) }
            if i >= 5 { button.contentTintColor = .black.withAlphaComponent(0.59) }
            addSubview(button); buttons.append(button)
        }
        label.font = .systemFont(ofSize: 13); label.alignment = .center; label.textColor = .black.withAlphaComponent(0.8)
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    func update() {
        label.stringValue = host?.currentURL?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        for (i, b) in buttons.enumerated() { b.isHidden = !isFocused && i != 6 }
        label.isHidden = !isFocused
        buttons[0].isEnabled = host?.canGoBack ?? false; buttons[1].isEnabled = host?.canGoForward ?? false
        buttons[4].isEnabled = false
        buttons[2].image = NSImage(systemSymbolName: host?.isLoading == true ? "xmark" : "arrow.clockwise", accessibilityDescription: "Reload or Stop")
        needsLayout = true
    }
    public override func layout() {
        super.layout(); let w = bounds.width
        buttons[0].frame = SplitMetrics.back; buttons[1].frame = SplitMetrics.forward; buttons[2].frame = SplitMetrics.reload
        let labelWidth = min(250, max(0, w - 300))
        label.frame = CGRect(x: (w - labelWidth) / 2, y: 7, width: labelWidth, height: 18)
        buttons[3].frame = CGRect(x: label.frame.minX - 26, y: 4, width: 24, height: 24)
        buttons[4].frame = CGRect(x: w - 105, y: 2, width: 32, height: 28)
        buttons[5].frame = CGRect(x: w - 69, y: 4, width: 32, height: 24)
        buttons[6].frame = CGRect(x: w - 37, y: 4, width: 32, height: 24)
    }
    private func press(_ i: Int) {
        switch i {
        case 0: host?.goBack()
        case 1: host?.goForward()
        case 2: if host?.isLoading == true { host?.stop() } else { host?.reload() }
        case 3:
            if let url = host?.currentURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); onCopy?() }
        case 5: onMenu?(buttons[5])
        case 6: onClose?()
        default: onURL?()
        }
        update()
    }
    public override func mouseDown(with event: NSEvent) { onURL?() }
}
