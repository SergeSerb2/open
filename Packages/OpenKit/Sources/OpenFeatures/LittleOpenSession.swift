import AppKit
import OpenModel
import Observation

@MainActor
@Observable
public final class LittleOpenSession: Identifiable {
    public let id = WindowID()
    public let tab: Tab
    public var profileID: ProfileID
    public let createdAt: Date
    public var lastActiveAt: Date
    public var windowIsVisible = false
    public init(tab: Tab, profileID: ProfileID) {
        self.tab = tab; self.profileID = profileID; createdAt = Date(); lastActiveAt = createdAt
    }
}

/// Routing plan §7 boundary, retained verbatim for the future engine adapter.
@MainActor
public protocol LittleOpenWebContentProviding: AnyObject {
    var view: NSView { get }
    var currentURL: URL? { get }
    func load(_ url: URL)
    func reload()
    func goBack()
    func goForward()
    var onURLChange: ((URL) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
}

/// The routing boundary is smaller than WebContentHost; bridge it in this one place.
@MainActor
final class LittleHostFactory: WebContentHostFactory {
    let make: (ProfileID) -> any LittleOpenWebContentProviding
    init(_ make: @escaping (ProfileID) -> any LittleOpenWebContentProviding) { self.make = make }
    func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)? {
        let base = make(profileID)
        let host: any WebContentHost = LittleHostAdapter(base: base, tabID: tabID)
        if let url { host.load(url) }; return host
    }
}
@MainActor
private final class LittleHostAdapter: WebContentHost {
    let base: any LittleOpenWebContentProviding
    let tabID: ItemID
    var view: NSView { base.view }
    var currentURL: URL? { base.currentURL }
    var title = ""
    var canGoBack: Bool { (base as? any WebContentHost)?.canGoBack ?? false }
    var canGoForward: Bool { (base as? any WebContentHost)?.canGoForward ?? false }
    var isLoading: Bool { (base as? any WebContentHost)?.isLoading ?? false }
    var onURLChange: ((URL) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onLoadingChange: ((Bool) -> Void)?
    var onFaviconChange: ((Data?) -> Void)?
    var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
    var pageBackgroundColor: NSColor? { (base as? any WebContentHost)?.pageBackgroundColor }
    var onPageBackgroundChange: ((NSColor?) -> Void)?
    var liveState: WebContentLiveState { (base as? any WebContentHost)?.liveState ?? WebContentLiveState() }
    var onLiveStateChange: ((WebContentLiveState) -> Void)?
    init(base: any LittleOpenWebContentProviding, tabID: ItemID) {
        self.base = base; self.tabID = tabID
        base.onURLChange = { [weak self] in self?.onURLChange?($0) }
        base.onTitleChange = { [weak self] title in self?.title = title; self?.onTitleChange?(title) }
        if let rich = base as? any WebContentHost {
            rich.onLoadingChange = { [weak self] in self?.onLoadingChange?($0) }
            rich.onFaviconChange = { [weak self] in self?.onFaviconChange?($0) }
            rich.shouldNavigate = { [weak self] url, flags in self?.shouldNavigate?(url, flags) ?? true }
            rich.onPageBackgroundChange = { [weak self] in self?.onPageBackgroundChange?($0) }
            rich.onLiveStateChange = { [weak self] in self?.onLiveStateChange?($0) }
        }
    }
    func load(_ url: URL) { base.load(url) }
    func reload() { base.reload() }
    func stop() { (base as? any WebContentHost)?.stop() }
    func goBack() { base.goBack() }
    func goForward() { base.goForward() }
    func focus() {
        if let rich = base as? any WebContentHost { rich.focus() }
        else { view.window?.makeFirstResponder(view) }
    }
    func prepareToClose() { (base as? any WebContentHost)?.prepareToClose() }
    func close() {
        base.onURLChange = nil; base.onTitleChange = nil
        (base as? any WebContentHost)?.close()
        onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
        onPageBackgroundChange = nil
        view.removeFromSuperview()
    }
}
