import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenStore
import OpenSuggest

struct CLIError: Error, CustomStringConvertible { var description: String }

/// Runs the main run loop until `done` is true or `timeout` passes. Main-actor tasks
/// (the bar's snapshot consumer, history queries) run inside it.
@MainActor
@discardableResult
func spin(until done: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() > end { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// Runs an async operation to completion from synchronous main-thread code.
@MainActor
func blocking<T: Sendable>(_ op: @escaping @MainActor () async -> T) -> T {
    var result: T?
    Task { @MainActor in result = await op() }
    spin(until: { result != nil }, timeout: 600)
    return result!
}

@MainActor
func blockingThrowing<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) throws -> T {
    let result: Result<T, Error> = blocking {
        do { return .success(try await op()) } catch { return .failure(error) }
    }
    return try result.get()
}

/// Records every intent and presentation change.
@MainActor
final class IntentRecorder: CommandBarDelegate {
    var intents: [CommandBarIntent] = []
    var presentations: [(Bool, CommandBarMode)] = []
    var noticeDismissals = 0
    /// What the delegate grants after a notice dismissal (the App: the Profile's suggestion setting).
    var allowsRemoteAfterDismissal: Bool?
    func commandBar(_ commandBar: CommandBarController, perform intent: CommandBarIntent) { intents.append(intent) }
    func commandBarDidDismissPrivacyNotice(_ commandBar: CommandBarController) {
        noticeDismissals += 1
        if let allowed = allowsRemoteAfterDismissal { commandBar.setAllowsRemoteSuggestions(allowed) }
    }
    func commandBar(_ commandBar: CommandBarController, didChangePresentation isPresented: Bool, mode: CommandBarMode) {
        presentations.append((isPresented, mode))
    }
}

/// A window-sized scene: a backdrop (a page color or a captured frame) and the real
/// overlay on top, in an offscreen window at the requested scale.
@MainActor
final class Stage {
    let window: ScaledWindow
    let root: StageRoot
    let controller: CommandBarController
    let recorder = IntentRecorder()
    /// New extension-scope scenes: AppKit draws the query correctly through cacheDisplay,
    /// but a plain copy of its private text backing store can lose the glyphs.
    var capturesNativeField = false

    func nativeFieldSnapshot() -> NativeLayerSnapshot? {
        guard let editor = fieldEditor, let layer = editor.layer,
              let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else { return nil }
        editor.cacheDisplay(in: editor.bounds, to: rep)
        return rep.cgImage.map { NativeLayerSnapshot(layer: layer, image: $0) }
    }

    init(size: CGSize, scale: CGFloat, engine: SuggestEngine, backdrop: CommandBarBackdrop, beforeAttach: ((CommandBarController) -> Void)? = nil) {
        root = StageRoot(frame: CGRect(origin: .zero, size: size))
        root.backdrop = backdrop
        controller = CommandBarController(engine: engine)
        controller.delegate = recorder
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        beforeAttach?(controller)
        root.addSubview(controller.view)
        window = OffscreenRenderer.host(root, scale: scale)
        controller.backdrop = backdrop
    }

    /// Waits until the bar applied a final snapshot for its current text.
    func settle(timeout: TimeInterval = 5) {
        let c = controller
        spin(until: { c.appliedQuery == c.text && c.appliedSequence >= 0 && c.isSnapshotFinal }, timeout: timeout)
        OffscreenRenderer.settle(root)
    }

    var fieldEditor: NSTextView? { window.firstResponder as? NSTextView }

    /// Types `text` through the field editor (the same path as the keyboard: NSTextView
    /// insertText → NSTextField delegate → controller).
    func type(_ text: String, settleEach: Bool = false) {
        for ch in text {
            guard let editor = window.firstResponder as? NSTextView else { return }
            editor.insertText(String(ch), replacementRange: editor.selectedRange())
            if settleEach { settle() }
        }
    }

    /// Sends a key event through the window, like the keyboard does.
    func key(_ key: Key, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { return }
        window.sendEvent(event)
    }

    enum Key {
        case up, down, returnKey, escape, tab, backspace, space, info, left, right, home, end, forwardDelete
        var code: UInt16 {
            switch self {
            case .up: 126
            case .down: 125
            case .returnKey: 36
            case .escape: 53
            case .tab: 48
            case .backspace: 51
            case .space: 49
            case .info: 34
            case .left: 123
            case .right: 124
            case .home: 115
            case .end: 119
            case .forwardDelete: 117
            }
        }
        var characters: String {
            switch self {
            case .up: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .returnKey: "\r"
            case .escape: "\u{1B}"
            case .tab: "\t"
            case .backspace: "\u{7F}"
            case .space: " "
            case .info: "i"
            case .left: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .right: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .home: String(Character(UnicodeScalar(NSHomeFunctionKey)!))
            case .end: String(Character(UnicodeScalar(NSEndFunctionKey)!))
            case .forwardDelete: String(Character(UnicodeScalar(NSDeleteFunctionKey)!))
            }
        }
    }

    /// Mouse event at a window point (top-left origin), delivered like a real click.
    func mouse(_ type: NSEvent.EventType, at p: CGPoint) {
        let windowPoint = NSPoint(x: p.x, y: root.bounds.height - p.y)
        guard let e = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // A window that is never shown gets no events from the window server, and AppKit's own
        // dispatch skips it; deliver to the hit-tested view as AppKit would (mouse-up goes to
        // the view that took the mouse-down).
        switch type {
        case .mouseMoved: root.hitTest(windowPoint)?.mouseMoved(with: e)
        case .leftMouseDown:
            pressed = root.hitTest(windowPoint)
            pressed?.mouseDown(with: e)
        case .leftMouseUp:
            pressed?.mouseUp(with: e)
            pressed = nil
        default: window.sendEvent(e)
        }
    }
    private var pressed: NSView?

    /// Renders the stage. The window is never on screen, so AppKit may mark its backing stores
    /// purgeable, and under memory pressure (a Chromium build) a store can be dropped before the
    /// renderer reads it. So: redraw every view right before the snapshot, check the result
    /// (the page corner and the panel fill must look like a page and a panel), and retry.
    func render(scale: CGFloat) -> CGImage {
        let nativeField = capturesNativeField ? nativeFieldSnapshot() : nil
        var image = OffscreenRenderer().snapshot(root, scale: scale, nativeLayer: nativeField)
        for _ in 0..<5 {
            func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
            mark(root)
            OffscreenRenderer.settle(root)
            image = OffscreenRenderer().snapshot(root, scale: scale, nativeLayer: nativeField)
            if looksValid(image, scale: scale) { return image }
            FileHandle.standardError.write(Data("commandbar-render: render did not validate; retrying\n".utf8))
        }
        FileHandle.standardError.write(Data("commandbar-render: render did not validate after retries\n".utf8))
        return image
    }

    private func looksValid(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
        func px(_ x: CGFloat, _ y: CGFloat) -> [Double] {
            let i = Int(y * scale) * image.bytesPerRow + Int(x * scale) * 4
            return [Double(ptr[i]), Double(ptr[i + 1]), Double(ptr[i + 2])]
        }
        // Page corners: the flat backdrop color (image backdrops: any non-garbage pixel). The bottom
        // corners too: an incomplete read-back leaves the lower part of the image unwritten (item 13).
        let embedded: Bool
        if case .embedded = controller.view.presentation { embedded = true } else { embedded = false }
        if root.backdrop.image == nil, root.bottomColor == nil, !embedded {
            let c = root.backdrop.color
            let expected = [c.red * 255, c.green * 255, c.blue * 255]
            let h = CGFloat(image.height) / scale - 4, w = CGFloat(image.width) / scale - 4
            for corner in [px(4, 4), px(4, h), px(w, h)] where zip(corner, expected).contains(where: { abs($0 - $1) > 3 }) { return false }
        }
        guard controller.isPresented else { return true }
        // Panel fill in the input row's empty middle: a dark, opaque-looking material.
        let p = controller.view.panelFrame
        func luma(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
        guard (8..<120).contains(luma(px(p.minX + 300, p.minY + 6))) else { return false }
        // Drawn content: light pixels (icon, text) in the input row's leading part and in row 1.
        func hasInk(_ r: CGRect) -> Bool {
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX { if luma(px(x, y)) > 140 { return true }; x += 0.5 }
                y += 0.5
            }
            return false
        }
        guard hasInk(CGRect(x: p.minX + 20, y: p.minY + 16, width: 200, height: 32)) else { return false }
        if !controller.rows.isEmpty, !hasInk(CGRect(x: p.minX + 20, y: p.minY + 80, width: 200, height: 28)) { return false }
        return true
    }
}

/// Backdrop under the overlay: a captured frame or a flat page color. Drawn as layer
/// contents, not through an AppKit backing store: large backing stores are purgeable and
/// can be dropped under memory pressure before the offscreen renderer reads them.
@MainActor
final class StageRoot: NSView {
    var backdrop = CommandBarBackdrop.darkPage { didSet { needsDisplay = true } }
    /// Bottom color of a vertical gradient under a flat backdrop.
    var bottomColor: RGBA? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        guard let layer else { return }
        if let image = backdrop.image {
            layer.contents = image
            layer.contentsGravity = .resize
            layer.backgroundColor = nil
        } else if let bottom = bottomColor {
            let g = CAGradientLayer()
            g.colors = [backdrop.color.cgColor, bottom.cgColor]
            g.frame = bounds
            layer.sublayers?.filter { $0 is CAGradientLayer }.forEach { $0.removeFromSuperlayer() }
            layer.insertSublayer(g, at: 0)
            layer.contents = nil
        } else {
            layer.contents = nil
            layer.backgroundColor = backdrop.color.cgColor
        }
    }
}
