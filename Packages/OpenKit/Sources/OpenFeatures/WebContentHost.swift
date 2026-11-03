import AppKit
import OpenModel
import OpenWeb

public struct WebContentLiveState: Sendable {
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isAudible: Bool
    public var isCrashed: Bool
    public init(isLoading: Bool = false, progress: Double = 0, canGoBack: Bool = false,
                canGoForward: Bool = false, isAudible: Bool = false, isCrashed: Bool = false) {
        self.isLoading = isLoading; self.progress = progress; self.canGoBack = canGoBack
        self.canGoForward = canGoForward; self.isAudible = isAudible; self.isCrashed = isCrashed
    }
}

@MainActor
public protocol WebContentHost: AnyObject {
    var view: NSView { get }
    var tabID: ItemID { get }
    var currentURL: URL? { get }
    var title: String { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    func load(_ url: URL)
    func reload()
    func stop()
    func goBack()
    func goForward()
    func focus()
    func close()
    var onURLChange: ((URL) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
    var onLoadingChange: ((Bool) -> Void)? { get set }
    var onFaviconChange: ((Data?) -> Void)? { get set }
    var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)? { get set }
    /// The page's own background color. A split pane's 32 pt bar takes it
    /// (F0081: lavender page → `#DEDEFA` bar, white page → white bar); nil uses the
    /// Space fallback. TODO(engine): report the page background or theme color
    /// (docs/engine-api.md, "Page background color").
    var pageBackgroundColor: NSColor? { get }
    /// Called when `pageBackgroundColor` changes, also after the URL callback for the
    /// same navigation (the color can arrive late).
    var onPageBackgroundChange: ((NSColor?) -> Void)? { get set }
    var liveState: WebContentLiveState { get }
    var onLiveStateChange: ((WebContentLiveState) -> Void)? { get set }
}

public extension WebContentHost {
    var liveState: WebContentLiveState { WebContentLiveState(isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward) }
}

/// The page behind a host, for capture, selection, and translation (page-platform §3.2).
/// A separate protocol so render fakes and every existing host keep compiling; the App's
/// engine host conforms.
@MainActor
public protocol WebContentProviding: AnyObject {
    var webContent: (any WebContent)? { get }
    /// The page runs in an in-memory (incognito) context: captures are not saved (§4.6.1).
    var isPrivateBrowsing: Bool { get }
}

@MainActor
public protocol WebContentHostFactory: AnyObject {
    /// Nil refuses creation while the engine or profile is unavailable.
    func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)?
    /// Called before binding an existing host under a promoted model tab ID.
    func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool
    func remainingLiveState(for tabID: ItemID) -> WebContentLiveState?
}
public extension WebContentHostFactory {
    func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool { true }
    func remainingLiveState(for tabID: ItemID) -> WebContentLiveState? { nil }
}
