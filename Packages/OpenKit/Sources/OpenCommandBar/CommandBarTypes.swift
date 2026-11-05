import AppKit
import OpenDesign
import OpenModel
import OpenSuggest

/// Entry point of the command bar (docs/re/features-core.md §4.1).
public enum CommandBarMode: String, Sendable, Hashable, CaseIterable {
    /// Cmd+T: empty input; Return opens a new Today tab.
    case newTab
    /// Cmd+L: the current URL fills the input, fully selected; Return navigates the current tab.
    case editCurrentURL
    /// Opens in the Tabs scope: open, pinned, and favorite tabs only. Leaving the scope gives `.newTab`.
    case searchTabs
    /// Opens in the Actions scope: browser actions only (commandbar-completion §4.3). Leaving gives `.newTab`.
    case searchActions

    var suggestMode: SuggestMode {
        switch self {
        case .newTab: .newTab
        case .editCurrentURL: .editCurrentURL
        case .searchTabs: .searchTabs
        case .searchActions: .searchActions
        }
    }
}

/// What opened the bar and the browser state the query needs. The App fills it from
/// the window that received Cmd+T / Cmd+L.
/// A scope: the chip in the input and what the engine searches (commandbar-completion §4.3.1).
public enum CommandBarScope: Sendable, Hashable {
    case site(SiteSearch)
    case `extension`(ExtensionKeyword)
    case actions
    case tabs

    /// The chip text: the site name, "Actions" (CC-17), or "Tabs" (guess).
    public var title: String {
        switch self {
        case .site(let s): s.name
        case .extension(let e): e.name
        case .actions: CommandBarText.actionsScope
        case .tabs: CommandBarText.tabsScope
        }
    }
}

public struct CommandBarRequest: Sendable {
    public var mode: CommandBarMode
    public var profileID: ProfileID?
    public var spaceID: SpaceID?
    public var currentTabID: ItemID?
    public var currentTabURL: URL?
    /// Shown as the first row's title in Cmd+L when the input still holds the current URL (F0048).
    public var currentTabTitle: String?
    public var allowsRemoteSuggestions: Bool
    public var searchEngineID: String?

    public init(mode: CommandBarMode, profileID: ProfileID? = nil, spaceID: SpaceID? = nil,
                currentTabID: ItemID? = nil, currentTabURL: URL? = nil, currentTabTitle: String? = nil,
                allowsRemoteSuggestions: Bool = true, searchEngineID: String? = nil) {
        self.mode = mode; self.profileID = profileID; self.spaceID = spaceID
        self.currentTabID = currentTabID; self.currentTabURL = currentTabURL; self.currentTabTitle = currentTabTitle
        self.allowsRemoteSuggestions = allowsRemoteSuggestions; self.searchEngineID = searchEngineID
    }
}

/// Where a URL opens.
public enum CommandBarDestination: String, Sendable, Hashable {
    /// A new Today tab (Cmd+T mode).
    case newTab
    /// The current tab (Cmd+L mode).
    case currentTab
}

/// Modifier keys held when a row was chosen. Arc's strings name `CommandBarSelectionOptions`
/// but no capture or string proves what Cmd, Shift, or Option do, so the bar only reports them.
public struct CommandBarModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = CommandBarModifiers(rawValue: 1)
    public static let shift = CommandBarModifiers(rawValue: 2)
    public static let option = CommandBarModifiers(rawValue: 4)

    init(_ flags: NSEvent.ModifierFlags) {
        var m: CommandBarModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        self = m
    }
}

public enum CommandBarDismissReason: String, Sendable, Hashable {
    /// Esc. One press closes the bar, typed text or not (F0052 → F0053). A second Esc is not
    /// the bar's: it reaches the App's "Exit" command (`exit-modal`, docs/commands.md).
    case escape
    /// A row was chosen.
    case selection
    /// A click outside the panel. guess: standard overlay behavior.
    case clickOutside
    /// The App closed it (for example Cmd+L again, `toggleOpenOmnibox:`).
    case programmatic
}

