import AppKit
import OpenDesign
import OpenWeb

/// Where captures go: `<root>/Captures` and `State/captures.json` (the App's
/// `CaptureLibraryWriter`, settings-library §2.6). Main actor, like the Library's own reader.
@MainActor
public protocol CaptureLibrary: AnyObject {
    /// Writes the PNG and appends its index row; returns the row id.
    func save(png: Data, kind: CaptureComposer.Kind, sourceHost: String) async throws -> UUID
    /// Removes the file and its row in one step.
    func delete(id: UUID) throws
    /// Library ▸ Captures.
    func showInLibrary(id: UUID)
    /// The saved file, for Share.
    func fileURL(id: UUID) -> URL?
}

/// Toasts the capture flow shows (page-platform §4.1.4). The window wires them to its toast
/// presenter; the default does nothing.
@MainActor
public struct CaptureToastHooks {
    /// "Capture in Progress", sticky until the returned closure runs.
    public var progress: () -> (() -> Void) = { {} }
    /// "Copied Image".
    public var copied: () -> Void = {}
    /// Keycaps ⌘ ⇧ + "and drag your mouse to capture any time." (§4.6.7).
    public var shortcutHint: () -> Void = {}
    public var failed: (String) -> Void = { _ in }
    /// The card replaces visible toasts (§4.6.5).
    public var dismissAll: () -> Void = {}
    public init() {}
}

/// The Capture tool of one browser window (page-platform §4.6): area, full page, and portrait
/// captures; the Cmd+Shift drag; the result card. Everything is one-shot work started by input:
/// no timer repeats, the card's lifetime is one cancellable work item, and the drag monitor
/// returns at once for every event that is not a held Cmd+Shift press.
@MainActor
public final class CaptureController {
    public enum Entry: String, Sendable { case command, drag, retake }
    public enum Phase: String, Sendable { case idle, selecting, capturing, showing }

    /// The focused page: its host (URL, title), its engine content, and its view.
    public struct PageTarget {
        public var url: URL?
        public var title: String
        public var content: any WebContent
        public var view: NSView
        public var isPrivate: Bool
        public init(url: URL?, title: String, content: any WebContent, view: NSView, isPrivate: Bool) {
            self.url = url; self.title = title; self.content = content; self.view = view; self.isPrivate = isPrivate
        }
    }

    public struct Result {
        public var kind: CaptureComposer.Kind
        public var png: Data
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var truncated: Bool
        public var savedID: UUID?
        public var sourceHost: String
        public var title: String
        public var createdAt: Date
    }

    public static let dragToCaptureKey = "open.capture.dragToCaptureEnabled"
    public static let shortcutHintKey = "open.capture.shortcutHintLastShown"
    public static let portraitBackgroundKey = "open.capture.portraitBackground"
    /// Lazy images load before a full-page capture (§4.6.4). Waits at most `fullPageSettle`.
    static let settleScript = """
    (async () => { document.querySelectorAll('img[loading=lazy]').forEach(i => { i.loading = 'eager' });
      const pending = Array.from(document.images).filter(i => !i.complete);
      await Promise.race([Promise.all(pending.map(i => new Promise(r => { i.addEventListener('load', r, { once: true }); i.addEventListener('error', r, { once: true }) }))),
        new Promise(r => setTimeout(r, \(Int(CaptureMetrics.fullPageSettle * 1000))))]); return pending.length })()
    """

    private weak var root: NSView?
    private let defaults: UserDefaults
    public var pageTarget: () -> PageTarget? = { nil }
    /// The toast anchor in root coordinates (flipped): the card's top-right corner.
    public var anchor: () -> CGPoint = { .zero }
    public var style: () -> SpaceThemeStyle = { .defaultTheme(system: .dark) }
    public var library: (any CaptureLibrary)?
    public var toasts = CaptureToastHooks()
    public var playSound: () -> Void = { SoundEffects.shared.play(.capture) }
    /// After every finished, failed, or cancelled flow (automation waits on this).
    public var onChange: (() -> Void)?

