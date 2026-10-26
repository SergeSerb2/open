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
        try drag(); try addRemove(); try modes(); try keyboardAndAccessibility(); try reviewedFlows(); try sessionTwoFlows()
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
        check(scene.space.theme == SpaceTheme() && !scene.view.remove.isHidden && !scene.view.add.isHidden
              && !scene.view.remove.enabled && !scene.view.add.enabled && !scene.view.pad.emptyLabel.isHidden,
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
        check(abs(hypot(scene.controller.state.knob!.x, scene.controller.state.knob!.y) - min(0.99, oldRadius + 0.1)) < 0.001,
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
    static func reviewedFlows() throws {
        let scene = try EditorScene(ownerUndo: true)
        scene.panel.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        scene.panel.orderBack(nil)
        let original = scene.space.theme
        check(scene.undo.groupsByEvent && scene.panel.undoManager === scene.model.undoManager && scene.undo === scene.owner.undoManager,
              "E2 panel, model, and owner share one default-grouping undo manager")
        scene.clickContent(CGPoint(x: 218, y: 48))
        check(scene.controller.state.appearance == .dark && scene.controller.commitCount == 1
              && NSScreen.screens.allSatisfy { !$0.frame.intersects(scene.panel.frame) },
              "E1 panel.sendEvent hit-tests the mode button over the pad in an offscreen window")
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        check(scene.undo.undoActionName == "Update Theme", "E2 default-grouping manager names the actual theme undo group")
        scene.key(6, target: scene.panel, flags: .command, characters: "z"); scene.controller.prepareForSnapshot()
        check(scene.space.theme == original && !scene.undo.canUndo, "E2 default-grouping owner manager undoes the complete gesture")
        scene.clickContent(CGPoint(x: 198, y: 316))
        check(scene.controller.state.style?.colorCount == 2, "E1 panel.sendEvent routes Add to its button rather than the pad")
        scene.panel.orderOut(nil); scene.controller.close()

        let empty = try EditorScene(style: nil)
        check(empty.view.pad.nextKeyView === empty.view.modes.buttons[0] && empty.view.remove.nextKeyView == nil && empty.view.add.nextKeyView == nil,
              "E1 empty-state key chain excludes disabled buttons")
        empty.controller.close()
        let held = try EditorScene()
        held.sendKey(124, target: held.view.pad)
        for _ in 0..<8 { held.sendKey(124, target: held.view.pad, repeatKey: true) }
        held.controller.flushPreviewFrame()
        check(held.controller.commitCount == 0, "E2 repeated pad arrows preview without minting undo steps")
        held.sendKey(124, target: held.view.pad, type: .keyUp); held.controller.flushPreviewFrame()
        check(held.controller.commitCount == 1, "E2 arrow key up commits one held-key gesture")
        let count = held.controller.state.style?.colorCount
        held.sendKey(49, target: held.view.add, repeatKey: true)
        check(held.controller.state.style?.colorCount == count, "E1 repeated button activation is ignored")
        check(!(held.view.pad.accessibilityValue() as? String ?? "").contains(" %"), "E1 AX lightness uses a percent without a space")
        held.click(held.view.add); held.click(held.view.add)
        check(held.view.remove.nextKeyView === held.view.modes.buttons[0] && held.view.add.nextKeyView == nil,
              "E1 key chain removes disabled Add at three colors")
        held.controller.close()
    }
    static func sessionTwoFlows() throws {
        let scene = try EditorScene(), original = scene.space.theme
        scene.click(scene.view.add)
        let key = ThemeColorMath.toP3(scene.space.theme.style!.keyColor)
        let h = ThemeColorMath.hsl(key).h
        let hues = ThemeColorMath.harmony(key: key, count: 2, wheel: scene.space.theme.style!.wheel).map { ThemeColorMath.hsl($0).h }
        let offset = ((hues[1] - h) * 360 + 360).truncatingRemainder(dividingBy: 360)
        check(original.style?.wheel == .analogous && scene.space.theme.style?.wheel == .complementary && abs(offset - 180) < 0.01,
              "E3 one-color analogous Add switches to complementary and places the second color at 180 degrees")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(scene.space.theme == original && scene.space.theme.style?.colorCount == 1 && scene.space.theme.style?.wheel == .analogous,
              "E3 one undo restores both one color and its original analogous mode")
        let analogous = try EditorScene(style: SpaceStyle(keyColor: original.style!.keyColor, colorCount: 2, wheel: .analogous))
        analogous.click(analogous.view.add)
        check(analogous.space.theme.style?.colorCount == 3 && analogous.space.theme.style?.wheel == .analogous,
              "E3 Add at two colors preserves the stored analogous mode")
        check(analogous.view.pad.secondaryKnobFrames.count == 2 && analogous.view.pad.secondaryKnobFrames.allSatisfy { $0.size == CGSize(width: 27, height: 27) },
              "E1 session-2 secondary knob rest frames are 27 pt")
        analogous.controller.close()
        let grey = SpaceStyle(keyColor: RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
        let greyOne = try EditorScene(style: grey)
        var greyThree = grey; greyThree.colorCount = 3
        let greyMany = try EditorScene(style: greyThree)
        let oneImage = OffscreenRenderer().snapshot(greyOne.view.pad, scale: 1)
        let manyImage = OffscreenRenderer().snapshot(greyMany.view.pad, scale: 1)
        check((oneImage.dataProvider!.data! as Data) == (manyImage.dataProvider!.data! as Data),
              "E3 coincident grey harmony knobs render identically with the primary on top")
        greyOne.controller.close(); greyMany.controller.close()
        scene.click(scene.view.modes.buttons[1])
        check(scene.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
              "E5 forced Light changes the editor while the system is Dark")
        scene.click(scene.view.modes.buttons[2])
        check(scene.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
              "E5 forced Dark changes the editor live")
        NSApp.appearance = NSAppearance(named: .aqua)
        scene.click(scene.view.modes.buttons[0])
        check(scene.panel.appearance == nil && scene.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
              "E5 Automatic inherits system appearance rather than the Space palette")
        scene.controller.close()
        let empty = try EditorScene(style: nil)
        check(abs(empty.view.pad.emptyLabel.frame.midY - 170) < 0.01 && !empty.view.remove.isHidden && !empty.view.add.isHidden,
              "E1 empty label is vertically centered and Add/Remove stay visible")
        empty.controller.close()
    }
}
