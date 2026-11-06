import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenSpaceEditor
import OpenStore

/// Exercises the shipped page, controller, model and native field editor together.
@MainActor
final class CreationScene: NSObject, NSWindowDelegate {
    let model: BrowserModel
    let undo = UndoManager()
    let controller: SpaceCreationController
    let scene: RenderScene
    let window: NSWindow
    init(width: CGFloat = 228, height: CGFloat = 700, light: Bool = false, options: SpaceCreationOptions = .init(), prepare: ((BrowserModel) -> SpaceCreationOptions)? = nil) throws {
        model = try RenderCLI.fixtureModel(); undo.groupsByEvent = false; model.undoManager = undo
        let context = try RenderCLI.context(model, args: ["--width", String(Double(width)), "--appearance", light ? "light" : "dark"])
        var sceneOptions = RenderScene.Options(); sceneOptions.size = CGSize(width: width, height: height)
        scene = RenderScene(context: context, options: sceneOptions, delegate: RecordingDelegate())
        scene.panelHost.removeFromSuperview() // The create command renders the sidebar column only.
        let resolvedOptions = prepare?(model) ?? options
        undo.removeAllActions()
        controller = SpaceCreationController(model: model, windowID: model.windows[0].id, options: resolvedOptions)
        controller.creationView.systemAppearance = light ? .light : .dark
        window = OffscreenRenderer.host(scene, scale: 1)
        super.init()
        window.delegate = self
        scene.sidebar.beginSpaceCreation(page: controller.view)
        controller.onDraftStyle = { [weak scene] in scene?.sidebar.previewSpaceCreation($0) }
        controller.onFinish = { [weak scene] in scene?.sidebar.endSpaceCreation(focus: $0?.id) }
        controller.updatePreview(); OffscreenRenderer.settle(scene); controller.focus()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { controller.localUndoManager }
    func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    func edit(_ action: String) {
        // Offscreen windows have no key-window menu target. Exercise the native
        // field editor action here; App A5 covers the full key/menu route.
        _ = window.firstResponder?.tryToPerform(NSSelectorFromString(action), with: nil)
    }
    func close() { if !controller.isFinished { controller.cancel() }; window.contentView = nil; window.close() }
}

@MainActor enum CreationChecks {
    static func render(_ args: [String]) throws {
        guard let output = RenderCLI.value(args, "--out"),
              let width = Double(RenderCLI.value(args, "--width") ?? "228"), [180, 200, 228, 300, 500].contains(width) else { throw CLIError(description: RenderCLI.usage) }
        let scene = try CreationScene(width: width, light: RenderCLI.value(args, "--appearance") == "light")
        defer { scene.close() }
        scene.window.makeFirstResponder(nil)
        OffscreenRenderer.settle(scene.scene)
        OffscreenRenderer.writePNG(OffscreenRenderer().snapshot(scene.scene, scale: 1), to: URL(fileURLWithPath: output))
        print("create rendered width=\(width)")
    }
    static func run() throws {
        for light in [false, true] {
            for width: CGFloat in [180, 200, 228, 300, 500] {
                let scene = try CreationScene(width: width, light: light); defer { scene.close() }
                let form = scene.controller.creationView, frames = form.cardFrames
                let expected: SpaceCreationView.WidthClass = width < 190 ? .compact : width < 227 ? .medium : .full
                let gap: CGFloat = width < 227 ? 6 : 8
                let inset: CGFloat = width < 227 ? 6 : 8
                Checks.check(form.widthClass == expected && frames["name"]?.minX == inset && frames["name"]?.maxX == width - inset
                    && frames["name"]?.width == width - 2 * inset
                    && frames["name"]?.height == 44 && frames["theme"]?.minY == (frames["name"]!.maxY + gap)
                    && frames["profile"]?.minY == (frames["theme"]!.maxY + gap)
                    && form.profileInfo.isHidden == (width < 190) && !form.submitIsPinned
                    && form.scroll.scrollerStyle == .overlay && !form.scroll.hasVerticalScroller
                    && form.scroll.contentView.bounds.width == width,
                    "C1 geometry width=\(width) light=\(light)")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let snapshot = try encoder.encode(SnapshotMapper.dto(from: scene.model))
                scene.key(53, characters: "\u{1b}")
                let after = try encoder.encode(SnapshotMapper.dto(from: scene.model))
                Checks.check(scene.controller.isFinished && !scene.undo.canUndo && snapshot == after,
                             "C1 native Escape cancels without mutation or undo width=\(width) light=\(light)")
            }
        }
        let small = try CreationScene(height: 350); defer { small.close() }
        Checks.check(small.controller.creationView.submitIsPinned && small.controller.creationView.scroll.documentView!.bounds.height > small.controller.creationView.scroll.bounds.height,
                     "C1 short page pins submit and scrolls the cards")
        let editing = try CreationScene(); defer { editing.close() }
        editing.controller.openThemeEditor()
        guard let themeEditor = editing.controller.themeEditor else { throw CLIError(description: "C1 draft editor did not open") }
        themeEditor.apply(.selectPreset(index: 2)); themeEditor.flushPreviewFrame(); themeEditor.close()
        let typingTheme = editing.controller.draftStyle
        // Separate user input events, as the App's automation socket does.
        OffscreenRenderer.settle(editing.scene, runLoop: 0.01)
        editing.controller.focus()
        guard let fieldEditor = editing.controller.creationView.nameField.currentEditor() as? NSTextView else {
            throw CLIError(description: "C1 Name field has no native editor")
        }
        Checks.check(fieldEditor.allowsUndo && fieldEditor.undoManager !== editing.controller.localUndoManager,
                     "C1 native Name typing history is separate from the draft undo manager")
        fieldEditor.insertText("abc", replacementRange: fieldEditor.selectedRange())
        OffscreenRenderer.settle(editing.scene, runLoop: 0.01)
        editing.edit("undo:")
        Checks.check(editing.controller.creationView.nameField.stringValue.isEmpty && editing.controller.draftStyle == typingTheme,
                     "C1 typing undo precedes the earlier theme edit")
        editing.edit("redo:")
        Checks.check(editing.controller.creationView.nameField.stringValue == "abc" && editing.controller.draftStyle == typingTheme,
                     "C1 native redo restores typing before theme undo")
        editing.edit("undo:"); editing.edit("undo:")
        Checks.check(editing.controller.creationView.nameField.stringValue.isEmpty && editing.controller.draftStyle == nil,
                     "C1 native Undo falls back from typing to theme")
        editing.edit("redo:"); editing.edit("redo:")
        Checks.check(editing.controller.creationView.nameField.stringValue == "abc" && editing.controller.draftStyle == typingTheme,
                     "C1 native Redo restores draft then field typing")
        let scene = try CreationScene(); defer { scene.close() }
        let oldCount = scene.model.spaces.count, previous = scene.model.windows[0].focusedSpaceID
        scene.controller.creationView.nameField.stringValue = "Created in the form"
        scene.controller.setDraftIcon(.emoji("🌿"))
        scene.controller.setDraftStyle(SpaceStylePresets.all[2].style)
        scene.key(36, characters: "\r")
        let created = scene.model.spaces.last!
        Checks.check(scene.model.spaces.count == oldCount + 1 && created.title == "Created in the form" && created.icon == .emoji("🌿")
                     && created.theme.style == SpaceStylePresets.all[2].style && created.profileID == scene.controller.profilePicker.selectedProfileID
                     && scene.model.windows[0].focusedSpaceID == created.id && scene.undo.undoActionName == "New Space", "C1 native Return creates title icon style Profile focus in one named step")
        scene.undo.undo()
        Checks.check(scene.model.spaces.count == oldCount && scene.model.windows[0].focusedSpaceID == previous && !scene.undo.canUndo,
                     "C1 undo removes Space and returns to previous focus")
        // Real tab/folder moves are driven through the same creation surface.
        for placement in [BrowserModel.SpaceCreationPlacement.preserveSection, .today] {
            let fixture = try RenderCLI.fixtureModel(), source = fixture.spaces[0]
            let a = fixture.newTab(in: source.id, url: URL(string: "https://example.invalid/pinned")!)
            let b = fixture.newTab(in: source.id, url: URL(string: "https://example.invalid/today")!)
            _ = fixture.moveNode(id: a.id, to: .spacePinned(source.id), at: nil)
            let undo = UndoManager(); undo.groupsByEvent = false; fixture.undoManager = undo
            let controller = SpaceCreationController(model: fixture, windowID: fixture.windows[0].id,
                options: .init(moving: [a.id, b.id], placement: placement))
            controller.submit()
            let moved = fixture.spaces.last!
            Checks.check(moved.today.map(\.id) == (placement == .today ? [a.id, b.id] : [b.id])
                         && moved.pinned.map(\.id) == (placement == .today ? [] : [a.id]), "C1 creation move placement \(placement)")
            undo.undo()
            Checks.check(fixture.parentByID[a.id] == .spacePinned(source.id) && fixture.parentByID[b.id] == .spaceToday(source.id) && !undo.canUndo,
                         "C1 move restores both sections in one undo \(placement)")
        }
        let folderScene = try CreationScene(prepare: { model in
            let source = model.spaces[0]
            let a = model.newTab(in: source.id, url: URL(string: "https://example.invalid/a")!)
            let b = model.newTab(in: source.id, url: URL(string: "https://example.invalid/b")!)
            let folder = model.createFolder(in: .spacePinned(source.id), title: "Folder Space", withNodes: [a.id, b.id])!
            return .init(moving: [a.id, b.id], prefillTitle: folder.title, placement: .today, removingEmptyFolder: folder.id)
        })
        defer { folderScene.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(SnapshotMapper.dto(from: folderScene.model))
        let moving = folderScene.controller.options.moving
        let folder = folderScene.controller.options.removingEmptyFolder!
        folderScene.key(36, characters: "\r")
        Checks.check(folderScene.model.node(id: folder) == nil && folderScene.model.spaces.last?.today.map(\.id) == moving
            && folderScene.model.spaces.last?.pinned.isEmpty == true, "C1 Turn into Space removes the empty folder and preserves ordered Today children")
        folderScene.undo.undo()
        let after = try encoder.encode(SnapshotMapper.dto(from: folderScene.model))
        Checks.check(before == after && !folderScene.undo.canUndo, "C1 folder conversion one undo restores exact snapshot")
        folderScene.undo.redo()
        Checks.check(folderScene.model.spaces.last?.today.map(\.id) == moving && folderScene.model.node(id: folder) == nil,
                     "C1 folder conversion redo replays the transaction")
        let refused = try CreationScene(options: .init(moving: [ItemID()]))
        defer { refused.close() }
        let refusedBefore = try encoder.encode(SnapshotMapper.dto(from: refused.model))
        refused.controller.profilePicker.isCreatingProfile = true
        refused.controller.creationView.profileNameField.stringValue = "Must not be created"
        refused.key(36, characters: "\r")
        let refusedAfter = try encoder.encode(SnapshotMapper.dto(from: refused.model))
        Checks.check(refusedBefore == refusedAfter && !refused.undo.canUndo && !refused.controller.isFinished,
                     "C1 missing move refuses Space and inline Profile without mutation or undo")
        #if DEBUG
        let rollback = try CreationScene(prepare: { model in
            let source = model.spaces[0]
            let a = model.newTab(in: source.id, url: URL(string: "https://example.invalid/a")!)
            let b = model.newTab(in: source.id, url: URL(string: "https://example.invalid/b")!)
            return .init(moving: [a.id, b.id])
        })
        defer { rollback.close() }
        let rollbackBefore = try encoder.encode(SnapshotMapper.dto(from: rollback.model))
        let generation = rollback.model.undoGeneration, revision = rollback.model.treeRevision
        var announcedProfiles = 0, changes = 0
        rollback.model.onProfileCreated = { _ in announcedProfiles += 1 }
        let observation = rollback.model.addObserver { _ in changes += 1 }
        defer { rollback.model.removeObserver(observation) }
        rollback.controller.profilePicker.isCreatingProfile = true
        rollback.controller.creationView.profileNameField.stringValue = "Rolled back Profile"
        rollback.model.diagnosticRollbackFailureAtMove = 1
        rollback.controller.submit()
        rollback.model.diagnosticRollbackFailureAtMove = nil
        let rollbackAfter = try encoder.encode(SnapshotMapper.dto(from: rollback.model))
        Checks.check(rollbackBefore == rollbackAfter && announcedProfiles == 0 && changes == 0
            && rollback.model.undoGeneration == generation && rollback.model.treeRevision == revision
            && !rollback.undo.canUndo && !rollback.controller.isFinished,
            "C1 late move refusal never announces an inline Profile or changes snapshot events revision undo")
        #endif
        let inline = try CreationScene(); defer { inline.close() }
        let profileCount = inline.model.profiles.count, spaceCount = inline.model.spaces.count
        inline.controller.profilePicker.isCreatingProfile = true
        inline.controller.creationView.profileNameField.stringValue = "Inline Profile"
        inline.key(36, characters: "\r")
        Checks.check(inline.model.profiles.count == profileCount + 1 && inline.model.spaces.count == spaceCount + 1,
                     "C1 inline Profile and Space create together")
        inline.undo.undo()
        Checks.check(inline.model.profiles.count == profileCount && inline.model.spaces.count == spaceCount && !inline.undo.canUndo,
                     "C1 one undo removes inline Profile and Space")
    }
}
