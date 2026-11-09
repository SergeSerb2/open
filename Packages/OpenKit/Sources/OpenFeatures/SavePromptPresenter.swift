import AppKit
import OpenWeb

/// One window owns the sheet and at most three waiting requests. Page identity
/// is supplied by the App, including Peek and Little Open pages.
@MainActor public final class SavePromptPresenter {
    private struct Entry { let request: any SavePromptRequest; let page: AnyHashable }
    private var pending: [Entry] = []
    public private(set) var active: SavePromptSheet?
    /// Called only after the real sheet is attached. Automation uses its buttons.
    public var onPresent: ((SavePromptSheet) -> Void)?
    /// Observes unanswered release without answering the engine request.
    public var onDiscard: ((any SavePromptRequest) -> Void)?
    private var activePage: AnyHashable?
    public var queuedCount: Int { pending.count }
    private weak var window: NSWindow?
    private let isFocused: (AnyHashable) -> Bool
    private var closing = false
    private var showing = false
    private var passScheduled = false
    private var needsPass = false
    private var activeInvalidated = false
    private var observers: [any NSObjectProtocol] = []
    public init(window: NSWindow, isFocused: @escaping (AnyHashable) -> Bool) {
        self.window = window; self.isFocused = isFocused
        for (name, object) in [(NSWindow.willCloseNotification, window as AnyObject), (NSApplication.willTerminateNotification, NSApplication.shared as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAll() }
            })
        }
        for name in [NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleNext() }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleNext() }
            })
        }
    }
    public func enqueue(_ request: any SavePromptRequest, page: AnyHashable) {
        guard !closing, window != nil, !request.isAnswered, request.displayHost.utf8.count <= SavePromptSheet.maximumHostBytes,
              active?.request !== request, !pending.contains(where: { $0.request === request }) else { return }
        removePending { $0.page == page }
        if activePage == page { activeInvalidated = true }
        pending.append(Entry(request: request, page: page))
        if pending.count > 3 { discard(pending.removeFirst().request) } // Release unanswered, never synthesize No.
        scheduleNext()
    }
    public func withdraw(_ request: any SavePromptRequest) {
        removePending { $0.request === request }
        if active?.request === request { activeInvalidated = true }
        scheduleNext()
    }
    public func pageDidBecomeFocused(_ page: AnyHashable) {
        // Read the current focused pane in the scheduled pass. AppKit may call
        // this during beginSheet, between the parent resigning and sheet focus.
        scheduleNext()
    }
    public func pageDidClose(_ page: AnyHashable) {
        removePending { $0.page == page }
        if activePage == page { activeInvalidated = true }
        scheduleNext()
    }
    private func showNext() {
        guard !showing else { scheduleNext(); return }
        guard !closing, active == nil, let window, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        pending.removeAll { $0.request.isAnswered }
        guard let index = pending.firstIndex(where: { isFocused($0.page) }) else { return }
        let entry = pending.remove(at: index)
        guard let sheet = SavePromptSheet(entry.request) else { scheduleNext(); return }
        showing = true
        defer { finishSheetChange() }
        active = sheet; activePage = entry.page
        sheet.onFinished = { [weak self, weak sheet] in
            guard let self, let sheet, self.active === sheet else { return }
            self.activeInvalidated = true; self.scheduleNext()
        }
        window.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.active === sheet else { return }
            self.activeInvalidated = true; self.scheduleNext()
        }
        sheet.makeFirstResponder(sheet.initialFirstResponder); sheet.announce()
        onPresent?(sheet)
    }
    private func discard(_ request: any SavePromptRequest) {
        if !request.isAnswered { onDiscard?(request) }
    }
    private func removePending(where predicate: (Entry) -> Bool) {
        let removed = pending.filter(predicate)
        pending.removeAll(where: predicate)
        removed.forEach { discard($0.request) }
    }
    private func removeActive(preservingRequest: Bool = false) {
        guard !showing else { scheduleNext(); return }
        let sheet = active; active = nil; activePage = nil; activeInvalidated = false
        guard let sheet else { return }
        showing = true
        defer { finishSheetChange() }
        sheet.onFinished = nil
        if !preservingRequest, let request = sheet.request { discard(request) }
        sheet.releaseUnanswered()
        if sheet.sheetParent != nil { window?.endSheet(sheet) }
        sheet.orderOut(nil)
    }
    private func finishSheetChange() {
        showing = false
        if needsPass { scheduleNext() }
    }
    private func scheduleNext() {
        needsPass = true
        guard !showing, !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.passScheduled = false
            // begin/endSheet may pump a nested run loop. Its outer operation
            // schedules the pending pass when it has fully unwound.
            guard !self.showing else { return }
            self.needsPass = false
            if self.closing || self.activeInvalidated { self.removeActive() }
            else if let sheet = self.active, let page = self.activePage, !self.isFocused(page) {
                if let request = sheet.request { self.pending.insert(Entry(request: request, page: page), at: 0) }
                self.removeActive(preservingRequest: true)
                if self.pending.count > 3 { self.discard(self.pending.removeFirst().request) }
            }
            self.showNext()
        }
    }
    public func cancelAll() {
        closing = true; removePending { _ in true }; activeInvalidated = true
        // Release the request while its closing window/page can still supply
        // completion metadata. AppKit sheet teardown stays in the queued pass.
        if let sheet = active, let request = sheet.request {
            discard(request); sheet.releaseUnanswered()
        }
        scheduleNext()
    }
    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        closing = true; needsPass = false; removePending { _ in true }; removeActive()
    }
}
