import AppKit
import OpenDesign
import OpenModel
import OpenSpaceEditor

@MainActor
enum EditorChecks {
    static func check(_ condition: Bool, _ message: String) { Checks.check(condition, message) }
    static func near(_ a: CGPoint?, _ b: CGPoint?, tolerance: Double = 0.001) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return hypot(a.x - b.x, a.y - b.y) <= tolerance
    }
    static func run() throws {
        for scale in [1.0, 2.0] {
            let scene = try EditorScene(scale: scale)
            let expected: [String: CGRect] = ["pad": CGRect(x: 8, y: 8, width: 340, height: 340),
                "automatic": CGRect(x: 122, y: 32, width: 32, height: 32), "light": CGRect(x: 162, y: 32, width: 32, height: 32),
                "dark": CGRect(x: 202, y: 32, width: 32, height: 32), "remove": CGRect(x: 142, y: 300, width: 32, height: 32),
                "add": CGRect(x: 182, y: 300, width: 32, height: 32)]
            check(expected.allSatisfy { name, frame in
                guard let actual = scene.view.controlFrames[name] else { return false }
                return zip([actual.minX, actual.minY, actual.width, actual.height], [frame.minX, frame.minY, frame.width, frame.height]).allSatisfy { abs($0 - $1) <= 0.5 }
            } && scene.view.bounds.size == CGSize(width: 382, height: 534) && scene.view.content.frame == CGRect(x: 13, y: 13, width: 356, height: 508), "E1 shell frames at \(Int(scale))x within 0.5 pt")
            let image = scene.snapshot()
            check(image.width == Int(382 * scale) && image.height == Int(534 * scale), "E1 real panel raster size at \(Int(scale))x")
            scene.controller.close()
        }
        try drag(); try addRemove(); try modes(); try keyboardAndAccessibility()
        try controls()
    }
    static func controls() throws {
        for scale in [1.0, 2.0] {
            let scene = try EditorScene(scale: scale)
            let frames = scene.view.controlFrames
            let expected: [String: CGRect] = ["previous": CGRect(x: 9, y: 364, width: 32, height: 32),
                "next": CGRect(x: 315, y: 364, width: 32, height: 32), "swatches": CGRect(x: 48, y: 364, width: 260, height: 32),
                "intensity": CGRect(x: 18, y: 424, width: 224, height: 56), "thumb": CGRect(x: 178, y: 424, width: 24, height: 56),
                "noise": CGRect(x: 258, y: 412, width: 84, height: 80), "noise-center": CGRect(x: 280, y: 432, width: 40, height: 40)]
            check(expected.allSatisfy { frames[$0.key] == $0.value } && (0..<9).allSatisfy {
                frames["swatch-\($0)"] == CGRect(x: 48 + 29.5 * Double($0), y: 368, width: 24, height: 24)
            }, "E1 remaining control frames and nine swatches at \(Int(scale))x")
            scene.controller.close()
        }
        let scene = try EditorScene()
        scene.controller.apply(.setAppearance(.dark)); scene.controller.apply(.setNoise(0.45, final: true)); scene.controller.flushPreviewFrame()
        scene.controller.apply(.setIntensity(0.2, final: true)); scene.controller.flushPreviewFrame()
        scene.controller.apply(.cycleTexture); scene.controller.apply(.cycleTexture); scene.controller.apply(.cycleTexture)
        let beforePages = scene.space.theme, commits = scene.controller.commitCount
        check(!scene.view.presets.previous.enabled && scene.view.presets.next.enabled, "E4 first page disables Previous")
        var allPresets = true, allFrames = true
        for page in 0..<5 {
            if page > 0 { scene.click(scene.view.presets.next) }
            allFrames = allFrames && scene.view.presets.page == page && (0..<9).allSatisfy {
                scene.view.controlFrames["swatch-\($0)"] == CGRect(x: 48 + 29.5 * Double($0), y: 368, width: 24, height: 24)
            }
            for (i, swatch) in scene.view.presets.visibleSwatches.enumerated() {
                scene.click(swatch)
                let style = scene.space.theme.style!, preset = SpaceStylePresets.all[page * 9 + i].style
                allPresets = allPresets && style.keyColor == preset.keyColor && style.colorCount == preset.colorCount && style.wheel == preset.wheel
                    && style.appearance == .dark && style.noiseFactor == 0.45 && style.intensityFactor == 0.2 && style.texture == .tweed
            }
        }
        check(allPresets && allFrames && scene.view.presets.page == 4 && !scene.view.presets.next.enabled, "E4 all 45 real swatch clicks, five page frames, preserved modifiers, and last-page refusal")
        for _ in 0..<4 { scene.click(scene.view.presets.previous) }
        scene.click(scene.view.presets.next)
        scene.click(scene.view.presets.visibleSwatches[4])
        check(scene.space.theme.style?.colorCount == 3 && scene.space.theme.style?.wheel == .analogous, "E4 page two gives three analogous colors")
        scene.scroll(scene.view.presets, x: 1)
        check(scene.view.presets.page == 2, "E4 horizontal line scroll pages the strip")
        // Page movement itself never writes or commits a theme.
        scene.undo.removeAllActions()
        let theme = scene.space.theme, count = scene.controller.commitCount
        scene.click(scene.view.presets.previous)
        check(scene.space.theme == theme && scene.controller.commitCount == count && !scene.undo.canUndo && beforePages.style != nil && commits > 0,
              "E4 paging has no model write or undo step")
        scene.controller.close()
        try sliderAndDial()
    }
    static func sliderAndDial() throws {
        let scene = try EditorScene(), slider = scene.view.intensity, dial = scene.view.noise
        let original = scene.space.theme, before = scene.controller.previewCount
        let layouts = (slider.layoutPassCount, dial.layoutPassCount, scene.view.layoutPassCount)
        scene.mouse(.leftMouseDown, at: CGPoint(x: 12, y: 28), in: slider)
        for x in stride(from: 22.0, through: 112, by: 10) { scene.mouse(.leftMouseDragged, at: CGPoint(x: x, y: 28), in: slider) }
        check(slider.value == 0.5 && slider.thumbFrame.midX == 112 && scene.controller.previewCount == before, "E6 slider value maps to 200 pt travel and queues pointer previews")
        scene.controller.flushPreviewFrame(); OffscreenRenderer.settle(scene.view)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 112, y: 28), in: slider); scene.controller.flushPreviewFrame()
        check(scene.space.theme.style?.intensityFactor == 0.5 && scene.controller.commitCount == 1,
              "E6 slider drag previews once per frame and commits once")
        check(slider.layoutPassCount == layouts.0 && dial.layoutPassCount == layouts.1 && scene.view.layoutPassCount == layouts.2,
              "E6 slider and dial use layer updates without per-frame view layout")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(scene.space.theme == original && slider.value == 0.8, "E6 slider undo restores full value and thumb")
        scene.scroll(slider, y: 1); scene.controller.flushPreviewFrame()
        check(abs(slider.value - 0.82) < 1e-9, "E6 intensity scroll changes 0.02 per line")
        scene.key(123, target: slider); scene.controller.flushPreviewFrame()
        check(abs(slider.value - 0.77) < 1e-9, "E6 intensity arrow changes 0.05")
        let point = dial.ringPoint(angle: 162)
        scene.mouse(.leftMouseDown, at: point, in: dial); scene.mouse(.leftMouseUp, at: point, in: dial); scene.controller.flushPreviewFrame()
        check(abs(dial.value - 0.45) < 1e-9 && dial.tickAngle == 162 && dial.litDotCount == 9,
              "E6 dot click snaps 0.05 steps; noise 0.45 gives 162 degrees and exactly nine lit dots")
        let generation = ThemeTexture.generationCount
        scene.mouse(.leftMouseDown, at: dial.ringPoint(angle: 342), in: dial)
        scene.mouse(.leftMouseDragged, at: dial.ringPoint(angle: 2), in: dial)
        scene.mouse(.leftMouseUp, at: dial.ringPoint(angle: 2), in: dial); scene.controller.flushPreviewFrame()
        check(dial.value == 1, "E6 clockwise drag past one clamps at one without wrapping")
        scene.mouse(.leftMouseDown, at: dial.ringPoint(angle: 18), in: dial)
        scene.mouse(.leftMouseDragged, at: dial.ringPoint(angle: 358), in: dial)
        scene.mouse(.leftMouseUp, at: dial.ringPoint(angle: 358), in: dial); scene.controller.flushPreviewFrame()
        check(dial.value == 0, "E6 counterclockwise drag past zero clamps at zero without wrapping")
        scene.scroll(dial, y: 1); scene.controller.flushPreviewFrame()
        check(abs(dial.value - 0.01) < 1e-9, "E6 noise scroll changes 0.01 per line")
        scene.key(124, target: dial); scene.controller.flushPreviewFrame()
        check(abs(dial.value - 0.06) < 1e-9, "E6 noise arrow changes 0.05")
        var textures: [SpaceStyleTexture] = []
        for _ in 0..<4 { scene.click(dial.centerButton); textures.append(dial.texture) }
        check(textures == [.sand, .denim, .tweed, .grain], "E6 center button cycles grain, sand, denim, tweed, grain")
        check(ThemeTexture.generationCount - generation <= 3, "E6 dial previews reuse their texture tiles while noise changes")
        check(slider.accessibilityRole() == .slider && slider.accessibilityLabel() == "Intensity"
              && dial.accessibilityRole() == .slider && dial.accessibilityLabel() == "Noise"
              && dial.centerButton.accessibilityLabel() == "Cycle noise texture"
              && scene.view.presets.visibleSwatches[0].accessibilityLabel()?.hasPrefix("Set Space color to ") == true,
              "E1 remaining native accessibility roles, labels, and texture value")
        check(scene.view.add.nextKeyView === scene.view.presets.previous
              && scene.view.presets.next.nextKeyView === slider && slider.nextKeyView === dial.centerButton
              && dial.centerButton.nextKeyView === dial, "E1 complete keyboard focus order")
        scene.controller.close()
    }
    static func drag() throws {
        let scene = try EditorScene()
        let pad = scene.view.pad, original = scene.space.theme, originalKnob = pad.primaryKnobCenter!
        let beforeLayouts = (scene.view.layoutPassCount, pad.layoutPassCount)
        let down = CGPoint(x: originalKnob.x + 6, y: originalKnob.y + 5)
        scene.mouse(.leftMouseDown, at: down, in: pad)
        check(scene.space.theme == original && near(pad.primaryKnobCenter, originalKnob), "E2 knob mouse down is relative, without a jump")
        for i in 1...12 { scene.mouse(.leftMouseDragged, at: CGPoint(x: down.x + Double(i), y: down.y + Double(i) / 2), in: pad) }
        check(scene.controller.previewCount == 0, "E2 pointer samples queue previews until a display frame")
        scene.controller.flushPreviewFrame()
        OffscreenRenderer.settle(scene.view)
        check(scene.controller.previewCount == 1 && near(pad.primaryKnobCenter, CGPoint(x: originalKnob.x + 12, y: originalKnob.y + 6)), "E2 twelve samples coalesce to one preview and follow pointer delta")
        for i in 13...24 { scene.mouse(.leftMouseDragged, at: CGPoint(x: down.x + Double(i), y: down.y + Double(i) / 2), in: pad) }
        scene.mouse(.leftMouseUp, at: CGPoint(x: down.x + 24, y: down.y + 12), in: pad)
        scene.controller.flushPreviewFrame()
        OffscreenRenderer.settle(scene.view)
        let edited = scene.space.theme, editedKnob = pad.primaryKnobCenter
        check(scene.controller.previewCount == 2 && scene.controller.commitCount == 1 && scene.undo.canUndo,
              "E2 one preview per frame and one commit at mouse up")
        check(scene.view.layoutPassCount == beforeLayouts.0 && pad.layoutPassCount == beforeLayouts.1,
              "E2 drag paints layers without an editor or pad layout pass")
        scene.key(6, target: scene.panel, flags: .command, characters: "z"); scene.controller.prepareForSnapshot()
        check(scene.space.theme == original && near(pad.primaryKnobCenter, originalKnob) && !scene.undo.canUndo,
              "E2 Cmd+Z restores full theme and knob in one undo step")
        scene.key(6, target: scene.panel, flags: [.command, .shift], characters: "z"); scene.controller.prepareForSnapshot()
        check(scene.space.theme == edited && near(pad.primaryKnobCenter, editedKnob), "E2 Shift+Cmd+Z restores edited theme and knob")
        scene.mouse(.leftMouseDown, at: CGPoint(x: 100, y: 190), in: pad)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 100, y: 190), in: pad); scene.controller.flushPreviewFrame()
        check(near(pad.primaryKnobCenter, CGPoint(x: 100, y: 190)), "E2 clicking outside the knob jumps directly")
        scene.mouse(.leftMouseDown, at: CGPoint(x: 330, y: 330), in: pad)
        scene.mouse(.leftMouseDragged, at: CGPoint(x: 600, y: 600), in: pad)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 600, y: 600), in: pad); scene.controller.flushPreviewFrame()
        check(abs(hypot(scene.controller.state.knob!.x, scene.controller.state.knob!.y) - 0.99) < 0.0001, "E2 pad clamps at unit radius 0.99")
        scene.controller.close()
    }
    static func addRemove() throws {
        let scene = try EditorScene()
        scene.click(scene.view.add)
        let two = SpaceThemeStyle(theme: scene.space.theme, system: .dark)
        let twoLayout: Bool
        if case .blended(let base, let overlay) = two.fill { twoLayout = base.count == 2 && overlay.isEmpty } else { twoLayout = false }
        check(scene.space.theme.style?.colorCount == 2 && twoLayout, "E3 Add creates the two-color background")
        scene.click(scene.view.add)
        let three = SpaceThemeStyle(theme: scene.space.theme, system: .dark)
        let threeLayout: Bool
        if case .blended(let base, let overlay) = three.fill { threeLayout = base.count == 2 && overlay.count == 2 && overlay[0] == .clear } else { threeLayout = false }
        check(scene.space.theme.style?.colorCount == 3 && threeLayout && !scene.view.add.enabled,
              "E3 Add creates three colors and disables at the limit")
        let full = scene.space.theme
        scene.click(scene.view.add)
        check(scene.space.theme == full, "E3 disabled Add changes nothing")
        scene.click(scene.view.remove); scene.click(scene.view.remove)
        let beforeEmpty = scene.space.theme
        scene.click(scene.view.remove)
        check(scene.space.theme == SpaceTheme() && scene.view.remove.isHidden && scene.view.add.isHidden && !scene.view.pad.emptyLabel.isHidden,
              "E3 Remove clears the theme and shows the empty pad")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(scene.space.theme == beforeEmpty && scene.view.pad.emptyLabel.isHidden && scene.view.pad.primaryKnobCenter != nil,
              "E3 undo restores the full last color and knob")
        scene.undo.redo(); scene.controller.prepareForSnapshot()
        scene.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: scene.view.pad)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 200), in: scene.view.pad); scene.controller.flushPreviewFrame()
        check(scene.space.theme.style?.colorCount == 1 && scene.view.pad.emptyLabel.isHidden, "E3 empty pad click creates its first color")
        scene.controller.close()
    }
    static func modes() throws {
        let scene = try EditorScene()
        let knob = scene.controller.state.knob
        for (index, mode, range) in [(2, SpaceStyleAppearance.dark, 0.01...0.425), (1, .light, 0.575...0.97), (0, .automatic, 0.01...0.97)] {
            scene.click(scene.view.modes.buttons[index])
            let state = scene.controller.state
            let content = SpaceThemeStyle(theme: scene.space.theme, system: .light).contentAppearance
            let primary = ThemeColorMath.primaryPalette(key: ThemeColorMath.toP3(state.style!.keyColor))
            let palettes = ThemeColorMath.semanticPalettes(primary)
            let expected = mode == .dark ? ContentAppearance.dark : mode == .light ? .light
                : ThemeColorMath.contentAppearance(key: ThemeColorMath.toP3(state.style!.keyColor), light: palettes.light, dark: palettes.dark, bias: ThemeTuning.automaticBias)
            check(state.appearance == mode && state.range == range && near(state.knob, knob) && content == expected,
                  "E5 \(mode.rawValue) keeps knob radius and derives the required palette and range")
        }
        scene.controller.close()
    }
    static func keyboardAndAccessibility() throws {
        let scene = try EditorScene()
        let pad = scene.view.pad
        let start = ThemeColorMath.hsl(ThemeColorMath.toP3(scene.controller.state.style!.keyColor)).h
        scene.key(124, target: pad)
        let next = ThemeColorMath.hsl(ThemeColorMath.toP3(scene.controller.state.style!.keyColor)).h
        check(abs((next - start) * 360 - 5) < 0.01 && scene.controller.commitCount == 1, "E2 keyboard hue commits five degrees")
        let oldRadius = hypot(scene.controller.state.knob!.x, scene.controller.state.knob!.y)
        scene.key(126, target: pad, flags: .shift)
        check(abs(hypot(scene.controller.state.knob!.x, scene.controller.state.knob!.y) - min(0.99, oldRadius + 0.099)) < 0.001,
              "E2 Shift+Up changes radius by 0.1 of the available range")
        check(scene.panel.accessibilityRole() == .popover && scene.panel.accessibilityLabel() == "Edit Theme"
              && pad.accessibilityRole() == .slider && pad.accessibilityLabel() == "Color"
              && scene.view.modes.accessibilityRole() == .radioGroup
              && scene.view.modes.buttons.map { $0.accessibilityRole() } == [.radioButton, .radioButton, .radioButton],
              "E1 native accessibility roles and labels")
        check(scene.view.modes.buttons[2].nextKeyView === pad && pad.nextKeyView === scene.view.remove
              && scene.view.remove.nextKeyView === scene.view.add, "E1 keyboard focus order through shell controls")
        _ = pad.accessibilityPerformIncrement()
        check(scene.controller.commitCount == 3, "E2 accessibility increment uses the same commit path")
        let before = scene.controller.commitCount
        scene.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 180), in: pad)
        scene.key(53, target: scene.panel)
        check(scene.controller.isClosed && scene.controller.commitCount == before + 1, "E2 Escape during a drag commits before closing")
    }
}
