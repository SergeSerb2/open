import AppKit
import SwiftUI
import OpenDesign
import OpenModel
import OpenSuggest

struct SettingsSearchSection: View {
    let root: SettingsViewModel
    @Bindable var model: ProfilesViewModel
    @Environment(\.colorScheme) private var scheme
    init(root: SettingsViewModel) { self.root = root; model = root.profiles }
    var body: some View {
        OpenSettingsGroup("Search engine") {
            OpenSettingsRow(root: root, id: "search/engine", title: "Search engine", help: "Use this engine for searches in this Profile.", changed: model.searchEngineID != "google", reset: { model.searchEngineID = "google" }) {
                OpenSettingsPop(title: "Search engine", value: $model.searchEngineID, options: model.engines.map { ($0.name, $0.id) })
            }
            OpenSettingsRow(root: root, id: "search/engines", title: "Manage search engines", help: "Add a site with its own search keyword.", changed: model.profile?.settings.customSearchEngines.isEmpty == false, last: true, reset: { model.restoreBuiltins() }) { Button("Manage…") { root.showsSearchEngines = true } }
        }
        OpenSettingsGroup("Suggestions") {
            OpenSettingsRow(root: root, id: "search/suggestions", title: "Include search engine suggestions", help: "Your search engine receives what you type to suggest results.", changed: !model.suggestions, last: true, reset: { model.suggestions = true }) {
                Toggle("Include search engine suggestions", isOn: $model.suggestions).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: "Include search engine suggestions"))
            }
        }
        SettingsInlineMessage(text: model.errorText)
        .onAppear { model.presentSuggestNotice() }
    }
}

struct SettingsDownloadsSection: View {
    let root: SettingsViewModel
    @Bindable var model: ProfilesViewModel
    @Environment(\.colorScheme) private var scheme
    init(root: SettingsViewModel) { self.root = root; model = root.profiles }
    private var name: String { URL(fileURLWithPath: (model.downloadDirectory as NSString).expandingTildeInPath).lastPathComponent }
    var body: some View {
        OpenSettingsGroup("Saving files") {
            OpenSettingsRow(root: root, id: "downloads/location", title: "Download location", help: model.downloadDirectory.isEmpty ? "~/Downloads" : (model.downloadDirectory as NSString).abbreviatingWithTildeInPath, changed: !["", "~/Downloads"].contains(model.downloadDirectory), reset: { model.downloadDirectory = "~/Downloads" }) {
                Button(name + " · Choose…") { chooseFolder() }
            }
            OpenSettingsRow(root: root, id: "downloads/ask", title: "Ask where to save each file", help: "Choose a location each time a download starts.", changed: model.askWhereToSave, last: true, reset: { model.askWhereToSave = false }) {
                Toggle("Ask where to save each file", isOn: $model.askWhereToSave).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: "Ask where to save each file"))
            }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.downloadDirectory = url.path; model.askWhereToSave = false }
    }
}

struct SettingsPreviewsSection: View {
    let root: SettingsViewModel
    var body: some View {
        OpenSettingsGroup("On hover") {
            OpenPreferenceRow(root: root, id: "previews/enabled", title: "Show Open Previews", key: "open.general.previewsEnabled", help: "Take a quick look without leaving your current page.")
            OpenPreferenceRow(root: root, id: "previews/folders", title: "Folders", key: "open.general.previewsFolders", help: root.bool("open.general.previewsEnabled") ? "Preview the tabs in a folder." : "Turn on Open Previews to preview folders.").disabled(!root.bool("open.general.previewsEnabled"))
            OpenPreferenceRow(root: root, id: "previews/pages", title: "Pinned tabs and Favorites", key: "open.general.previewsPages", help: root.bool("open.general.previewsEnabled") ? "Preview a page from the sidebar." : "Turn on Open Previews to preview pages.", last: true).disabled(!root.bool("open.general.previewsEnabled"))
        }
    }
}

struct SettingsDestinationSection: View {
    let root: SettingsViewModel
    var body: some View {
        SettingsInlineMessage(text: explanation)
        OpenSettingsGroup(root.selectedSection == .extensions ? "Browser tools" : "This Profile") {
            switch root.selectedSection {
            case .sitePermissions:
                destination("site-permissions/privacy", title: "Privacy and Security", help: "Site access, cookies, and security options.", page: .privacy)
                destination("site-permissions/notifications", title: "Notifications", help: "Choose which sites can send notifications.", page: .notifications, last: true)
            case .passwordsCards:
                destination("passwords-cards/passwords", title: "Passwords", help: "View and manage this Profile’s saved passwords.", page: .passwords)
                destination("passwords-cards/cards", title: "Credit Cards", help: "Manage saved cards and payment methods.", page: .paymentMethods, last: true)
            case .browsingData:
                OpenSettingsRow(root: root, id: "browsing-data/clear", title: "Clear Browsing Data", help: "Choose a time range and the data to remove.", last: true) { Button("Choose Data…") { root.profiles.showClear() } }
            case .extensions:
                OpenSettingsRow(root: root, id: "extensions/manage", title: "Manage Extensions", help: "Enable, remove, and configure installed extensions.", last: true) { Button("Open Extensions") { root.actions.openURL(URL(string: "chrome://extensions")!, profileID: root.selectedProfileID) } }
            default: EmptyView()
            }
        }
    }
    private var explanation: String {
        switch root.selectedSection {
        case .browsingData: "Clearing data affects only the selected Profile. You choose what to remove before anything changes."
        case .extensions: "Extension management opens in a browser tab."
        default: "These controls open in a browser tab for the selected Profile."
        }
    }
    private func destination(_ id: String, title: String, help: String, page: ProfilePage, last: Bool = false) -> some View {
        OpenSettingsRow(root: root, id: id, title: title, help: help, last: last) { Button("Open in Tab") { root.profiles.open(page) }.accessibilityLabel("Open " + title + " in Tab") }
    }
}

