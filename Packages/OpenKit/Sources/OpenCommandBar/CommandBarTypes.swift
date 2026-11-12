import AppKit
import OpenDesign
import OpenModel
import OpenSuggest

/// Entry point of the command bar (docs/re/features-core.md §4.1).
public enum CommandBarMode: String, Sendable, Hashable, CaseIterable {
    /// Cmd+T: empty input; Return opens a new Today tab.
    case newTab
    /// Little Open: the same suggestions, navigating its one page.
    case littleOpen
    /// Cmd+L: the current URL fills the input, fully selected; Return navigates the current tab.
    case editCurrentURL
    /// Opens in the Tabs scope: open, pinned, and favorite tabs only. Leaving the scope gives `.newTab`.
    case searchTabs
    /// Opens in the Actions scope: browser actions only (commandbar-completion §4.3). Leaving gives `.newTab`.
    case searchActions

    var suggestMode: SuggestMode {
        switch self {
        case .newTab, .littleOpen: .newTab
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

/// Theme colors the bar takes from the Space and the window appearance (plan D3 §2.1, §2.6).
public struct CommandBarTheme: Sendable, Hashable {
    /// The Space accent (one function, `SpaceAccent`).
    public var accent: SpaceAccent
    /// The window's effective appearance: Light `#F9F9F9` / Dark `#30302E` card.
    public var isDark: Bool
    private var focusOverride: RGBA?

    public init(accent: SpaceAccent, isDark: Bool = false) { self.accent = accent; self.isDark = isDark }

    public init(style: SpaceThemeStyle?, isDark: Bool = false) {
        self.init(accent: SpaceAccent(style: style), isDark: isDark)
    }

    /// Selected row fill: the accent (Light) or the dark accent (Dark). A scope sets the chip color.
    public var focus: RGBA {
        get { focusOverride ?? accent.selection(dark: isDark) }
        set { focusOverride = newValue }
    }
    /// Input text selection: the accent at 55 %.
    public var textSelection: RGBA { accent.accent.withAlpha(CommandCard.textSelectionAlpha) }
    /// The (i) circle.
    public var infoFill: RGBA { CommandCard.infoFill.resolved(appearance) }
    /// The key cap glyph on the selected row.
    public var keyCapGlyph: RGBA { accent.darkAccent }
    public var tint: RGBA { accent.tint(dark: isDark) }
    public var appearance: ContentAppearance { isDark ? .dark : .light }
    public var body: RGBA { CommandCard.body.resolved(appearance) }
    public var text: RGBA { CommandCard.text.resolved(appearance) }
    public var secondaryText: RGBA { CommandCard.secondaryText.resolved(appearance) }
    public var separator: RGBA { CommandCard.separator.resolved(appearance) }
    /// Plates for keycaps and action glyphs on unselected rows. guess (not in the mock-up): the text at 7 %.
    public var plate: RGBA { text.withAlpha(0.07) }

    /// Open's default theme in Light.
    public static let `default` = CommandBarTheme(accent: .night)
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
