import AppKit
import Foundation
import Darwin
import OpenCommands
import OpenDesign
import OpenModel

public enum SettingsSection: String, CaseIterable, Sendable, Identifiable {
    case general, appearance, tabsArchive = "tabs-archive", search, links, downloads, previews
    case adBlocking = "ad-blocking", sitePermissions = "site-permissions", passwordsCards = "passwords-cards", browsingData = "browsing-data"
    case profiles, shortcuts, extensions, advanced
    public var id: String { rawValue }
    public var title: String { switch self {
    case .general: "General"; case .appearance: "Appearance"; case .tabsArchive: "Tabs & Archive"
    case .search: "Search"; case .links: "Links"; case .downloads: "Downloads"; case .previews: "Previews"
    case .adBlocking: "Ad Blocking"; case .sitePermissions: "Site Permissions"; case .passwordsCards: "Passwords & Cards"
    case .browsingData: "Browsing Data"; case .profiles: "Profiles"; case .shortcuts: "Shortcuts"
    case .extensions: "Extensions"; case .advanced: "Advanced"
    } }
    public var subtitle: String { switch self {
    case .general: "How Open starts, updates, and fits into your Mac."
    case .appearance: "The window, the sidebar, and the app icon."
    case .shortcuts: "Type a name, or press keys to find what they do."
    case .tabsArchive: "Keep the tabs you need. Let the rest make room."
    case .search: "Your search engine and its suggestions."
    case .profiles: "Separate your data across Spaces."
    case .links: "Choose where links open."
    case .downloads: "Where this Profile saves your files."
    case .previews: "A quick look before you open."
    case .adBlocking: "Block lists and allowed sites for this Profile."
    case .sitePermissions: "Control what websites can use."
    case .passwordsCards: "Saved passwords and payment methods."
    case .browsingData: "Choose what to keep on this Mac."
    case .extensions: "Add tools to your browser."
    case .advanced: "The details that make Open yours."
    } }
    public var group: String? { switch self {
    case .tabsArchive: "BROWSING"; case .adBlocking: "PRIVACY"; case .profiles: "OPEN"; default: nil
    } }
    public var isPerProfile: Bool { [.tabsArchive, .search, .downloads, .adBlocking, .sitePermissions, .passwordsCards, .browsingData].contains(self) }
    var legacyPane: PaneID { switch self {
    case .general, .previews: .general
    case .appearance: .appIcon
    case .profiles, .search, .downloads, .sitePermissions, .passwordsCards, .browsingData: .profiles
    case .links: .links
    case .shortcuts: .shortcuts
    default: .advanced
    } }
    static func legacy(_ pane: PaneID) -> Self { switch pane {
    case .general: .general; case .profiles: .profiles; case .links: .links
    case .shortcuts: .shortcuts; case .appIcon: .appearance; case .advanced: .advanced
    } }
}

