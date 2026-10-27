import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenSpaceEditor
import OpenFeatures
import OpenStore
import Darwin

/// End-to-end scenes use the real editor, model, sidebar and window controller.
/// No web tab is selected: these gates exercise browser chrome, not page hosts.
@MainActor
enum LiveThemeChecks {
    static func check(_ value: Bool, _ name: String) { Checks.check(value, name) }
    static func run() throws {
        try propagation(); try closing(); try persistence(); try bench()
    }
    static func propagation() throws {
        let editor = try EditorScene(style: SpaceStylePresets.all[7].style)
        let model = editor.model
        let suite = "open-theme-live-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); editor.controller.close() }
        var scenes: [RenderScene] = [], owners: [NSWindow] = []
        for i in 0..<3 {
            let space = model.spaces[i == 2 ? 1 : 0]
            let window = model.createWindow(focusedSpaceID: space.id)!
            let context = SidebarContext(model: model, windowID: window.id, previewPreferences: preferences)
            context.systemAppearance = .dark
            var options = RenderScene.Options(); options.size = CGSize(width: 900, height: 700)
            let scene = RenderScene(context: context, options: options, delegate: RecordingDelegate())
            let owner = OffscreenRenderer.host(scene, scale: 1)
            scenes.append(scene); owners.append(owner)
        }
        defer { for owner in owners { owner.contentView = nil; owner.close() } }
        // Drain setup observation before measuring this display tick.
        for scene in scenes { OffscreenRenderer.settle(scene, runLoop: 0.002) }
        let renderer = OffscreenRenderer()
        let before = scenes.map { Bitmap(image: renderer.snapshot($0, scale: 1), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        let rebuilds = scenes.map { $0.background.fieldRebuildCount }
        let animations = scenes.map { $0.background.animatedThemeChangeCount }
        editor.undo.removeAllActions()
        editor.controller.apply(.dragKnob(to: CGPoint(x: -0.5, y: -0.2), relative: false))
        editor.controller.flushPreviewFrame()
        let style = SpaceThemeStyle(theme: editor.space.theme, system: .dark)
        check(scenes[0].background.targetStyle == style && scenes[1].background.targetStyle == style
              && scenes[2].background.fieldRebuildCount == rebuilds[2],
              "E7 both same-Space backgrounds update synchronously in one editor frame; other Space stays unchanged")
        check(scenes.prefix(2).allSatisfy { !$0.background.isCrossfading }
              && zip(scenes, animations).allSatisfy { $0.background.animatedThemeChangeCount == $1 },
              "E7 a live drag adds no cross-fade to any window")
        check(scenes.prefix(2).allSatisfy { $0.sidebar.context.livePreviewSpaces.contains(editor.space.id) },
              "E7 the shared live preview lease reaches both sidebar contexts")
        let after = scenes.map { scene -> Bitmap in
            scene.displayIfNeeded(); return Bitmap(image: renderer.snapshot(scene, scale: 1), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let changedTitles = (0..<2).allSatisfy { i in
            guard let rect = scenes[i].sidebar.chromeGeometry.headerTitle,
                  let a = before[i].ink(rect).1, let b = after[i].ink(rect).1 else { return false }
            return zip(a, b).contains { abs($0 - $1) > 1 }
        }
        check(changedTitles, "E7 real sidebar title core pixels change in both same-Space window renders")
        check(before[2].data == after[2].data, "E7 the other-Space render remains pixel-identical")
        editor.controller.apply(.endDrag); editor.controller.flushPreviewFrame()
        check(editor.controller.commitCount == 1 && !ThemePreviewRegistry.shared.livePreviewSpaces.contains(editor.space.id),
              "E7 a drag commits once and releases its live preview lease")
        SidebarDiagnostics.forceAnimations = true
        defer { SidebarDiagnostics.forceAnimations = false }
        let counts = scenes.map { $0.background.animatedThemeChangeCount }
        editor.controller.apply(.selectPreset(index: 4))
        check((0..<2).allSatisfy { scenes[$0].background.animatedThemeChangeCount == counts[$0] + 1 }
              && scenes[2].background.animatedThemeChangeCount == counts[2],
              "E7 one preset click adds exactly one discrete cross-fade per same-Space window")
    }
    static func closing() throws {
        do {
            let scene = try EditorScene()
            let original = scene.space.theme
            scene.controller.apply(.dragKnob(to: CGPoint(x: 0.3, y: -0.4), relative: false))
            scene.key(53, target: scene.panel)
            check(scene.controller.isClosed && scene.space.theme != original && scene.controller.commitCount == 1,
                  "E8 Esc mid-drag flushes the pending frame and commits once before close")
            scene.undo.undo()
            check(scene.space.theme == original, "E8 Esc's mid-drag commit undoes in one step")
            scene.controller.close()
        }
        do {
            let scene = try EditorScene()
            var closes = 0
            scene.controller.onClose = { closes += 1 }
            scene.controller.onCommit = { [weak controller = scene.controller] in controller?.close() }
            scene.controller.apply(.dragKnob(to: CGPoint(x: 0.3, y: -0.4), relative: false))
            scene.controller.close(); scene.controller.close()
            check(scene.controller.isClosed && closes == 1 && scene.controller.commitCount == 1,
                  "E8 close during a commit callback and repeated close notify once")
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification, NSWindow.willCloseNotification] {
            let scene = try EditorScene()
            NotificationCenter.default.post(name: name, object: name == NSWindow.willCloseNotification ? scene.owner : nil)
            check(scene.controller.isClosed, "E8 \(name.rawValue) closes the editor")
        }
        do {
            let scene = try EditorScene()
            let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                            windowNumber: scene.owner.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(outside, atStart: true)
            if let next = NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
            check(scene.controller.isClosed, "E8 native dequeue of an outside mouse down closes the editor")
        }
        let model = try RenderCLI.fixtureModel()
        let manager = UndoManager(); manager.groupsByEvent = false; model.undoManager = manager
        let state = model.windows[0]; state.selectedNodeBySpace = [:]
        let factory = UnselectedPageFactory()
        let domain = "open-theme-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let window = BrowserWindowController(model: model, windowID: state.id, factory: factory, defaults: defaults)
        window.window?.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        defer { window.closeThemeEditor(); window.window?.close() }
        window.performCommand("edit-theme")
        let first = window.themeEditor
        check(first != nil && window.isCommandEnabled("edit-theme", enabledKey: "always"), "E8 edit-theme command opens the focused Space editor")
        check(window.sidebar(window.sidebar, didRequest: .editSpaceTheme(model.spaces[1].id))
              && first?.isClosed == true && state.focusedSpaceID == model.spaces[1].id,
              "E8 context-menu entry focuses its Space and replaces the previous editor")
        let switched = window.themeEditor!
        model.focusSpace(windowID: state.id, spaceID: model.spaces[0].id)
        OffscreenRenderer.settle(window.contentView, runLoop: 0.003)
        check(switched.isClosed && window.themeEditor == nil, "E8 Space switch closes the editor")
        window.performCommand("edit-theme")
        let deleted = window.themeEditor!
        model.deleteSpace(id: state.focusedSpaceID)
        OffscreenRenderer.settle(window.contentView, runLoop: 0.003)
        check(deleted.isClosed && window.themeEditor == nil, "E8 Space deletion closes the editor")
        window.performCommand("edit-theme")
        let closing = window.themeEditor!
        window.window?.close()
        check(closing.isClosed && window.themeEditor == nil, "E8 owner window close closes the editor")
        check(factory.requests == 0, "E8 chrome-only scenes never request a web host")
    }
    static func persistence() throws {
        let model = try RenderCLI.fixtureModel()
        model.windows[0].selectedNodeBySpace = [:]
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-session-\(UUID().uuidString)")
        let store = SnapshotStore(root: root)
        defer { store.flush(); try? FileManager.default.removeItem(at: root) }
        var window: BrowserWindowController? = BrowserWindowController(model: model, windowID: model.windows[0].id,
                                                                      factory: UnselectedPageFactory(), snapshotStore: store)
        window?.window?.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window?.performCommand("edit-theme")
        let editor = window!.themeEditor!
        let original = model.spaces[0].theme
        let count = store.scheduleCount
        for i in 0..<4 {
            editor.apply(.dragKnob(to: CGPoint(x: 0.4 + Double(i) * 0.02, y: 0.1), relative: false))
            editor.flushPreviewFrame()
        }
        check(store.scheduleCount == count && !undo.canUndo, "E7 previews schedule no save and register no undo")
        editor.apply(.endDrag); editor.flushPreviewFrame()
        let edited = model.spaces[0].theme
        check(store.scheduleCount == count + 1 && undo.undoActionName == "Update Theme", "E7 gesture end schedules one save and names its single undo step")
        window?.window?.close(); window = nil
        undo.undo()
        check(model.spaces[0].theme == original && store.scheduleCount == count + 2 && !undo.canUndo,
              "E7 undo after the owning window closes restores the full theme and schedules a save")
        undo.redo()
        try store.saveNow(model: model)
        check(try store.load()?.spaces[0].theme == edited && store.scheduleCount == count + 3,
              "E7 redo after owner close saves and round-trips the committed editor theme")
    }
    static func bench() throws {
        let editor = try EditorScene(style: SpaceStyle(keyColor: SpaceStylePresets.all[7].style.keyColor, colorCount: 3, noiseFactor: 0.5))
        defer { editor.controller.close() }
        var scenes: [RenderScene] = [], owners: [NSWindow] = []
        for _ in 0..<2 {
            let state = editor.model.createWindow(focusedSpaceID: editor.space.id)!
            let context = SidebarContext(model: editor.model, windowID: state.id)
            context.systemAppearance = .dark
            var options = RenderScene.Options(); options.size = CGSize(width: 1280, height: 900)
            let scene = RenderScene(context: context, options: options, delegate: RecordingDelegate())
            owners.append(OffscreenRenderer.host(scene, scale: 2)); scenes.append(scene)
        }
        defer { for owner in owners { owner.contentView = nil; owner.close() } }
        scenes.forEach { OffscreenRenderer.settle($0, runLoop: 0.002) }
        let tiles = ThemeTexture.generationCount
        let layouts = editor.view.layoutPassCount
        func threadMilliseconds() -> Double {
            var time = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
        }
        var times: [Double] = [], walls: [Double] = [], maximumRebuilds = 0
        let initialRebuilds = scenes.map { $0.background.fieldRebuildCount }
        for tick in 0..<240 {
            let before = scenes.map { $0.background.fieldRebuildCount }
            let started = threadMilliseconds(), wallStart = ProcessInfo.processInfo.systemUptime
            let angle = Double(tick) * .pi / 120
            editor.controller.apply(.dragKnob(to: CGPoint(x: cos(angle) * 0.5, y: sin(angle) * 0.5), relative: false))
            editor.controller.flushPreviewFrame()
            // Paint invalidated rows in this frame as well as rebuilding the field.
            for scene in scenes { scene.layoutSubtreeIfNeeded(); scene.displayIfNeeded() }
            times.append(threadMilliseconds() - started)
            walls.append((ProcessInfo.processInfo.systemUptime - wallStart) * 1000)
            for (i, scene) in scenes.enumerated() { maximumRebuilds = max(maximumRebuilds, scene.background.fieldRebuildCount - before[i]) }
        }
        let p95 = times.sorted()[Int(Double(times.count - 1) * 0.95)]
        print(String(format: "B1 wall p95 %.3f ms (informational); load %@", walls.sorted()[227], ProcessInfo.processInfo.environment["OPEN_LOAD_NOTE"] ?? "see uptime"))
        check(p95 <= 4, String(format: "B1 240 ticks, two same-Space windows: main-thread p95 %.3f ms <= 4 ms", p95))
        check(zip(scenes, initialRebuilds).allSatisfy { $0.background.fieldRebuildCount - $1 == 240 },
              "B1 both windows rebuild on every one of the 240 display ticks")
        check(maximumRebuilds <= 1, "B1 field rebuilds <= 1 per editor frame per window")
        check(ThemeTexture.generationCount == tiles, "B1 zero texture generations after warm-up")
        check(editor.view.layoutPassCount == layouts, "B1 no editor layout during 240 drag frames")
        editor.controller.apply(.endDrag); editor.controller.flushPreviewFrame(); editor.controller.close()
        let writes = editor.controller.previewCount
        editor.controller.apply(.dragKnob(to: .zero, relative: false)); editor.controller.flushPreviewFrame()
        check(editor.controller.previewCount == writes && !ThemePreviewRegistry.shared.livePreviewSpaces.contains(editor.space.id),
              "B1 a closed editor produces no preview work or retained live lease")
    }
}

@MainActor private final class UnselectedPageFactory: WebContentHostFactory {
    private(set) var requests = 0
    func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)? {
        requests += 1; return nil
    }
}