    public private(set) var phase = Phase.idle
    public private(set) var overlay: CaptureOverlayView? { didSet { if (overlay == nil) != (oldValue == nil) { onOverlayChange?(overlay != nil) } } }
    /// The selection overlay came up (true) or went away (false): page history swipes pause
    /// while it shows (page-platform §4.4.1).
    public var onOverlayChange: ((Bool) -> Void)?
    public private(set) var card: CaptureResultView?
    public private(set) var lastResult: Result?
    public private(set) var lastError: String?
    public private(set) var lastEntry: Entry?
    public private(set) var completedCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var hintShows = 0
    /// The card's scheduled close (CACurrentMediaTime); nil while the pointer pauses it.
    public private(set) var cardDeadline: CFTimeInterval?
    /// The configured lifetime left when paused.
    public private(set) var cardRemaining: TimeInterval = CaptureMetrics.cardLifetime
    /// Swipe navigation reads this (EP-1, §4.4): no history swipe while the overlay shows.
    public var isOverlayActive: Bool { overlay != nil }

    private weak var overlayPage: NSView?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var cardWork: DispatchWorkItem?
    private var pendingHint = false
    private var dismissProgress: (() -> Void)?
    private var pendingSave: NSSavePanel?
    /// A held Cmd+Shift mouse-down (§4.6.2) and whatever arrived before the decision.
    private struct Held { var events: [NSEvent]; var start: CGPoint; weak var view: NSView?; var dragging: Bool }
    private var held: Held?
    public var isHoldingPress: Bool { held != nil }

    public init(root: NSView, defaults: UserDefaults = .standard) {
        self.root = root; self.defaults = defaults
    }

    // MARK: Start

