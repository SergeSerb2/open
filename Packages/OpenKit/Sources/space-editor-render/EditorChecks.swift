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
        try drag(); try padCalibration(); try addRemove(); try modes(); try keyboardAndAccessibility(); try reviewedFlows(); try sessionTwoFlows(); try controls(); try reviewedControls(); try roundThreeControls(); try releasedControllerUndo(); compatibilityRange(); try undoKeepsPresetPage()
    }
    static func releasedControllerUndo() throws {
        let model = try RenderCLI.fixtureModel(), undo = UndoManager()
        undo.groupsByEvent = false; model.undoManager = undo
        let owner = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 900, height: 700),
                             styleMask: .borderless, backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let original = model.spaces[0].theme
        var controller: ThemeEditorController? = ThemeEditorController(model: model, spaceID: model.spaces[0].id,
            window: owner, anchor: .sidebarTrailingEdge(sidebarFrameInWindow: CGRect(x: 0, y: 0, width: 228, height: 700)))
        controller?.apply(.selectPreset(index: 4))
        let edited = model.spaces[0].theme
        weak let released = controller
        controller?.close(); controller = nil
        check(released == nil && original != edited, "S9 lifetime: commit, close, and release the editor controller")
        // Normal allocation churn makes an unowned, freed undo target observable.
        let churn = (0..<128).map { NSMutableSet(object: $0) }
        withExtendedLifetime(churn) { undo.undo() }
        check(model.spaces[0].theme == original && !undo.canUndo,
              "S9 lifetime: undo after controller release restores the full theme without a crash")
        undo.redo()
        check(model.spaces[0].theme == edited, "S9 lifetime: redo after controller release restores the edited theme")
    }
    static func undoKeepsPresetPage() throws {
        let scene = try EditorScene()
        scene.controller.apply(.selectPreset(index: 4))
        scene.controller.apply(.setPresetPage(3))
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(scene.controller.state.presetPage == 3, "S9 undo keeps preset navigation on the current page")
        scene.undo.redo(); scene.controller.prepareForSnapshot()
        check(scene.controller.state.presetPage == 3, "S9 redo keeps preset navigation on the current page")
        scene.controller.close()
    }
    static func compatibilityRange() {
        check(ThemeColorMath.lightnessRange(.automatic) == 0.01...0.97,
              "S9 compatibility: public Automatic range remains the empty-editor default without trapping")
    }
    static func padCalibration() throws {
        let scene = try EditorScene(style: SpaceStylePresets.all[7].style)
        func same(_ a: ThemeEditorState, _ b: ThemeEditorState) -> Bool {
            a.style == b.style && a.range == b.range && a.saturation == b.saturation && a.knob == b.knob
        }
        let start = scene.controller.state
        scene.click(scene.view.presets.swatches[4])
        let preset = scene.controller.state
        check(start.range != preset.range && start.saturation != preset.saturation,
              "S9 preset tap changes the stored editor range and saturation")
        let point = CGPoint(x: 245, y: 210)
        scene.mouse(.leftMouseDown, at: point, in: scene.view.pad)
        scene.mouse(.leftMouseDragged, at: CGPoint(x: 260, y: 220), in: scene.view.pad)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 260, y: 220), in: scene.view.pad)
        scene.controller.flushPreviewFrame()
        let dragged = scene.controller.state
        check(dragged.range == preset.range && dragged.saturation == preset.saturation,
              "S9 drag keeps the current range and saturation")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(same(scene.controller.state, preset), "S9 first undo restores exact preset style, knob, range, and saturation")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(same(scene.controller.state, start) && !scene.undo.canUndo,
              "S9 second undo restores exact pre-preset editor state")
        scene.undo.redo(); scene.controller.prepareForSnapshot()
        check(same(scene.controller.state, preset), "S9 first redo restores exact preset editor state")
        scene.undo.redo(); scene.controller.prepareForSnapshot()
        check(same(scene.controller.state, dragged), "S9 second redo restores exact dragged editor state without recentering")
        let reopened = ThemeEditorState(style: scene.space.theme.style)
        check(reopened.range == ThemeColorMath.editorRange(key: ThemeColorMath.toP3(dragged.style!.keyColor), mode: .automatic)
              && reopened.range != dragged.range, "S9 reopening reconstructs the range from the key; undo state is not persisted")
        scene.click(scene.view.modes.buttons[1])
        let forced = scene.controller.state.range
        for _ in 0..<4 { scene.click(scene.view.presets.next) }
        scene.click(scene.view.presets.swatches[44])
        check(scene.controller.state.range == forced && scene.controller.state.saturation == 0.01,
              "S9 forced preset keeps the current range and updates saturation")
        let forcedKey = scene.space.theme.style!.keyColor
        scene.click(scene.view.modes.buttons[0])
        check(scene.controller.state.range == forced && scene.space.theme.style!.keyColor == forcedKey,
              "S9 Automatic return keeps the key and range")
        scene.click(scene.view.remove)
        check(scene.controller.state.range == 0.01...0.97 && scene.controller.state.saturation == 1,
              "S9 removing the final color resets the empty range and saturation")
        scene.controller.close(); scene.controller.close()
        let closed = scene.controller.state
        scene.undo.undo(); OffscreenRenderer.settle(scene.view, runLoop: 0.002)
        check(scene.controller.isClosed && scene.controller.state == closed && scene.space.theme.style != nil,
              "S9 undo after repeated close restores the model without repainting a closed editor")
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
        let key = scene.controller.state.style!.keyColor, range = scene.controller.state.range
        for (index, mode, scheme) in [(2, SpaceStyleAppearance.dark, ContentAppearance.dark), (1, .light, .light), (0, .automatic, .light)] {
            scene.click(scene.view.modes.buttons[index])
            let state = scene.controller.state
            let style = SpaceThemeStyle(theme: scene.space.theme, system: .light)
            let primary = ThemeColorMath.primaryPalette(key: ThemeColorMath.toP3(state.style!.keyColor))
            let palettes = ThemeColorMath.semanticPalettes(primary)
            // Arc 1.172.2: every mode keeps the key and the §6.5 polarity; the mode picks the window scheme.
            let expected = ThemeColorMath.contentAppearance(key: ThemeColorMath.toP3(state.style!.keyColor), light: palettes.light, dark: palettes.dark, bias: SidebarThemeRules.polarityBias)
            check(state.appearance == mode && state.style!.keyColor == key && state.range == range && near(state.knob, knob)
                  && style.contentAppearance == expected && style.windowColorScheme == scheme,
                  "E5 \(mode.rawValue) keeps the key and polarity and sets the window scheme")
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
        check(empty.view.pad.nextKeyView === empty.view.presets.visibleSwatches[0] && empty.view.remove.nextKeyView == nil && empty.view.add.nextKeyView == nil,
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
        check(held.view.remove.nextKeyView === held.view.presets.visibleSwatches[0] && held.view.add.nextKeyView == nil,
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
        check(scene.view.modes.buttons.allSatisfy { abs(($0.glyphView.contentTintColor?.alphaComponent ?? 0) - 0.5) < 0.001 },
              "E1 light mode glyphs use the shared black 0.50 token")
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
        check(empty.view.remove.glyphView.alphaValue == 0.32 && empty.view.add.glyphView.alphaValue == 0.32,
              "E1 disabled Remove/Add use the captured 0.32 glyph factor")
        empty.controller.close()
    }
    static func controls() throws {
        for scale in [1.0, 2.0] {
            let scene = try EditorScene(scale: scale)
            let frames = scene.view.controlFrames
            let expected: [String: CGRect] = ["previous": CGRect(x: 9, y: 364, width: 32, height: 32),
                "next": CGRect(x: 315, y: 364, width: 32, height: 32), "swatches": CGRect(x: 48, y: 364, width: 260, height: 32),
                "intensity": CGRect(x: 18, y: 424, width: 224, height: 56), "thumb": CGRect(x: 180.32, y: 424, width: 24.4, height: 56),
                "noise": CGRect(x: 258, y: 412, width: 84, height: 80), "noise-center": CGRect(x: 278, y: 432, width: 40, height: 40)]
            check(expected.allSatisfy { name, expected in
                guard let frame = frames[name] else { return false }
                return zip([frame.minX, frame.minY, frame.width, frame.height], [expected.minX, expected.minY, expected.width, expected.height]).allSatisfy { abs($0 - $1) < 0.001 }
            } && (0..<9).allSatisfy {
                frames["swatch-\($0)"] == CGRect(x: 48 + floor(29.5 * Double($0) * scale) / scale, y: 368, width: 24, height: 24)
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
                scene.view.controlFrames["swatch-\($0)"] == CGRect(x: [48.0, 77, 107, 136, 166, 195, 225, 254, 284][$0], y: 368, width: 24, height: 24)
            }
            for (i, swatch) in scene.view.presets.visibleSwatches.enumerated() {
                scene.click(swatch)
                let style = scene.space.theme.style!, preset = SpaceStylePresets.all[page * 9 + i].style
                allPresets = allPresets && style.keyColor == preset.keyColor && style.colorCount == preset.colorCount && style.wheel == preset.wheel
                    && style.appearance == .dark && style.noiseFactor == 0.8 && style.intensityFactor == 0.2 && style.texture == .tweed
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
        let empty = try EditorScene(style: nil)
        empty.mouse(.leftMouseDown, at: CGPoint(x: 114, y: 28), in: empty.view.intensity)
        empty.mouse(.leftMouseUp, at: CGPoint(x: 114, y: 28), in: empty.view.intensity)
        check(empty.space.theme == SpaceTheme() && !empty.view.noise.centerButton.accessibilityPerformPress() && !empty.undo.canUndo,
              "E6 empty theme disables slider and texture input without a write or undo")
        empty.click(empty.view.presets.next); empty.click(empty.view.presets.visibleSwatches[0])
        check(empty.space.theme.style?.colorCount == 3 && empty.undo.canUndo, "E4 preset creates a theme from the empty state")
        empty.undo.undo(); empty.controller.prepareForSnapshot()
        check(empty.space.theme == SpaceTheme() && !empty.view.pad.emptyLabel.isHidden, "E4 undo of empty-state preset restores empty theme")
        empty.controller.close()
    }
    static func sliderAndDial() throws {
        let scene = try EditorScene(), slider = scene.view.intensity, dial = scene.view.noise
        let original = scene.space.theme, before = scene.controller.previewCount
        let layouts = (slider.layoutPassCount, dial.layoutPassCount, scene.view.layoutPassCount)
        scene.mouse(.leftMouseDown, at: CGPoint(x: 7.8, y: 28), in: slider)
        for x in stride(from: 18.0, through: 108, by: 10) { scene.mouse(.leftMouseDragged, at: CGPoint(x: x, y: 28), in: slider) }
        scene.mouse(.leftMouseDragged, at: CGPoint(x: 112, y: 28), in: slider)
        check(abs(slider.value - 0.5) < 1e-9 && scene.view.controlFrames["thumb"]?.midX == 130 && scene.controller.previewCount == before,
              "E6 slider midpoint is literal content x=130 (panel x=143) and queues pointer previews")
        scene.controller.flushPreviewFrame(); OffscreenRenderer.settle(scene.view)
        scene.mouse(.leftMouseUp, at: CGPoint(x: 112, y: 28), in: slider); scene.controller.flushPreviewFrame()
        check(scene.space.theme.style?.intensityFactor == 0.5 && scene.controller.commitCount == 1,
              "E6 slider drag previews once per frame and commits once")
        check(slider.layoutPassCount == layouts.0 && dial.layoutPassCount == layouts.1 && scene.view.layoutPassCount == layouts.2,
              "E6 slider and dial use layer updates without per-frame view layout")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(scene.space.theme == original && slider.value == 0.8, "E6 slider undo restores full value and thumb")
        let noOpCommits = scene.controller.commitCount
        scene.mouse(.leftMouseDown, at: CGPoint(x: slider.thumbFrame.midX, y: 28), in: slider)
        scene.mouse(.leftMouseUp, at: CGPoint(x: slider.thumbFrame.midX, y: 28), in: slider); scene.controller.flushPreviewFrame()
        check(slider.value == 0.8 && scene.controller.commitCount == noOpCommits,
              "E6 calibrated thumb center click keeps its value without a jump or undo")
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
        var textures: [String] = [], values: [Double] = []
        for _ in 0..<5 {
            scene.click(dial.centerButton); textures.append(dial.value == 0 ? "none" : dial.texture.rawValue); values.append(dial.value)
        }
        check(textures == ["sand", "denim", "tweed", "none", "grain"] && values == [0.8, 0.8, 0.8, 0, 0.8],
              "E6 center cycles none/grain/sand/denim/tweed with exactly 0.8 or zero noise")
        scene.undo.undo(); scene.controller.prepareForSnapshot()
        check(dial.value == 0 && dial.texture == .tweed, "E6 texture cycle undo restores both noise and retained texture in one step")
        scene.undo.redo(); scene.controller.prepareForSnapshot()
        check(ThemeTexture.generationCount - generation <= 4, "E6 dial previews reuse their texture tiles while noise changes")
        check(slider.accessibilityRole() == .slider && slider.accessibilityLabel() == "Intensity"
              && dial.accessibilityRole() == .slider && dial.accessibilityLabel() == "Noise"
              && dial.centerButton.accessibilityLabel() == "Cycle noise texture"
              && scene.view.presets.visibleSwatches[0].accessibilityLabel()?.hasPrefix("Set Space color to ") == true,
              "E1 remaining native accessibility roles, labels, and texture value")
        check(scene.view.add.nextKeyView === scene.view.presets.visibleSwatches[0]
              && scene.view.presets.next.nextKeyView === slider && slider.nextKeyView === dial.centerButton
              && dial.centerButton.nextKeyView === dial, "E1 complete keyboard focus order")
        scene.controller.close()
        let endpoints = try EditorScene()
        var mapping = true
        for value in [0.0, 0.5, 1.0] {
            let x = 7.8 + 208.4 * value
            endpoints.mouse(.leftMouseDown, at: CGPoint(x: x, y: 28), in: endpoints.view.intensity)
            endpoints.mouse(.leftMouseUp, at: CGPoint(x: x, y: 28), in: endpoints.view.intensity); endpoints.controller.flushPreviewFrame()
            mapping = mapping && abs(endpoints.view.intensity.value - value) < 1e-9
                && abs(endpoints.view.controlFrames["thumb"]!.midX - (25.8 + 208.4 * value)) < 0.001
        }
        check(mapping, "E6 calibrated slider input and art agree at zero, midpoint, and one")
        endpoints.mouse(.leftMouseDown, at: CGPoint(x: -10, y: 28), in: endpoints.view.intensity)
        endpoints.mouse(.leftMouseUp, at: CGPoint(x: -10, y: 28), in: endpoints.view.intensity); endpoints.controller.flushPreviewFrame()
        let zero = endpoints.view.intensity.value == 0
        endpoints.mouse(.leftMouseDown, at: CGPoint(x: 250, y: 28), in: endpoints.view.intensity)
        endpoints.mouse(.leftMouseUp, at: CGPoint(x: 250, y: 28), in: endpoints.view.intensity); endpoints.controller.flushPreviewFrame()
        check(zero && endpoints.view.intensity.value == 1, "E6 slider input clamps beyond both ends")
        endpoints.controller.apply(.setIntensity(0, final: true)); endpoints.controller.flushPreviewFrame()
        check(endpoints.view.intensity.waveAmplitude == 0 && endpoints.view.intensity.thumbSize == CGSize(width: 12.2, height: 44.4),
              "E6 intensity zero draws a flat wave and the captured small rest thumb")
        endpoints.controller.apply(.setIntensity(1, final: true)); endpoints.controller.flushPreviewFrame()
        check(endpoints.view.intensity.waveAmplitude == 14.8 && abs(endpoints.view.intensity.thumbSize.width - 27.05) < 1e-9
              && abs(endpoints.view.intensity.thumbSize.height - 59.15) < 1e-9,
              "E6 intensity one draws 14.8 pt amplitude and the captured 27.05 by 59.15 rest thumb")
        endpoints.controller.close()
    }
    static func reviewedControls() throws {
        let scene = try EditorScene(), dial = scene.view.noise, slider = scene.view.intensity
        for target in [slider, dial] as [NSView] {
            let original = scene.space.theme, commits = scene.controller.commitCount
            scene.undo.removeAllActions()
            scene.scroll(target, y: 1, phase: 1)
            for _ in 0..<3 { scene.scroll(target, y: 1, phase: 2); scene.controller.flushPreviewFrame() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.18)); scene.controller.flushPreviewFrame()
            check(scene.controller.commitCount == commits && !scene.undo.canUndo,
                  "E6 \(target === slider ? "slider" : "dial") phased scroll previews without intermediate undo")
            scene.scroll(target, phase: 4)
            scene.scroll(target, y: 1, momentum: 1); scene.scroll(target, y: 1, momentum: 2)
            scene.scroll(target, momentum: 3); scene.controller.flushPreviewFrame()
            check(scene.controller.commitCount == commits + 1 && scene.undo.canUndo,
                  "E6 \(target === slider ? "slider" : "dial") momentum end commits exactly once")
            scene.undo.undo(); scene.controller.prepareForSnapshot()
            check(scene.space.theme == original && !scene.undo.canUndo, "E6 one undo restores the whole scroll gesture")
        }
        let commits = scene.controller.commitCount
        for _ in 0..<4 { scene.scroll(slider, y: -1); scene.controller.flushPreviewFrame() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); scene.controller.flushPreviewFrame()
        check(scene.controller.commitCount == commits + 1, "E6 phase-free wheel events coalesce until idle")
        let keyboardCommit = scene.controller.commitCount
        scene.scroll(dial, y: 1, phase: 1); scene.key(124, target: dial)
        check(scene.controller.commitCount == keyboardCommit + 2, "E6 keyboard input finishes a scroll before its own undo step")
        scene.controller.apply(.setNoise(0.98, final: true)); scene.controller.flushPreviewFrame()
        check(dial.hiddenDotIndices.isEmpty, "E6 non-wrapping slot distance hides no dot at noise 0.98")
        scene.controller.apply(.setNoise(1, final: true)); scene.controller.flushPreviewFrame()
        check(dial.hiddenDotIndices == [0], "E6 exact endpoint hides only coincident slot zero")
        scene.mouse(.leftMouseDown, at: dial.ringPoint(angle: 9), in: dial)
        scene.mouse(.leftMouseUp, at: dial.ringPoint(angle: 9), in: dial); scene.controller.flushPreviewFrame()
        check(abs(dial.value - 0.025) < 1e-9, "E6 between-dot click keeps its continuous angle rather than snapping")
        scene.mouse(.leftMouseDown, at: dial.ringPoint(angle: 18), in: dial)
        scene.mouse(.leftMouseUp, at: dial.ringPoint(angle: 18), in: dial); scene.controller.flushPreviewFrame()
        check(abs(dial.value - 0.05) < 1e-9 && dial.hiddenDotIndices == [1], "E6 inside-dot click snaps and hides only the nearest slot")
        scene.controller.apply(.setNoise(0, final: true)); scene.controller.flushPreviewFrame()
        let previews = dial.previewCompositionCount
        var quiet = scene.space.theme.style!
        for texture in SpaceStyleTexture.allCases {
            quiet.texture = texture; quiet.noiseFactor = 0
            scene.model.previewSpaceTheme(id: scene.space.id, theme: SpaceTheme(style: quiet)); scene.controller.prepareForSnapshot()
        }
        check(dial.previewCompositionCount == previews, "E6 external zero-noise texture changes skip preview composition")
        let fresh = try EditorScene()
        var freshQuiet = fresh.space.theme.style!
        for texture in SpaceStyleTexture.allCases {
            freshQuiet.texture = texture
            fresh.model.previewSpaceTheme(id: fresh.space.id, theme: SpaceTheme(style: freshQuiet)); fresh.controller.prepareForSnapshot()
        }
        check(fresh.view.noise.previewCompositionCount == 0, "E6 fresh zero-noise model changes compose nothing")
        fresh.click(fresh.view.noise.centerButton)
        check(fresh.view.noise.previewCompositionCount == 1 && fresh.view.noise.texture == .grain && fresh.view.noise.value == 0.8,
              "E6 center from none selects grain at 0.8 and composes once")
        let phaseEnd = fresh.controller.commitCount
        fresh.scroll(fresh.view.noise, y: 1, phase: 1); fresh.scroll(fresh.view.noise, phase: 4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12)); fresh.controller.flushPreviewFrame()
        check(fresh.controller.commitCount == phaseEnd + 1, "E6 phase end without momentum commits once after its grace interval")
        fresh.controller.close()
        let empty = try EditorScene(style: nil)
        check(empty.view.intensity.alphaValue == 1 && empty.view.noise.alphaValue == 1
              && !empty.view.intensity.isThumbVisible && !empty.view.noise.isTickVisible && empty.view.noise.litDotCount == 0,
              "E1 empty state has inactive wave, no thumb, no tick, and unlit dots")
        empty.controller.close()
        scene.panel.setFrameOrigin(CGPoint(x: -20000, y: -20000)); scene.panel.orderBack(nil)
        var nativePages = true
        for page in 0..<5 {
            scene.controller.apply(.setPresetPage(page)); OffscreenRenderer.settle(scene.view)
            scene.clickContent(CGPoint(x: 60, y: 380))
            nativePages = nativePages && scene.space.theme.style?.keyColor == SpaceStylePresets.all[page * 9].style.keyColor
            check(scene.space.theme.style?.keyColor == SpaceStylePresets.all[page * 9].style.keyColor,
                  "E4 native click selects page \(page + 1)'s visible swatch")
        }
        check(nativePages, "E4 panel.sendEvent hits a visible swatch after every page transition")
        scene.panel.orderOut(nil)
        let beforeClose = scene.controller.commitCount
        scene.scroll(slider, y: 1, phase: 1); scene.controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(scene.controller.commitCount == beforeClose + 1, "E6 close finishes one scroll and cancels its idle callback")
    }
    static func roundThreeControls() throws {
        var style = EditorScene.capturedStyle
        style.intensityFactor = 1; style.noiseFactor = 0.5; style.texture = .denim; style.appearance = .light
        let scene = try EditorScene(style: style, light: true), slider = scene.view.intensity, dial = scene.view.noise
        scene.panel.setFrameOrigin(CGPoint(x: -20000, y: -20000)); scene.panel.orderBack(nil)
        for point in [CGPoint(x: slider.thumbFrame.maxX - 0.5, y: 28), CGPoint(x: slider.thumbFrame.midX, y: -0.5)] {
            scene.panel.makeFirstResponder(scene.view.modes.buttons[0])
            scene.clickContent(CGPoint(x: slider.frame.minX + point.x, y: slider.frame.minY + point.y))
            check(scene.panel.firstResponder === slider && slider.value == 1,
                  "E6 panel.sendEvent routes the thumb overhang strip to the slider")
        }
        scene.mouse(.mouseMoved, at: CGPoint(x: slider.thumbFrame.midX, y: 28), in: slider)
        scene.mouse(.mouseMoved, at: CGPoint(x: slider.thumbFrame.maxX + 0.25, y: 28), in: slider)
        check(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || slider.displayedThumbFrame.width > slider.thumbFrame.width,
              "E6 hover remains active while the pointer is inside the grown thumb rim")
        var fixedShadow = true
        for noise in [0.0, 0.25, 0.5, 0.75] {
            scene.controller.apply(.setNoise(noise, final: true)); scene.controller.flushPreviewFrame()
            fixedShadow = fixedShadow && dial.tickLayerIsUnrotated && dial.tickShadowOffset == CGSize(width: 0, height: 2)
        }
        check(fixedShadow, "E6 tick rotates its path while its native shadow stays down at every angle")
        scene.controller.apply(.setNoise(0.25, final: true)); scene.controller.flushPreviewFrame()
        scene.mouse(.leftMouseDown, at: dial.ringPoint(angle: 90), in: dial)
        scene.mouse(.leftMouseDragged, at: dial.ringPoint(angle: 360 * 1e-8), in: dial)
        scene.mouse(.leftMouseUp, at: dial.ringPoint(angle: 360 * 1e-8), in: dial); scene.controller.flushPreviewFrame()
        check(scene.space.theme.style?.noiseFactor == 0, "E6 ring drag snaps epsilon noise to exact none")
        scene.click(dial.centerButton)
        check(scene.space.theme.style?.texture == .grain && scene.space.theme.style?.noiseFactor == 0.8,
              "E6 center after an epsilon-to-none drag restarts at grain")
        scene.panel.orderOut(nil); scene.controller.close()
        let empty = try EditorScene(style: nil), before = empty.space.theme
        check(empty.view.intensity.isAccessibilityEnabled() && empty.view.noise.isAccessibilityEnabled()
              && empty.view.noise.centerButton.isAccessibilityEnabled(), "E1 empty slider, dial, and Cycle-noise report AX enabled")
        _ = empty.view.intensity.accessibilityPerformIncrement(); _ = empty.view.noise.centerButton.accessibilityPerformPress()
        check(empty.space.theme == before, "E1 empty control actions preserve the unthemed Space")
        empty.controller.close()
    }

}