struct SettingsAdBlockingSection: View {
    let root: SettingsViewModel
    @Bindable var model: AdBlockSettingsModel
    @Environment(\.colorScheme) private var scheme
    init(root: SettingsViewModel, model: AdBlockSettingsModel) { self.root = root; self.model = model }
    var body: some View {
        OpenSettingsGroup("Protection") {
            OpenSettingsRow(root: root, id: "ad-blocking/enabled", title: "Block ads, trackers, and popups", help: "The main switch applies to all Profiles.", changed: !model.enabled, last: true, reset: { model.setEnabled(true) }) {
                Toggle("Block ads, trackers, and popups", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: "Block ads, trackers, and popups"))
            }
        }
        if model.hasOtherBlocker { SettingsInlineMessage(text: "More than one ad blocker is on. Blocking may break sites.") }
        if !model.isReady { SettingsInlineMessage(text: "Block lists are loading for this Profile. Choices will be available when they are ready.") }
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Block lists").font(.system(size: 11, weight: .semibold)); Spacer(); Button("Reset List Choices") { Task { await model.reset() } }.disabled(model.busy || !model.isReady) }
            TextField("Search block lists", text: $model.query).textFieldStyle(.roundedBorder).accessibilityLabel("Search block lists")
            ForEach(["generic", "cookies", "privacy", "regional"], id: \.self) { category in
                let lists = model.lists.filter { $0.category.lowercased() == category && !$0.urls.isEmpty }
                if !lists.isEmpty {
                    DisclosureGroup(category.capitalized) {
                        OpenSettingsCard {
                            ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                                OpenSettingsRow(root: root, id: "ad-blocking/list-" + list.id, title: list.displayName, help: model.listStatus(list), changed: model.isReady && model.enabledIDs.contains(list.id) != list.defaultEnabled, last: index == lists.count - 1, reset: { Task { await model.setList(list.id, enabled: list.defaultEnabled) } }) {
                                    Button { model.openInfo(list) } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).accessibilityLabel("About " + list.displayName)
                                    Toggle(list.displayName, isOn: Binding(get: { model.enabledIDs.contains(list.id) }, set: { on in Task { await model.setList(list.id, enabled: on) } })).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accent.nsColor), label: list.displayName)).disabled(model.busy || !model.isReady)
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.system(size: 13)).padding(12).background(Color(nsColor: SettingsStyle.card.nsColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if model.lists.isEmpty { SettingsInlineMessage(text: "No block lists match this search.") }
        }.id("ad-blocking/lists")
        OpenSettingsGroup("Don’t block on these sites") {
            ForEach(model.domains, id: \.self) { host in
                OpenSettingsRow(root: root, id: "ad-blocking/site-" + host, title: host, changed: true, reset: { model.setExcluded(host, excluded: false) }) { Button("Remove") { model.setExcluded(host, excluded: false) }.disabled(model.busy || !model.isReady) }
            }
            HStack(spacing: 10) { TextField("example.com", text: $model.hostDraft).textFieldStyle(.plain).accessibilityLabel("Allowed site"); Button("Add Site") { model.setExcluded(model.hostDraft, excluded: true) }.disabled(model.hostDraft.isEmpty || model.busy || !model.isReady) }.padding(14)
        }.id("ad-blocking/allowed-sites")
        SettingsInlineMessage(text: model.errorText)
        if let error = model.lastError { SettingsInlineMessage(text: error) }
        Button("Copy Debug Info") { model.copyDebug() }.id("ad-blocking/debug")
    }
}

struct SettingsAdvancedSection: View {
    let root: SettingsViewModel
    var body: some View {
        OpenSettingsGroup("Feedback") {
            row("sound", "Play Open sound effects", key: "playSoundEffects")
            row("haptics", "Haptic feedback when reordering tabs", key: "hapticOnTabReorder", last: true)
        }
        OpenSettingsGroup("Pages") {
            row("window-dragging", "Allow window dragging from the top of webpages", key: "allowWindowDraggingFromWebTop")
            row("shared-quotes", "Enable Shared Quotes when highlighting text", key: "enableSharedQuotes", help: "You can always use Copy URL as Quote from the menu.")
            row("picture-in-picture", "Enable Picture in Picture when you leave a video tab", key: "enablePictureInPictureOnLeave")
            row("theme-data", "Allow websites to get your theme data", key: "allowSitesThemeData")
            row("boosts", "Enable Boosts on websites you visit", key: "enableBoosts", last: true)
        }
        OpenSettingsGroup("Tools") {
            OpenSettingsRow(root: root, id: "advanced/translate", title: "Translated-site prompts", help: "Show translation prompts again for this Profile.") { Button("Reset Prompts") { root.advanced.resetTranslate() } }
            OpenSettingsRow(root: root, id: "advanced/more", title: "More browser settings") { Button("Open in Tab") { root.actions.openMoreSettings() } }
            OpenSettingsRow(root: root, id: "advanced/data-folder", title: "Open data folder") { Button("Show in Finder") { root.actions.revealOpenDataFolder() } }
            OpenSettingsRow(root: root, id: "advanced/copy-info", title: "Open information", last: true) { Button("Copy Info") { root.actions.copyOpenInfoToPasteboard() } }
        }
        SettingsInlineMessage(text: root.advanced.statusText)
    }
    private func row(_ id: String, _ title: String, key: String, help: String = "", last: Bool = false) -> some View {
        OpenPreferenceRow(root: root, id: "advanced/" + id, title: title, key: "open.advanced." + key, help: help, last: last)
    }
}
