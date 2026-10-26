import AppKit
import OpenModel

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
    /// (F0081: lavender page → `#DEDEFA` bar, white page → white bar).
    /// TODO(engine): report the page background or theme color; nil uses the Space fallback.
    var pageBackgroundColor: NSColor? { get }
}

extension WebContentHost {
    public var pageBackgroundColor: NSColor? { nil }
}

@MainActor
public protocol WebContentHostFactory: AnyObject {
    func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> any WebContentHost
}
