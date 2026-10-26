import AppKit
import OpenModel

@MainActor
public final class FakeWebContentHost: WebContentHost {
    public let tabID: ItemID
    public let surface: FakePageView
    public var view: NSView { surface }
    public var currentURL: URL? { history.indices.contains(cursor) ? history[cursor] : nil }
    public private(set) var title = ""
    public var canGoBack: Bool { cursor > 0 }
    public var canGoForward: Bool { cursor + 1 < history.count }
    public private(set) var isLoading = false
    public private(set) var isClosed = false
    public private(set) var loadCount = 0
    private var history: [URL] = []
    private var cursor = -1
    private var loadGeneration = 0
    private var loadingTask: Task<Void, Never>?
    public var onURLChange: ((URL) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onLoadingChange: ((Bool) -> Void)?
    public var onFaviconChange: ((Data?) -> Void)?
    public var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?

    public init(tabID: ItemID, color: NSColor) {
        self.tabID = tabID; surface = FakePageView(color: color)
    }
    public func load(_ url: URL) {
        guard !isClosed else { return }
        history = Array(history.prefix(cursor + 1)); history.append(url); cursor = history.count - 1
        loadCount += 1; publish(); beginLoading()
    }
    private func publish() {
        guard let url = currentURL else { return }
        title = url.host() ?? "New Tab"; surface.label.stringValue = title
        onURLChange?(url); onTitleChange?(title)
    }
    private func beginLoading() {
        loadGeneration += 1; let generation = loadGeneration
        loadingTask?.cancel(); isLoading = true; onLoadingChange?(true)
        loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.isClosed, self.loadGeneration == generation else { return }
            self.isLoading = false; self.onLoadingChange?(false)
        }
    }
    public func reload() { guard !isClosed else { return }; loadCount += 1; beginLoading() }
    public func stop() { loadingTask?.cancel(); loadGeneration += 1; isLoading = false; onLoadingChange?(false) }
    public func goBack() { guard !isClosed, canGoBack else { return }; cursor -= 1; publish() }
    public func goForward() { guard !isClosed, canGoForward else { return }; cursor += 1; publish() }
    public func focus() { guard !isClosed else { return }; surface.window?.makeFirstResponder(surface) }
    public func close() {
        guard !isClosed else { return }; isClosed = true; loadingTask?.cancel(); loadGeneration += 1
        onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
        surface.removeFromSuperview()
    }
    @discardableResult public func simulateLinkClick(_ url: URL, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !isClosed else { return false }
        if shouldNavigate?(url, modifiers) ?? true { load(url); return true }
        return false
    }
}

@MainActor
public final class FakePageView: NSView {
    public let label = NSTextField(labelWithString: "New Tab")
    public private(set) var clickCount = 0
    public init(color: NSColor) {
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = color.cgColor
        label.font = .systemFont(ofSize: 20); label.textColor = .darkGray; label.alignment = .center
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    public override func layout() { super.layout(); label.frame = CGRect(x: 10, y: bounds.midY - 15, width: max(0, bounds.width - 20), height: 30) }
    public override func mouseDown(with event: NSEvent) { clickCount += 1 }
}

@MainActor
public final class FakeWebContentHostFactory: WebContentHostFactory {
    public private(set) var made: [FakeWebContentHost] = []
    public func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> any WebContentHost {
        let colors: [NSColor] = [.init(srgbRed: 0.87, green: 0.87, blue: 0.98, alpha: 1), .white,
                                  .init(srgbRed: 0.84, green: 0.94, blue: 0.88, alpha: 1), .init(srgbRed: 0.97, green: 0.90, blue: 0.80, alpha: 1)]
        let host = FakeWebContentHost(tabID: tabID, color: colors[made.count % colors.count]); made.append(host)
        if let url { host.load(url) }; return host
    }
}
