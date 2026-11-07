import AppKit
import OpenWeb

/// One window owns the sheet and at most three waiting requests. Page identity
/// is supplied by the App, including Peek and Little Open pages.
@MainActor public final class SavePromptPresenter {
    private struct Entry { let request: any SavePromptRequest; let page: AnyHashable }
    private var pending: [Entry] = []
    public private(set) var active: SavePromptSheet?
    private var activePage: AnyHashable?
    public var queuedCount: Int { pending.count }
    private weak var window: NSWindow?
    private let isFocused: (AnyHashable) -> Bool
    private var closing = false
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
    }
    public func enqueue(_ request: any SavePromptRequest, page: AnyHashable) {
        guard !closing, window != nil, !request.isAnswered, request.displayHost.utf8.count <= SavePromptSheet.maximumHostBytes,
              active?.request !== request, !pending.contains(where: { $0.request === request }) else { return }
        pending.removeAll { $0.page == page }
        if activePage == page { removeActive() }
        pending.append(Entry(request: request, page: page))
        if pending.count > 3 { pending.removeFirst() } // Release unanswered, never synthesize No.
        showNext()
    }
    public func withdraw(_ request: any SavePromptRequest) {
        pending.removeAll { $0.request === request }
        if active?.request === request { removeActive() }
        scheduleNext()
    }
    public func pageDidBecomeFocused(_ page: AnyHashable) {
        if let sheet = active, let oldPage = activePage, oldPage != page || !isFocused(oldPage) {
            if let request = sheet.request { pending.insert(Entry(request: request, page: oldPage), at: 0) }
            removeActive()
            if pending.count > 3 { pending.removeFirst() }
        }
        showNext()
    }
    public func pageDidClose(_ page: AnyHashable) {
        pending.removeAll { $0.page == page }
        if activePage == page { removeActive() }
        scheduleNext()
    }
    private func showNext() {
        guard !closing, active == nil, let window, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        pending.removeAll { $0.request.isAnswered }
        guard let index = pending.firstIndex(where: { isFocused($0.page) }) else { return }
        let entry = pending.remove(at: index)
        guard let sheet = SavePromptSheet(entry.request) else { scheduleNext(); return }
        active = sheet; activePage = entry.page
        sheet.onFinished = { [weak self, weak sheet] in
            // NSButton/engine callbacks may close or replace a request. Tear down
            // on the next run-loop turn, after the caller has unwound.
            DispatchQueue.main.async { [weak self, weak sheet] in
                guard let self, let sheet, self.active === sheet else { return }
                self.removeActive(); self.showNext()
            }
        }
        window.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.active === sheet else { return }
            self.removeActive(); self.scheduleNext()
        }
        sheet.makeFirstResponder(sheet.initialFirstResponder); sheet.announce()
    }
    private func removeActive() {
        let sheet = active; active = nil; activePage = nil
        guard let sheet else { return }
        sheet.onFinished = nil; sheet.releaseUnanswered()
        if sheet.sheetParent != nil { window?.endSheet(sheet) }
        sheet.orderOut(nil)
    }
    private func scheduleNext() { DispatchQueue.main.async { [weak self] in self?.showNext() } }
    public func cancelAll() { closing = true; pending.removeAll(); removeActive() }
    isolated deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; cancelAll() }
}
