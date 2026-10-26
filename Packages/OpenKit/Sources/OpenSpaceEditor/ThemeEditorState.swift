import CoreGraphics
import Foundation
import OpenDesign
import OpenModel

public enum ThemeEditorAction: Equatable, Sendable {
    case dragKnob(to: CGPoint, relative: Bool), endDrag
    case selectPreset(index: Int), setPresetPage(Int)
    case addColor, removeColor
    case setAppearance(SpaceStyleAppearance)
    case setIntensity(Double, final: Bool)
    case setNoise(Double, final: Bool), cycleTexture
    case keyboardHue(Double), keyboardRadius(Double)
    case beginKeyboardGesture, endKeyboardGesture
}

/// Values only. Views paint the state; the controller owns preview and undo.
public struct ThemeEditorState: Equatable, Sendable {
    public var style: SpaceStyle?
    public var presetPage: Int = 0
    public var isGestureInProgress = false
    private var emptyAppearance: SpaceStyleAppearance = .automatic
    private var startKnob: CGPoint?
    private var startPointer: CGPoint?

    public init(style: SpaceStyle? = nil) { self.style = style }
    public var appearance: SpaceStyleAppearance { style?.appearance ?? emptyAppearance }
    public var range: ClosedRange<Double> { ThemeColorMath.lightnessRange(appearance) }
    public var saturation: Double { style.map { max(ThemeColorMath.hsl(ThemeColorMath.toP3($0.keyColor)).s, 0.01) } ?? 0.8 }
    public var knob: CGPoint? { style.map { ThemeColorMath.knob(for: ThemeColorMath.toP3($0.keyColor), range: range) } }

    public mutating func apply(_ action: ThemeEditorAction) {
        switch action {
        case .dragKnob(let point, let relative):
            if !isGestureInProgress {
                isGestureInProgress = true
                startKnob = knob; startPointer = point
                if relative && style != nil { return }
            }
            let target: CGPoint
            if relative, let startKnob, let startPointer {
                target = CGPoint(x: startKnob.x + point.x - startPointer.x, y: startKnob.y + point.y - startPointer.y)
                if point == startPointer { return }
            } else { target = point }
            setColor(at: target)
        case .beginKeyboardGesture: isGestureInProgress = true
        case .endDrag, .endKeyboardGesture:
            isGestureInProgress = false; startKnob = nil; startPointer = nil
        case .addColor:
            if var value = style, value.colorCount < 3 {
                if value.colorCount == 1 { value.wheel = .complementary }
                value.colorCount += 1; style = value
            }
        case .removeColor:
            if let value = style {
                if value.colorCount == 1 { style = nil; emptyAppearance = .automatic }
                else { style?.colorCount -= 1 }
            }
        case .setAppearance(let mode):
            guard mode != appearance else { return }
            if let value = style, let position = knob {
                var result = value
                result.keyColor = ThemeColorMath.toExtendedSRGB(ThemeColorMath.color(at: position, saturation: saturation,
                                                                                    range: ThemeColorMath.lightnessRange(mode)))
                result.appearance = mode; style = result
            } else { emptyAppearance = mode }
        case .selectPreset(let index):
            guard SpaceStylePresets.all.indices.contains(index) else { return }
            let preset = SpaceStylePresets.all[index].style
            var result = style ?? SpaceStyle(keyColor: preset.keyColor, appearance: appearance)
            result.keyColor = preset.keyColor; result.colorCount = preset.colorCount; result.wheel = preset.wheel
            style = result
        case .setPresetPage(let page): presetPage = min(4, max(0, page))
        case .setIntensity(let value, let final):
            style?.intensityFactor = value; isGestureInProgress = !final
        case .setNoise(let value, let final):
            style?.noiseFactor = value; isGestureInProgress = !final
        case .cycleTexture:
            guard let texture = style?.texture, let index = SpaceStyleTexture.allCases.firstIndex(of: texture) else { return }
            style?.texture = SpaceStyleTexture.allCases[(index + 1) % SpaceStyleTexture.allCases.count]
        case .keyboardHue(let degrees):
            guard var value = style else { return }
            let hsl = ThemeColorMath.hsl(ThemeColorMath.toP3(value.keyColor))
            value.keyColor = ThemeColorMath.toExtendedSRGB(ThemeColorMath.rgb(h: hsl.h + degrees / 360, s: saturation, l: hsl.l))
            style = value
        case .keyboardRadius(let delta):
            guard let position = knob else { return }
            let r = hypot(position.x, position.y), target = min(0.99, max(0, r + delta))
            let h = r > 0 ? atan2(position.y, position.x) : 0
            setColor(at: CGPoint(x: cos(h) * target, y: sin(h) * target))
        }
    }

    private mutating func setColor(at point: CGPoint) {
        let color = ThemeColorMath.toExtendedSRGB(ThemeColorMath.color(at: point, saturation: saturation, range: range))
        if style == nil { style = SpaceStyle(keyColor: color, appearance: emptyAppearance) }
        else { style?.keyColor = color }
    }
}