/// Everything the bar asks the App to do. The bar has no engine code.
public enum CommandBarIntent: Sendable, Hashable {
    /// Open a page: a typed URL, a history page, or a URL the search engine suggested.
    case open(URL, CommandBarDestination, CommandBarModifiers)
    /// Run a search: the typed text, a suggested query, or a Site Search query.
    /// `siteSearchID` is set for Site Search; `url` is the final search URL.
    case search(query: String, url: URL, siteSearchID: String?, CommandBarDestination, CommandBarModifiers)
    /// Select an existing tab; switch to `spaceID` first when it names another Space.
    case switchToTab(ItemID, spaceID: SpaceID?)
    /// Run a browser command by id (`ActionRegistry`, docs/commands.md). `spaceID` is the
    /// target of "Focus on <Space>".
    case runAction(id: String, spaceID: SpaceID?)
    /// Calculator row: copy the answer.
    case runExtensionAction(extensionID: String)
    case extensionOmnibox(extensionID: String, content: String, destination: CommandBarDestination, modifiers: CommandBarModifiers)
    case copy(String)
    /// "Search Settings…" in the (i) privacy footer (CC-42): the bar closed; show the search
    /// engine settings of this Profile (the request's Profile; nil when the request had none).
    case openSearchSettings(profileID: ProfileID?)
    /// The bar closed without a choice.
    case dismissed(CommandBarDismissReason)
}

@MainActor
public protocol CommandBarDelegate: AnyObject {
    func commandBar(_ commandBar: CommandBarController, perform intent: CommandBarIntent)
    /// Presentation changed. With `.newTab` the App sets `SidebarContext.isNewTabCommandBarOpen`
    /// (the sidebar "New Tab" row looks selected during Cmd+T, not Cmd+L; F0063 vs F0049).
    func commandBar(_ commandBar: CommandBarController, didChangePresentation isPresented: Bool, mode: CommandBarMode)
    /// "Dismiss" in the (i) privacy footer. The App records the dismissal
    /// (`open.general.searchSuggestNoticeDismissed`) and may call
    /// `setAllowsRemoteSuggestions(_:)`; the bar then re-runs the current query.
    func commandBarDidDismissPrivacyNotice(_ commandBar: CommandBarController)
}

extension CommandBarDelegate {
    public func commandBar(_ commandBar: CommandBarController, didChangePresentation isPresented: Bool, mode: CommandBarMode) {}
    public func commandBarDidDismissPrivacyNotice(_ commandBar: CommandBarController) {}
}

/// Theme colors the bar takes from the Space (`semanticColorPalette.appearanceBased.dark`).
public struct CommandBarTheme: Sendable, Hashable {
    /// Selected row fill, drawn over the panel: `dark.focus` with its alpha (#B85727 a 0.8075 → #9A4B26, F0063).
    public var focus: RGBA
    /// Input text selection: `dark.subtitle` (#807571 exact, F0048).
    public var textSelection: RGBA
    /// Info (i) circle: `dark.backgroundExtra` (#190700 exact, F0063).
    public var infoFill: RGBA

    public init(focus: RGBA, textSelection: RGBA, infoFill: RGBA) {
        self.focus = focus; self.textSelection = textSelection; self.infoFill = infoFill
    }

    public init(style: SpaceThemeStyle?) {
        if let p = style?.darkPalette {
            self.init(focus: p.focus, textSelection: p.subtitle.withAlpha(1), infoFill: p.backgroundExtra.withAlpha(1))
        } else {
            self = .default
        }
    }

    /// Spaces without a theme (A0327, A0359).
    public static let `default` = CommandBarTheme(focus: CommandBarRole.defaultFocus, textSelection: CommandBarRole.defaultTextSelection,
                                                  infoFill: CommandBarRole.defaultInfoFill)
}

/// What lies behind the panel. The panel is translucent (docs/commandbar.md §3), so its
/// fill and edge follow the content under it.
public struct CommandBarBackdrop: @unchecked Sendable {
    /// Dominant color behind the panel (the page or the empty Space background).
    public var color: RGBA
    /// Optional snapshot of the window content, in window points (top-left origin), at any
    /// scale. With it the panel shows a blurred, saturated copy of the area under it.
    public var image: CGImage?
    public var imageScale: CGFloat

    public init(color: RGBA, image: CGImage? = nil, imageScale: CGFloat = 1) {
        self.color = color; self.image = image; self.imageScale = imageScale
    }

    /// A dark page (Arc's own captures: a dark Google page, #22242A).
    public static let darkPage = CommandBarBackdrop(color: RGBA(hex: 0x22242A))

    var luma: Double { 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue }
    var isDark: Bool { luma < CommandBarMaterial.darkBackdropLumaThreshold }
}
