import AppKit
import CoreText
import OpenModel
import OpenFeatures

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
    private var loadingWork: DispatchWorkItem?
    public var onURLChange: ((URL) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onLoadingChange: ((Bool) -> Void)?
    public var onFaviconChange: ((Data?) -> Void)?
    public var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
    /// Render-only page colors by host (`--page-color HOST=RRGGBB`). A comparison gives a
    /// fake page the background of the captured page, so the chrome around it is measured
    /// against the same page pixels. Hosts without an entry keep the factory's color.
    public static var pageColors: [String: NSColor] = [:]
    /// Render-only (`--keep-titles`): pages do not report a title, so tabs keep their saved titles.
    public static var reportsTitles = true
    public var pageBackgroundColor: NSColor? { surface.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    public var onPageBackgroundChange: ((NSColor?) -> Void)?
    public var onLiveStateChange: ((WebContentLiveState) -> Void)?

    public init(tabID: ItemID, color: NSColor) {
        self.tabID = tabID; surface = FakePageView(color: color)
    }
    public func load(_ url: URL) {
        guard !isClosed else { return }
        history = Array(history.prefix(cursor + 1)); history.append(url); cursor = history.count - 1
        loadCount += 1; publish(colorAfterLoad: true); beginLoading()
    }
    /// A navigation's page color (`--page-color`) arrives late, like an engine's: after the
    /// URL callback, and for a load only once loading ends.
    private var pendingPageColor: NSColor?
    private func publish(colorAfterLoad: Bool = false) {
        guard let url = currentURL else { return }
        title = url.host() ?? "New Tab"; surface.label.stringValue = title
        onURLChange?(url); if Self.reportsTitles { onTitleChange?(title) }
        pendingPageColor = url.host().flatMap { Self.pageColors[$0] }
        if !colorAfterLoad { applyPendingPageColor() }
    }
    private func applyPendingPageColor() {
        guard let color = pendingPageColor else { return }
        pendingPageColor = nil
        surface.layer?.backgroundColor = color.cgColor; onPageBackgroundChange?(color)
    }
    private func beginLoading() {
        loadGeneration += 1; let generation = loadGeneration
        loadingWork?.cancel(); isLoading = true; onLoadingChange?(true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, self.loadGeneration == generation else { return }
                self.isLoading = false; self.onLoadingChange?(false); self.applyPendingPageColor()
            }
        }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    public func reload() { guard !isClosed else { return }; loadCount += 1; beginLoading() }
    public func stop() { loadingWork?.cancel(); loadGeneration += 1; isLoading = false; onLoadingChange?(false); applyPendingPageColor() }
    public func goBack() { guard !isClosed, canGoBack else { return }; cursor -= 1; publish() }
    public func goForward() { guard !isClosed, canGoForward else { return }; cursor += 1; publish() }
    public func focus() { guard !isClosed else { return }; surface.window?.makeFirstResponder(surface) }
    public func close() {
        guard !isClosed else { return }; isClosed = true; loadingWork?.cancel(); loadGeneration += 1
        onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
        onPageBackgroundChange = nil
        surface.removeFromSuperview()
    }
    /// The page changes its own background (a theme switch or late paint): report it as an engine would.
    public func simulatePageBackground(_ color: NSColor) {
        guard !isClosed else { return }
        surface.layer?.backgroundColor = color.cgColor; onPageBackgroundChange?(color)
    }
    @discardableResult public func simulateLinkClick(_ url: URL, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !isClosed else { return false }
        if shouldNavigate?(url, modifiers) ?? true { load(url); return true }
        return false
    }
}

@MainActor
public final class FakePageLabel: NSView {
    public var stringValue = "New Tab" { didSet { needsDisplay = true } }
    public var font = NSFont.systemFont(ofSize: 20) { didSet { needsDisplay = true } }
    public var textColor = NSColor.darkGray { didSet { needsDisplay = true } }
    public init() { super.init(frame: .zero); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: textColor]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: max(0, (bounds.width - width) / 2), y: bounds.height / 2 + (font.ascender + font.descender) / 2)
        CTLineDraw(line, context); context.restoreGState()
    }
}

@MainActor
public final class FakePageView: NSView {
    public let label = FakePageLabel()
    public private(set) var clickCount = 0
    public private(set) var layoutCount = 0
    public init(color: NSColor) {
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = color.cgColor
        label.font = .systemFont(ofSize: 20); label.textColor = .darkGray;
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); needsLayout = true
        label.frame = CGRect(x: 10, y: newSize.height / 2 - 15, width: max(0, newSize.width - 20), height: 30)
    }
    public override func layout() { super.layout(); layoutCount += 1; label.frame = CGRect(x: 10, y: bounds.midY - 15, width: max(0, bounds.width - 20), height: 30) }
    public override func mouseDown(with event: NSEvent) { clickCount += 1 }
}

@MainActor
public final class FakeWebContentHostFactory: WebContentHostFactory {
    public private(set) var made: [FakeWebContentHost] = []
    /// SP6: a factory that cannot rebind a host to another tab ID (the container closes it).
    public var refusesAdoption = false
    public func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool { !refusesAdoption || host.tabID == tabID }
    public func releaseClosedHosts() { made.removeAll { $0.isClosed } }
    public func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)? {
        let colors: [NSColor] = [.init(srgbRed: 0.87, green: 0.87, blue: 0.98, alpha: 1), .white,
                                  .init(srgbRed: 0.84, green: 0.94, blue: 0.88, alpha: 1), .init(srgbRed: 0.97, green: 0.90, blue: 0.80, alpha: 1)]
        let host = FakeWebContentHost(tabID: tabID, color: colors[made.count % colors.count]); made.append(host)
        if let url { host.load(url) }; return host
    }
}

extension FakeWebContentHost: LittleOpenWebContentProviding {}
