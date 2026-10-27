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
    public static let noiseInputEpsilon = 1e-6
    public var style: SpaceStyle?
    public var presetPage: Int = 0
    public var isGestureInProgress = false
    public private(set) var range: ClosedRange<Double>
    public private(set) var saturation: Double
    private var emptyAppearance: SpaceStyleAppearance = .automatic
    private var startKnob: CGPoint?
    private var startPointer: CGPoint?

    public init(style: SpaceStyle? = nil) {
        self.style = style
        let key = style.map { ThemeColorMath.toP3($0.keyColor) }
        range = ThemeColorMath.editorRange(key: key, mode: style?.appearance ?? .automatic)
        saturation = key.map { max(0.01, ThemeColorMath.hsl($0).s) } ?? 1
    }
    public var appearance: SpaceStyleAppearance { style?.appearance ?? emptyAppearance }
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
                if value.colorCount == 1 { style = nil; emptyAppearance = .automatic; range = 0.01...0.97; saturation = 1 }
                else { style?.colorCount -= 1 }
            }
        case .setAppearance(let mode):
            guard mode != appearance else { return }
            if mode != .automatic {
                let next = ThemeColorMath.forcedRange(mode)
                if var value = style {
                    let key = ThemeColorMath.hsl(ThemeColorMath.toP3(value.keyColor))
                    let t = min(1, max(0, (key.l - range.lowerBound) / (range.upperBound - range.lowerBound)))
                    value.keyColor = ThemeColorMath.toExtendedSRGB(ThemeColorMath.rgb(h: key.h, s: key.s,
                        l: next.lowerBound + t * (next.upperBound - next.lowerBound)))
                    style = value
                }
                range = next
            }
            if style != nil { style?.appearance = mode } else { emptyAppearance = mode }
        case .selectPreset(let index):
            guard SpaceStylePresets.all.indices.contains(index) else { return }
            let preset = SpaceStylePresets.all[index].style
            var result = style ?? SpaceStyle(keyColor: preset.keyColor, appearance: appearance)
            result.keyColor = preset.keyColor; result.colorCount = preset.colorCount; result.wheel = preset.wheel
            let key = ThemeColorMath.toP3(preset.keyColor)
            if appearance == .automatic { range = ThemeColorMath.autoRange(lightness: ThemeColorMath.hsl(key).l) }
            saturation = max(0.01, ThemeColorMath.hsl(key).s)
            style = result
        case .setPresetPage(let page): presetPage = min(4, max(0, page))
        case .setIntensity(let value, let final):
            style?.intensityFactor = value; isGestureInProgress = !final
        case .setNoise(let value, let final):
            style?.noiseFactor = abs(value) <= Self.noiseInputEpsilon ? 0 : value; isGestureInProgress = !final
        case .cycleTexture:
            guard var value = style else { return }
            if value.noiseFactor <= Self.noiseInputEpsilon { value.texture = .grain; value.noiseFactor = 0.8 }
            else if value.texture == .tweed { value.noiseFactor = 0 }
            else if let index = SpaceStyleTexture.allCases.firstIndex(of: value.texture) {
                value.texture = SpaceStyleTexture.allCases[index + 1]; value.noiseFactor = 0.8
            }
            style = value
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
