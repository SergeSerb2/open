import AppKit
import OpenDesign
import OpenModel
import OpenSpaceEditor

/// Real editor/model/undo. Renders stay unordered; native-event probes order
/// only at (-20000,-20000), entirely outside every screen, then order out.
@MainActor
final class EditorScene {
    let model: BrowserModel
    let owner: NSWindow
    let controller: ThemeEditorController
    let undo: UndoManager
    var backdropOverride: RGBA?
    var view: ThemeEditorContentView { controller.panel.editorView }
    var panel: ThemeEditorPanel { controller.panel }
    var space: Space { model.spaces[0] }

    static var capturedStyle: SpaceStyle {
        // Session 1's stored extended-sRGB key. Its clipped swatch is #926400;
        // replacing the negative blue with zero changes the pad's hue and radius.
        SpaceStyle(keyColor: RGBAColor(red: 0.570741951, green: 0.392751396, blue: -0.130948484))
    }

    init(style: SpaceStyle? = capturedStyle, scale: CGFloat = 1, light: Bool = false, ownerUndo: Bool = false) throws {
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        model = try RenderCLI.fixtureModel()
        model.spaces[0].theme = style.map { SpaceTheme(style: $0) } ?? SpaceTheme()
        owner = EditorOwnerWindow(contentRect: CGRect(x: -20000, y: -20000, width: 900, height: 700),
                         styleMask: .borderless, backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        undo = ownerUndo ? owner.undoManager! : UndoManager()
        if !ownerUndo { undo.groupsByEvent = false }
        model.undoManager = undo
        controller = ThemeEditorController(model: model, spaceID: model.spaces[0].id, window: owner,
                                            anchor: .sidebarTrailingEdge(sidebarFrameInWindow: CGRect(x: 0, y: 0, width: 228, height: 700)))
        panel.renderScale = scale; panel.colorSpace = .sRGB
        panel.backdrop = RGBA(hex: light ? 0xFCFBFC : 0x2E3237)
        controller.show(); controller.prepareForSnapshot(); OffscreenRenderer.settle(view)
        // The captured editor has no keyboard focus ring. Checks focus controls explicitly.
        panel.makeFirstResponder(nil)
        undo.removeAllActions()
    }

    func click(_ button: ThemeEditorButton) {
        mouse(.leftMouseDown, at: CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        mouse(.leftMouseUp, at: CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
    }
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, in target: NSView) {
        let event = NSEvent.mouseEvent(with: type, location: target.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        switch type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .leftMouseUp: target.mouseUp(with: event)
        case .mouseMoved: target.mouseMoved(with: event)
        default: break
        }
    }
    func key(_ code: UInt16, target: NSResponder, flags: NSEvent.ModifierFlags = [], characters: String = "") {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        if flags.contains(.command) { _ = panel.performKeyEquivalent(with: event) }
        else {
            target.keyDown(with: event)
            sendKey(code, target: target, flags: flags, type: .keyUp)
            controller.flushPreviewFrame()
        }
    }
    func sendKey(_ code: UInt16, target: NSResponder, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: repeatKey, keyCode: code)!
        if type == .keyUp { target.keyUp(with: event) } else { target.keyDown(with: event) }
    }
    func clickContent(_ point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: view.content.convert(point, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            panel.sendEvent(event)
        }
        controller.flushPreviewFrame()
    }
    func snapshot() -> CGImage {
        controller.prepareForSnapshot()
        let light = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        panel.backdrop = backdropOverride ?? RGBA(hex: light ? 0xFCFBFC : 0x2E3237)
        OffscreenRenderer.settle(view)
        return OffscreenRenderer().snapshot(view, scale: panel.renderScale ?? 1)
    }
    static func render(_ args: [String]) throws {
        guard let output = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let scale = Double(RenderCLI.value(args, "--scale") ?? "1") ?? 0
        guard [1.0, 2.0].contains(scale) else { throw CLIError(description: "invalid editor scale") }
        let style = try RenderCLI.value(args, "--style").map { try JSONDecoder().decode(SpaceStyle.self, from: Data($0.utf8)) }
        let scene = try EditorScene(style: args.contains("--empty") ? nil : style ?? capturedStyle,
                                    scale: scale, light: RenderCLI.value(args, "--appearance") == "light")
        if let hex = RenderCLI.value(args, "--backdrop"), let color = UInt32(hex, radix: 16) { scene.backdropOverride = RGBA(hex: color) }
        if let page = RenderCLI.value(args, "--page").flatMap(Int.init) { scene.controller.apply(.setPresetPage(page)) }
        let buttons = ["automatic": scene.view.modes.buttons[0], "light": scene.view.modes.buttons[1],
                       "dark": scene.view.modes.buttons[2], "remove": scene.view.remove, "add": scene.view.add]
        if let name = RenderCLI.value(args, "--hover"), let button = buttons[name] { button.forcedHover = true }
        if let name = RenderCLI.value(args, "--pressed"), let button = buttons[name] {
            scene.mouse(.leftMouseDown, at: CGPoint(x: 16, y: 16), in: button)
        }
        if let name = RenderCLI.value(args, "--focus") {
            scene.panel.makeFirstResponder(name == "pad" ? scene.view.pad : buttons[name])
        }
        if RenderCLI.value(args, "--hover") == "knob", let point = scene.view.pad.primaryKnobCenter {
            scene.mouse(.mouseMoved, at: point, in: scene.view.pad)
        }
        let image = scene.snapshot()
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: output))
        print("editor rendered \(image.width)x\(image.height)")
        scene.controller.close()
    }
}

@MainActor private final class EditorOwnerWindow: NSWindow {
    private let eventUndo = UndoManager()
    override var undoManager: UndoManager? { eventUndo }
}