/// One metadata index supplies navigation search and stable section/row links.
/// It contains no view, store, user title or URL. Command-bar clients can reuse it.
public struct SettingsSearchEntry: Identifiable, Sendable {
    public let id: String
    public let section: SettingsSection
    public let label: String
    public let help: String
    public let synonyms: String
    public let defaultsKey: String?
    public let commandID: String?
    let searchable: String
    public init(_ section: SettingsSection, _ row: String, _ label: String, help: String = "", synonyms: String = "", key: String? = nil, commandID: String? = nil) {
        id = section.rawValue + "/" + row; self.section = section; self.label = label; self.help = help
        self.synonyms = synonyms; defaultsKey = key; self.commandID = commandID
        searchable = [label, help, synonyms, section.title, commandID ?? ""].joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    public var url: URL { URL(string: "open://settings/" + id)! }
}

@MainActor public enum SettingsSearchIndex {
    /// Private deep links are metadata IDs, never arbitrary page URLs. Before
    /// splitting/decoding, bound one in-app URL to 2 KiB. No public OS scheme
    /// is registered for these links.
    public static func destination(for url: URL) -> (section: SettingsSection, row: String?)? {
        guard url.absoluteString.utf8.count <= 2_048,
              url.scheme == "open", url.host() == "settings", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count <= 2, let raw = parts.first, let section = SettingsSection(rawValue: raw) else { return nil }
        if parts.count == 2, !entries.contains(where: { $0.id == parts.joined(separator: "/") }) { return nil }
        return (section, parts.count == 2 ? parts[1] : nil)
    }
    public static let entries: [SettingsSearchEntry] = {
        var rows: [SettingsSearchEntry] = [
            .init(.general, "default-browser", "Make Open your default browser", help: "Links from Mail, Messages, and other apps will open here.", synonyms: "default app"),
            .init(.general, "restore-windows", "Restore windows from the previous session", key: "open.advanced.restoreWindowsOnLaunch"),
            .init(.general, "warn-before-quitting", "Warn before quitting", help: "Ask before quitting with downloads in progress.", key: "open.general.warnBeforeQuitting"),
            .init(.general, "automatic-updates", "Update Open automatically", help: "Keep Open up to date.", key: "open.general.automaticallyUpdate"),
            .init(.general, "check-updates", "Check for Updates"),
            .init(.general, "import", "Import from another browser", help: "Bring your bookmarks, history, Spaces, and passwords from Arc, Chrome, and other browsers.", synonyms: "import from arc chrome brave edge vivaldi opera bookmarks history"),
            .init(.general, "export", "Export your Open data", help: "Export your snapshot and Archive index."),
            .init(.appearance, "website-appearance", "Website appearance", help: "Choose Light, Dark, or Match System for websites.", key: "open.web.colorScheme"),
            .init(.appearance, "toolbar", "Show the toolbar", help: "The address and page controls above each page. Applies to the focused browser window."),
            .init(.appearance, "full-url", "Show the full URL", help: "Show the full address when the toolbar is on.", key: "open.advanced.showFullURLWithToolbar"),
            .init(.appearance, "app-icon", "App icon", help: "Choose one of six original Open icons.", key: "open.appIcon.selectedID"),
            .init(.tabsArchive, "archive-after", "Archive tabs after", help: "Today tabs you have not used move to the Archive.", synonyms: "auto-archive timer"),
            .init(.tabsArchive, "little-open-archive", "Archive Little Open windows after", synonyms: "Little Arc"),
            .init(.tabsArchive, "sleep", "Sleep inactive tabs", help: "Sleeping tabs stay in the sidebar. They are not archived.", key: "open.advanced.tabSleepMode"),
            .init(.search, "engine", "Search engine", help: "The default search engine for this Profile."),
            .init(.search, "engines", "Manage search engines", help: "Add, edit, remove, or restore custom search engines."),
            .init(.search, "suggestions", "Include search engine suggestions", help: "We talk to your search engine to help suggest results."),
            .init(.downloads, "location", "Download location", help: "Choose a folder or ask for each download."),
            .init(.downloads, "ask", "Ask where to save each file"),
            .init(.previews, "enabled", "Show Open Previews", key: "open.general.previewsEnabled"),
            .init(.previews, "folders", "Folders", help: "Preview folders on hover.", key: "open.general.previewsFolders"),
            .init(.previews, "pages", "Pinned tabs and Favorites", help: "Preview pages on hover.", key: "open.general.previewsPages"),
            .init(.previews, "recents", "Recent pages on Linear, Notion, Figma, and Confluence", help: "Preview recent pages of these sites on hover.", key: "open.general.previewsRecents"),
            .init(.previews, "calendar", "Upcoming meetings on Google, Outlook, and Notion Calendar", help: "Preview today's meetings and join calls on hover.", key: "open.general.previewsCalendar"),
            .init(.links, "little-open-hotkey", "Open Little Open in any app", key: "open.links.littleOpenHotkeyEnabled"),
            .init(.links, "option-command-click", "Open Little Open with Option-Command-click", key: "open.links.optionCommandClickLittleOpen"),
            .init(.links, "external-links", "Links from other apps open in Little Open", key: "open.links.externalInLittleOpen"),
            .init(.links, "destination", "Default destination", help: "Choose where new links open.", synonyms: "routing"),
            .init(.links, "rules", "Air Traffic Control", help: "Add, edit, delete, and reorder link rules."),
            .init(.links, "test", "Test a Link", help: "Try a URL, source app, and recent Space."),
            .init(.links, "peek-shift-click", "Open Peek with Shift-click", key: "open.links.openPeekShiftClick"),
            .init(.links, "peek-other-sites", "Open Peek for links to other sites", key: "open.links.openPeekOtherSites"),
            .init(.adBlocking, "enabled", "Block ads, trackers, and popups", help: "The main switch applies to all Profiles."),
            .init(.adBlocking, "lists", "Block lists", help: "Choose lists, see update status, or reset list choices."),
            .init(.adBlocking, "allowed-sites", "Don't block on these sites", help: "Add or remove an allowed site."),
            .init(.advanced, "adblock-debug", "Copy debug info", help: "Ad blocking diagnostics for the selected Profile.", synonyms: "Copy Ad Block Debug Info"),
            .init(.sitePermissions, "privacy", "Privacy and Security"),
            .init(.sitePermissions, "notifications", "Notifications"),
            .init(.passwordsCards, "passwords", "Passwords"),
            .init(.passwordsCards, "cards", "Credit Cards"),
            .init(.browsingData, "clear", "Clear Browsing Data", help: "History, cookies, cache, and download history for this Profile."),
            .init(.profiles, "new-documents", "New documents", help: "What New Note creates: a Note, or a Google Doc, Notion, Word, or Confluence page.", synonyms: "default document app note google doc notion word confluence"),
            .init(.profiles, "manage", "Your Profiles", help: "Create, rename, change an icon, assign Spaces, or delete an unused Profile."),
            .init(.profiles, "name", "Profile name"),
            .init(.profiles, "delete", "Delete Profile"),
            .init(.shortcuts, "priority", "When shortcuts conflict", key: "open.shortcuts.defaultPriority"),
             .init(.tabsArchive, "include-favorites", "Include Favorites in tab numbering", synonyms: "shortcut", key: "open.shortcuts.includeFavoritesInTabNumbering"),
             .init(.tabsArchive, "ninth-tab", "Switch to ninth tab", synonyms: "shortcut", key: "open.shortcuts.switchToNinthEnabled"),
            .init(.shortcuts, "essential", "Learn the Essential Shortcuts"),
            .init(.extensions, "manage", "Manage Extensions"),
            .init(.advanced, "sound", "Play Open sound effects", key: "open.advanced.playSoundEffects"),
            .init(.advanced, "haptics", "Haptic feedback when reordering tabs", key: "open.advanced.hapticOnTabReorder"),
            .init(.advanced, "window-dragging", "Allow window dragging from the top of webpages", key: "open.advanced.allowWindowDraggingFromWebTop"),
            .init(.advanced, "shared-quotes", "Enable Shared Quotes when highlighting text", key: "open.advanced.enableSharedQuotes"),
            .init(.advanced, "picture-in-picture", "Enable Picture in Picture when you leave a video tab", key: "open.advanced.enablePictureInPictureOnLeave"),
            .init(.advanced, "theme-data", "Allow websites to get your theme data", key: "open.advanced.allowSitesThemeData"),
            .init(.advanced, "boosts", "Enable Boosts on websites you visit", key: "open.advanced.enableBoosts"),
            .init(.advanced, "more", "More browser settings"),
            .init(.advanced, "translate", "Reset Translated-site Prompts"),
            .init(.advanced, "data-folder", "Show Data Folder"),
            .init(.advanced, "copy-info", "Copy Open Info")
        ]
        rows += CommandRegistry.active.map { .init(.shortcuts, $0.id, $0.title == "Automatic" ? "Use Automatic Appearance" : $0.title, help: $0.scope == .global ? "Works when Open is in the background." : "", synonyms: $0.aliases.joined(separator: " "), commandID: $0.id) }
        return rows
    }()
}

extension SettingsViewModel {
    public func navigate(to section: SettingsSection, row: String? = nil) {
        if selectedSection != section { sectionBack.append(selectedSection); sectionForward.removeAll() }
        if section == .shortcuts, let row {
            let command = row.replacingOccurrences(of: "shortcuts/", with: "")
            if CommandRegistry.byID[command] != nil { shortcuts.query = ""; shortcuts.filter = "all"; shortcuts.category = "all"; shortcuts.findShortcut = nil; shortcuts.selectedCommandID = command }
        }
        searchQuery = ""; selectedSection = section
        scrollTarget = row.map { $0.contains("/") ? $0 : section.rawValue + "/" + $0 }
        arrivalID = scrollTarget; arrivalRevision &+= 1
        onNavigation?()
    }
    public func goBack() {
        guard let section = sectionBack.popLast() else { return }
        sectionForward.append(selectedSection); selectedSection = section; searchQuery = ""; scrollTarget = nil; arrivalID = nil; onNavigation?()
    }
    public func goForward() {
        guard let section = sectionForward.popLast() else { return }
        sectionBack.append(selectedSection); selectedSection = section; searchQuery = ""; scrollTarget = nil; arrivalID = nil; onNavigation?()
    }
    @discardableResult public func openSettingsURL(_ url: URL) -> Bool {
        guard let target = SettingsSearchIndex.destination(for: url) else { return false }
        navigate(to: target.section, row: target.row); return true
    }
    public func updateSettingsSearch() {
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let folded = searchQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let changedOnly = folded.contains("is:changed")
        let words = folded.replacingOccurrences(of: "is:changed", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        searchResults = searchQuery.isEmpty ? [] : SettingsSearchIndex.entries.filter { entry in
            (!changedOnly || isChanged(entry)) && words.allSatisfy { entry.searchable.contains($0) }
        }
        searchSelection = 0
        searchCPUMilliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000
    }
    public func isChanged(_ entry: SettingsSearchEntry) -> Bool {
        if let key = entry.defaultsKey, let expected = SettingsDefaults.values[key] as? NSObject,
           let actual = defaults.object(forKey: key) as? NSObject { _ = preferenceRevision; return actual != expected }
        if let id = entry.commandID { return shortcuts.store.bindings[id] != nil }
        let settings = profiles.profile?.settings
        switch entry.id {
        case "tabs-archive/archive-after": return settings?.autoArchiveAfter != .twelveHours
        case "tabs-archive/little-open-archive": return settings?.littleOpenAutoArchiveAfter != .sixHours
        case "search/engine": return profiles.searchEngineID != "google"
        case "search/engines": return settings?.customSearchEngines.isEmpty == false
        case "links/destination": return links.defaultRoutingDestination != .littleOpen(profile: nil)
        case "links/rules": return !links.drafts.isEmpty
        case "ad-blocking/enabled": return adBlock.map { !$0.enabled } ?? false
        case "ad-blocking/lists": return adBlock.map { $0.isReady && Set($0.enabledIDs) != Set($0.store.catalog.defaultIDs) } ?? false
        case "ad-blocking/allowed-sites": return adBlock.map { !$0.domains.isEmpty } ?? false
        case "search/suggestions": return !profiles.suggestions
        case "profiles/new-documents": return profiles.defaultDocumentApp != DocumentApp.note.id
        case "downloads/ask": return profiles.askWhereToSave
        case "downloads/location": return !["", "~/Downloads"].contains(profiles.downloadDirectory)
        case "appearance/toolbar": return appearanceToolbar
        default: return false
        }
    }
    public func openSearchSelection() {
        guard searchResults.indices.contains(searchSelection) else { return }
        let entry = searchResults[searchSelection]
        if let command = entry.commandID { shortcuts.query = ""; shortcuts.selectedCommandID = command }
        navigate(to: entry.section, row: entry.id)
    }
    public var appearanceToolbar: Bool {
        get { model.windows.first(where: { $0.id == appearanceWindowID })?.showsToolbar ?? model.windows.first?.showsToolbar ?? false }
        set { if let window = model.windows.first(where: { $0.id == appearanceWindowID }) ?? model.windows.first { _ = model.setToolbarShown(windowID: window.id, newValue); save() } }
    }
    public var settingsAccentSource: NSColor? {
        guard let window = model.windows.first(where: { $0.id == appearanceWindowID }) ?? model.windows.first,
              let theme = model.space(id: window.focusedSpaceID)?.theme,
              let color = theme.style?.keyColor ?? theme.accent else { return nil }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