    /// Starts a capture of the focused page. An area capture shows the overlay; `pressPoint`
    /// (page-view points) makes it start already dragging from there.
    public func start(_ kind: CaptureComposer.Kind, entry: Entry = .command, pressPoint: CGPoint? = nil) {
        guard phase != .capturing, overlay == nil else { return }
        closeCard()
        guard let target = pageTarget() else { fail("There is no page to capture."); return }
        generation += 1; lastEntry = entry; lastError = nil
        if entry == .command, now() - defaults.double(forKey: Self.shortcutHintKey) > CaptureMetrics.shortcutHintInterval { pendingHint = true }
        if kind == .area { showOverlay(on: target.view, pressPoint: pressPoint) }
        else { capture(kind, selection: nil) }
    }

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }

    private func showOverlay(on page: NSView, pressPoint: CGPoint?) {
        guard let root else { return }
        let fill = style().toastFillTop.nsColor
        let view = CaptureOverlayView(frame: root.convert(page.bounds, from: page), hintFill: fill)
        view.onFinish = { [weak self, weak view] outcome in
            guard let self, let view, self.overlay === view else { return }
            self.removeOverlay()
            switch outcome {
            case .cancelled: self.cancelledCount += 1; self.phase = .idle; self.flowEnded()
            case .selected(let rect): self.capture(.area, selection: rect)
            }
        }
        root.addSubview(view)
        overlay = view; overlayPage = page; phase = .selecting
        view.layoutSubtreeIfNeeded()
        root.window?.makeFirstResponder(view)
        root.window?.invalidateCursorRects(for: view)
        NSCursor.crosshair.set()
        if let pressPoint { view.begin(at: pressPoint) }
        onChange?()
    }

    private func removeOverlay() {
        guard let view = overlay else { return }
        overlay = nil
        let page = overlayPage; overlayPage = nil
        view.onFinish = nil; view.removeFromSuperview()
        NSCursor.arrow.set()
        // Give the keyboard back to the page the overlay covered.
        if let page, page.window != nil { page.window?.makeFirstResponder(page) }
    }

    /// Keeps the overlay over its page when the window lays out (resize, sidebar), and ends it
    /// when the focused page changed under it (tab switch, close).
    public func layout() {
        if let overlay {
            guard let page = overlayPage, page.window != nil, page === pageTarget()?.view, let root else { overlay.cancel(); return }
            let frame = root.convert(page.bounds, from: page)
            if overlay.frame != frame { overlay.frame = frame }
        }
        if let card { place(card) }
    }

    // MARK: Pipeline

    private func capture(_ kind: CaptureComposer.Kind, selection: CGRect?) {
        guard let target = pageTarget() else { fail("There is no page to capture."); return }
        phase = .capturing
        let token = generation, content = target.content
        let viewSize = target.view.bounds.size
        let host = target.url?.host ?? target.url?.scheme ?? "", title = target.title
        let background = CaptureComposer.PortraitBackground(defaultsValue: defaults.string(forKey: Self.portraitBackgroundKey))
        let theme = style(), library = target.isPrivate ? nil : library
        if kind == .fullPage { dismissProgress = toasts.progress() }
        task = Task { @MainActor [weak self] in
            do {
                let png: Data, truncated: Bool
                if kind == .fullPage {
                    _ = try? await content.evaluateJavaScript(Self.settleScript)
                    guard self?.generation == token else { return }
                    let full = try await content.fullPagePNG(maxDevicePixels: CaptureMetrics.fullPageMaxDevicePixels)
                    png = full.data; truncated = full.truncated
                } else { png = try await content.snapshotPNG(); truncated = false }
                guard let self, self.generation == token else { return }
                let output = try await CaptureComposer.render(.init(kind: kind, png: png, selection: selection, viewSize: viewSize,
                                                                    portraitBackground: background, themeStyle: theme))
                guard self.generation == token else { return }
                let savedID = try await library?.save(png: output.png, kind: kind, sourceHost: host)
                guard self.generation == token else {
                    // The window or the flow ended while the file was written: keep the Library row.
                    return
                }
                self.finish(Result(kind: kind, png: output.png, pixelWidth: output.pixelWidth, pixelHeight: output.pixelHeight,
                                   truncated: truncated, savedID: savedID, sourceHost: host, title: title, createdAt: Date()),
                            thumbnail: output.thumbnailPNG)
            } catch {
                guard let self, self.generation == token else { return }
                self.fail("Could not capture this page. \(error)")
            }
        }
    }

    private func finish(_ result: Result, thumbnail: Data) {
        task = nil; dismissProgress?(); dismissProgress = nil
        lastResult = result; completedCount += 1
        // TODO(sound): `SoundEffects` owns the player and the playSoundEffects preference (§4.6.8).
        playSound()
        showCard(result, thumbnail: NSImage(data: thumbnail) ?? NSImage())
        onChange?()
    }

    private func fail(_ message: String) {
        task = nil; dismissProgress?(); dismissProgress = nil
        removeOverlay()
        lastError = message; phase = .idle
        toasts.failed(message)
        flowEnded()
    }

    /// One flow ended (card closed, capture cancelled or failed): the keycap hint may show now.
    private func flowEnded() {
        if pendingHint {
            pendingHint = false; hintShows += 1
            defaults.set(now(), forKey: Self.shortcutHintKey)
            toasts.shortcutHint()
        }
        onChange?()
    }

    // MARK: Card

    private func showCard(_ result: Result, thumbnail: NSImage) {
        guard let root else { return }
        toasts.dismissAll()
        let note = result.truncated ? "Page cut at \(Self.grouped(CaptureMetrics.fullPageMaxDevicePixels)) px." : nil
        let view = CaptureResultView(image: thumbnail, imageSize: CGSize(width: result.pixelWidth, height: result.pixelHeight),
                                     actions: CaptureResultView.actions(area: result.kind == .area, saved: result.savedID != nil),
                                     savedToLibrary: result.savedID != nil, note: note)
        view.onAction = { [weak self] action, sender in self?.perform(action, sender: sender) }
        view.onHover = { [weak self] hovered in self?.cardHover(hovered) }
        root.addSubview(view)
        card = view; phase = .showing
        place(view)
        if root.window?.isVisible == true, !Motion.reducesMotion {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = CaptureMetrics.cardFade; view.animator().alphaValue = 1 }
        }
        cardRemaining = CaptureMetrics.cardLifetime
        scheduleCardClose()
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func place(_ card: CaptureResultView) {
        let a = anchor()
        let frame = CGRect(x: a.x - card.frame.width, y: a.y, width: card.frame.width, height: card.frame.height)
        if card.frame != frame { card.frame = frame }
    }

    private func scheduleCardClose() {
        cardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeCard() } }
        cardWork = work; cardDeadline = CACurrentMediaTime() + cardRemaining
        DispatchQueue.main.asyncAfter(deadline: .now() + cardRemaining, execute: work)
    }

    private func cardHover(_ hovered: Bool) {
        guard card != nil else { return }
        if hovered {
            if let deadline = cardDeadline { cardRemaining = max(0, deadline - CACurrentMediaTime()) }
            cardWork?.cancel(); cardWork = nil; cardDeadline = nil
        } else if cardDeadline == nil { scheduleCardClose() }
    }

    /// Closes the card (Esc, its lifetime, a new capture, Delete).
    public func closeCard() {
        // End a Save… sheet first: its completion may reschedule the lifetime.
        if let panel = pendingSave { pendingSave = nil; panel.cancel(nil) }
        cardWork?.cancel(); cardWork = nil; cardDeadline = nil
        guard let view = card else { return }
        card = nil; phase = .idle
        view.onAction = nil; view.onHover = nil
        // A card button's own action can close the card: the view leaves on a later turn
        // (the fade's completion, or the next run-loop turn), never inside that callback.
        if view.window?.isVisible == true, !Motion.reducesMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = CaptureMetrics.cardFade; view.animator().alphaValue = 0 }
                completionHandler: { MainActor.assumeIsolated { view.removeFromSuperview() } }
        } else {
            view.isHidden = true
            DispatchQueue.main.async { view.removeFromSuperview() }
        }
        flowEnded()
    }

    // MARK: Card actions

    /// Runs a card action, as its button does.
    public func perform(_ action: CaptureResultView.Action, sender: NSView? = nil) {
        guard let result = lastResult, card != nil else { return }
        switch action {
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents(); pasteboard.setData(result.png, forType: .png)
            toasts.copied()
        case .save: save(result)
        case .share:
            let url = result.savedID.flatMap { library?.fileURL(id: $0) } ?? temporaryFile(result)
            guard let url, let anchorView = sender ?? card else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        case .library:
            if let id = result.savedID { library?.showInLibrary(id: id) }
            closeCard()
        case .retake:
            // Retake replaces this capture (Section 8 decision): its row goes, a new area capture starts.
            if let id = result.savedID { try? library?.delete(id: id) }
            lastResult = nil; closeCard(); start(.area, entry: .retake)
        case .delete:
            if let id = result.savedID {
                do { try library?.delete(id: id) } catch { toasts.failed("Could not delete the capture. \(error.localizedDescription)"); return }
            }
            lastResult = nil; closeCard()
        }
    }

    private func save(_ result: Result) {
        guard pendingSave == nil, let window = root?.window else { return }
        let panel = NSSavePanel(); pendingSave = panel
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = CaptureComposer.fileName(title: result.title, date: result.createdAt)
        // The card waits while the sheet is up.
        cardWork?.cancel(); cardWork = nil; cardDeadline = nil
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                guard let self, let panel, self.pendingSave === panel else { return }
                self.pendingSave = nil
                if self.card != nil { self.scheduleCardClose() }
                guard response == .OK, let url = panel.url else { return }
                let data = result.png
                Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    private func temporaryFile(_ result: Result) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Open Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureComposer.fileName(title: result.title, date: result.createdAt))
        return (try? result.png.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: Keys and the Cmd+Shift drag

    /// Esc and Return for the overlay, Esc and Cmd+C for the card. Called from the window's
    /// real key path (`BrowserWindowController.handleKeyDown`).
    public func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let overlay {
            switch event.keyCode {
            case 53: overlay.cancel(); return true
            case 36 where flags.isEmpty, 76 where flags.isEmpty: overlay.captureWholePage(); return true
            default: return false
            }
        }
        guard card != nil else { return false }
        if event.keyCode == 53, flags.isEmpty { closeCard(); return true }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            let responder = event.window?.firstResponder
            guard !(responder is NSTextView), !(responder is NSTextField) else { return false }
            perform(.copy); return true
        }
        return false
    }

    /// The window's local mouse monitor (§4.6.2). Holds a left mouse-down with exactly Cmd+Shift
    /// over the focused page; ≥ 4 pt of travel starts the area overlay at the press point; a
    /// mouse-up first replays the held events to the page (so Cmd+Shift-click on a link still
    /// opens it, C6). Returns true when the event was consumed (the monitor then drops it).
    /// The window calls this only for a Cmd+Shift mouse-down or while a press is held.
    public func handleMouse(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            held = nil
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
                  overlay == nil, phase != .capturing, defaults.object(forKey: Self.dragToCaptureKey) as? Bool ?? true,
                  let target = pageTarget(), target.view.window != nil, event.window === target.view.window else { return false }
            let point = target.view.convert(event.locationInWindow, from: nil)
            guard target.view.bounds.contains(point) else { return false }
            held = Held(events: [event], start: point, view: target.view, dragging: false)
            return true
        case .leftMouseDragged:
            guard var press = held else { return false }
            guard let view = press.view, event.window === view.window else { held = nil; return false }
            let point = view.convert(event.locationInWindow, from: nil)
            if press.dragging { overlay?.drag(to: point); return true }
            press.events.append(event)
            if hypot(point.x - press.start.x, point.y - press.start.y) >= CaptureMetrics.dragThreshold {
                press.events = []; press.dragging = true; held = press
                start(.area, entry: .drag, pressPoint: press.start)
                guard overlay != nil else { held = nil; return true }
                overlay?.drag(to: point)
            } else { held = press }
            return true
        case .leftMouseUp:
            guard let press = held else { return false }
            held = nil
            guard event.window === press.view?.window else { return false }
            if press.dragging {
                if let view = press.view { overlay?.drag(to: view.convert(event.locationInWindow, from: nil)) }
                overlay?.end(); return true
            }
            // A click: the page gets the press it would have had, then this mouse-up.
            replayCount += 1
            for e in press.events { replay(e) }
            return false
        default: return false
        }
    }
    /// Held Cmd+Shift clicks given back to the page (C6 evidence).
    public private(set) var replayCount = 0
    /// Delivers a held event to its window (past the local monitors, which already saw it).
    /// The offscreen checks record here; the App's e2e C6 proves the real delivery.
    public var replay: (NSEvent) -> Void = { $0.window?.sendEvent($0) }

    // MARK: Teardown

    /// Window close or controller teardown: cancel everything; nothing outlives the window.
    public func tearDown() {
        generation += 1; task?.cancel(); task = nil
        dismissProgress?(); dismissProgress = nil
        held = nil; pendingHint = false
        removeOverlay(); closeCard()
        phase = .idle
    }

    /// Cancels the overlay or the card from outside (tab switch, automation).
    public func cancel() {
        if let overlay { overlay.cancel() }
        else if phase == .capturing { generation += 1; task?.cancel(); task = nil; fail("The capture was cancelled.") }
        else { closeCard() }
    }
}
