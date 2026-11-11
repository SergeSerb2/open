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
    let section: SettingsSection
    var body: some View {
        SettingsInlineMessage(text: explanation)
        OpenSettingsGroup(section == .extensions ? "Browser tools" : "This Profile") {
            switch section {
            case .sitePermissions:
                destination("site-permissions/privacy", title: "Privacy and Security", help: "Site access, cookies, and security options.", page: .privacy)
                destination("site-permissions/notifications", title: "Notifications", help: "Choose which sites can send notifications.", page: .notifications, last: true)
            case .passwordsCards:
                destination("passwords-cards/passwords", title: "Passwords", help: "View and manage this Profile’s saved passwords.", page: .passwords)
                destination("passwords-cards/cards", title: "Credit Cards", help: "Manage saved cards and payment methods.", page: .paymentMethods, last: true)
            case .browsingData:
                OpenSettingsRow(root: root, id: "browsing-data/clear", title: "Clear Browsing Data", help: "Choose a time range and the data to remove.", last: true) { Button("Choose data…") { root.profiles.showClear() } }
            case .extensions:
                OpenSettingsRow(root: root, id: "extensions/manage", title: "Manage Extensions", help: "Enable, remove, and configure installed extensions.", last: true) { Button("Open extensions") { root.actions.openURL(URL(string: "chrome://extensions")!, profileID: root.selectedProfileID) } }
            default: EmptyView()
            }
        }
    }
    private var explanation: String {
        switch section {
        case .browsingData: "Clearing data affects only the selected Profile. You choose what to remove before anything changes."
        case .extensions: "Extension management opens in a browser tab."
        default: "These controls open in a browser tab for the selected Profile."
        }
    }
    private func destination(_ id: String, title: String, help: String, page: ProfilePage, last: Bool = false) -> some View {
        OpenSettingsRow(root: root, id: id, title: title, help: help, last: last) { Button("Open in tab") { root.profiles.open(page) }.accessibilityLabel("Open " + title + " in Tab") }
    }
}

struct SettingsAdBlockingSection: View {
    let root: SettingsViewModel
    @Bindable var model: AdBlockSettingsModel
    @State private var expanded: Set<String> = []
    @Environment(\.colorScheme) private var scheme
    init(root: SettingsViewModel, model: AdBlockSettingsModel) { self.root = root; self.model = model }
    private var accent: Color { Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)) }
    private var changedLists: Bool { model.isReady && Set(model.enabledIDs) != Set(model.store.catalog.defaultIDs) }
    var body: some View {
        OpenSettingsGroup("Protection") {
            OpenSettingsRow(root: root, id: "ad-blocking/enabled", title: "Block ads, trackers, and popups", help: "The main switch applies to all Profiles.", changed: !model.enabled, last: true, reset: { model.setEnabled(true) }) {
                Toggle("Block ads, trackers, and popups", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })).toggleStyle(OpenSettingsSwitchStyle(accent: accent, label: "Block ads, trackers, and popups"))
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Block lists").font(.system(size: 11, weight: .semibold))
                if changedLists {
                    Button("↺ Reset") { Task { await model.reset() } }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(accent).accessibilityLabel("Reset lists").disabled(model.busy)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search block lists", text: $model.query).textFieldStyle(.plain).accessibilityLabel("Search block lists")
                }.font(.system(size: 11.5)).padding(.horizontal, 8).frame(width: 200, height: 26)
                    .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
            }.foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).padding(.leading, 4)
            OpenSettingsCard {
                ForEach(["generic", "cookies", "privacy", "regional"], id: \.self) { category in
                    categoryRows(category)
                }
            }
        }.padding(.top, 24).id("ad-blocking/lists")
        OpenSettingsGroup("Don’t block on these sites") {
            HStack(spacing: 10) {
                TextField("example.com", text: $model.hostDraft).textFieldStyle(.plain).accessibilityLabel("Allowed site")
                    .padding(.horizontal, 8).frame(height: 26).background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit { if model.validHostDraft { model.setExcluded(model.hostDraft, excluded: true) } }
                Button("Add site") { model.setExcluded(model.hostDraft, excluded: true) }.disabled(!model.validHostDraft || model.busy || !model.isReady)
            }.padding(.horizontal, 14).frame(height: 44)
            if model.domains.isEmpty {
                Text("No sites yet.").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 36)
            }
            ForEach(Array(model.domains.enumerated()), id: \.element) { index, host in
                SettingsAllowedSiteRow(host: host, disabled: model.busy || !model.isReady, last: index == model.domains.count - 1) { model.setExcluded(host, excluded: false) }
            }
        }.id("ad-blocking/allowed-sites")
        let notice = !model.errorText.isEmpty ? model.errorText : model.lastError ?? (!model.isReady ? "Block lists are loading for this Profile. Choices will be available when they are ready." : model.hasOtherBlocker ? "More than one ad blocker is on. Blocking may break sites." : "")
        SettingsInlineMessage(text: notice).padding(.top, notice.isEmpty ? 0 : 12)
    }
    @ViewBuilder private func categoryRows(_ category: String) -> some View {
        let all = model.store.catalog.lists.filter { $0.category.lowercased() == category && !$0.urls.isEmpty }
        let lists = model.lists.filter { $0.category.lowercased() == category && !$0.urls.isEmpty }
        Button {
            if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded.contains(category) ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).frame(width: 10)
                Text(category.capitalized).font(.system(size: 13))
                Spacer()
                Text("\(all.filter { model.enabledIDs.contains($0.id) }.count) of \(all.count) on").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(category.capitalized).accessibilityValue(expanded.contains(category) ? "Expanded" : "Collapsed")
        if expanded.contains(category) || !model.query.isEmpty {
            ForEach(lists, id: \.id) { list in
                OpenSettingsRow(root: root, id: "ad-blocking/list-" + list.id, title: list.displayName, help: model.listSourceStatus(list),
                    changed: model.isReady && model.enabledIDs.contains(list.id) != list.defaultEnabled,
                    reset: { Task { await model.setList(list.id, enabled: list.defaultEnabled) } },
                    checkbox: Binding(get: { model.enabledIDs.contains(list.id) }, set: { on in Task { await model.setList(list.id, enabled: on) } })) {
                    Button { model.openInfo(list) } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).accessibilityLabel("About " + list.displayName)
                }.padding(.leading, 18).disabled(model.busy || !model.isReady)
            }
            if lists.isEmpty { Text("No block lists match this search.").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).padding(.leading, 32).padding(.bottom, 12) }
        }
        if category != "regional" { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) }
    }
}

