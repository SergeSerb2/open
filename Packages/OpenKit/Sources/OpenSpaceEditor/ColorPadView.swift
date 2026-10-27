import AppKit
import OpenDesign
import OpenModel

/// Theme state and actions stay here; all pad drawing and input live in OpenDesign.
@MainActor
public final class ColorPadView: OpenDesign.ColorPadView {
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var state = ThemeEditorState()
    public let emptyLabel = NSTextField(wrappingLabelWithString: "Tap to pick a color for this space")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        emptyLabel.font = .systemFont(ofSize: 13,weight: .semibold)
        emptyLabel.alignment = .center; emptyLabel.maximumNumberOfLines = 1
        emptyLabel.setAccessibilityElement(false); addSubview(emptyLabel)
        onInput = { [weak self] input in
            switch input {
            case .beginDrag: break
            case .endDrag: self?.onAction?(.endDrag)
            case .beginKeyboardGesture: self?.onAction?(.beginKeyboardGesture)
            case .endKeyboardGesture: self?.onAction?(.endKeyboardGesture)
            case .keyboardHue(let value): self?.onAction?(.keyboardHue(value))
            case .keyboardRadius(let value): self?.onAction?(.keyboardRadius(value))
            }
        }
        refreshAppearance()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() {
        super.layout()
        let height = ceil(emptyLabel.cell?.cellSize(forBounds: CGRect(x: 0,y: 0,width: 220,height: 40)).height ?? 18)
        emptyLabel.frame = CGRect(x: bounds.midX-110,y: bounds.midY-height/2,width: 220,height: height)
    }
    public func apply(_ state: ThemeEditorState) {
        self.state = state; emptyLabel.isHidden = state.style != nil
        super.apply(state,law: ThemePadLaw(),gestureInProgress: state.isGestureInProgress) { [weak self] action in self?.onAction?(action) }
    }
    public override func refreshAppearance() {
        super.refreshAppearance()
        emptyLabel.textColor = ThemeEditorColors.secondaryText.resolved(contentAppearance).nsColor
    }
    public override func accessibilityValue() -> Any? {
        guard let style = state.style else { return "No color" }
        let color = ThemeColorMath.hsl(ThemeColorMath.toP3(style.keyColor))
        return "Hue \(Int((color.h*360).rounded()))°, lightness \(Int((color.l*100).rounded()))%"
    }
    public override func accessibilityPerformIncrement() -> Bool { onAction?(.keyboardHue(5)); return state.style != nil }
    public override func accessibilityPerformDecrement() -> Bool { onAction?(.keyboardHue(-5)); return state.style != nil }
}

@MainActor private struct ThemePadLaw: ColorPadLaw {
    func knobs(for state: ThemeEditorState) -> [ColorPadKnob] {
        guard let style = state.style else { return [] }
        return ThemeColorMath.harmony(key: ThemeColorMath.toP3(style.keyColor),count: style.colorCount,wheel: style.wheel).map { color in
            ColorPadKnob(position: ThemeColorMath.knob(for: color,range: state.range),fill: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,components: [color.r,color.g,color.b,1])!)
        }
    }
    func value(at unitPoint: CGPoint,relative: Bool) -> ThemeEditorAction { .dragKnob(to: unitPoint,relative: relative) }
}