private struct SettingsAllowedSiteRow: View {
    let host: String
    let disabled: Bool
    let last: Bool
    let remove: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(host).font(.system(size: 13)); Spacer()
            Button("–", action: remove).buttonStyle(.plain).font(.system(size: 16)).frame(width: 26, height: 26).opacity(hovered || focused ? 1 : 0).accessibilityLabel("Remove " + host).disabled(disabled).focused($focused)
        }.padding(.horizontal, 14).frame(height: 44)
            .background(SettingsHoverRegion(hovered: $hovered).allowsHitTesting(false))
            .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) }
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
            OpenSettingsRow(root: root, id: "advanced/translate", title: "Translated-site prompts", help: "Show translation prompts again for this Profile.") { Button("Reset prompts") { root.advanced.resetTranslate() } }
            OpenSettingsRow(root: root, id: "advanced/more", title: "More browser settings") { Button("Open in tab") { root.actions.openMoreSettings() } }
            OpenSettingsRow(root: root, id: "advanced/data-folder", title: "Open data folder") { Button("Show in Finder") { root.actions.revealOpenDataFolder() } }
            OpenSettingsRow(root: root, id: "advanced/copy-info", title: "Open information", last: true) { Button("Copy info") { root.actions.copyOpenInfoToPasteboard() } }
        }
        OpenSettingsGroup("Diagnostics") {
            OpenSettingsRow(root: root, id: "advanced/adblock-debug", title: "Ad blocking", help: "Diagnostics for \(root.profiles.profile?.name ?? "the selected Profile").", last: true) {
                Button("Copy debug info") { root.adBlock?.copyDebug() }.disabled(root.adBlock?.isReady != true)
            }
        }
        SettingsInlineMessage(text: root.advanced.statusText)
    }
    private func row(_ id: String, _ title: String, key: String, help: String = "", last: Bool = false) -> some View {
        OpenPreferenceRow(root: root, id: "advanced/" + id, title: title, key: "open.advanced." + key, help: help, last: last)
    }
}
