import AppKit
import SwiftUI
import OpenDesign
import OpenModel
import OpenCommands
import QuartzCore

struct SettingsDetail: View {
    @Bindable var root: SettingsViewModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if root.searchQuery.isEmpty {
                        header
                        section
                    } else { SettingsSearchResults(root: root) }
                }
                #if DEBUG || OPEN_AUTOMATION
                .background(SettingsSectionDrawMarker(root: root, section: root.selectedSection).allowsHitTesting(false))
                #endif
                .modifier(SettingsSectionArrival(section: root.selectedSection))
                .frame(maxWidth: SettingsStyle.columnWidth, alignment: .leading)
                .padding(.top, SettingsStyle.topInset).padding(.bottom, 28)
                .id("settings-top")
                .frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 24)
            }
            .task(id: root.arrivalRevision) {
                await Task.yield()
                proxy.scrollTo(root.scrollTarget ?? "settings-top", anchor: root.scrollTarget == nil ? .top : .center)
            }
            .onChange(of: root.selectedSection) { _, _ in if root.scrollTarget == nil { proxy.scrollTo("settings-top", anchor: .top) } }
        }
        .buttonStyle(OpenSettingsButtonStyle())
    }
    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(root.selectedSection.title).font(.system(size: 22, weight: .semibold)).tracking(-0.44)
                Text(root.selectedSection.subtitle).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            }
            Spacer(minLength: 8)
            if root.selectedSection.isPerProfile { SettingsProfilePill(root: root) }
            if root.selectedSection == .shortcuts { Button("Reset All…") { root.shortcuts.resetAll(confirmed: false) }.accessibilityLabel("Reset All Shortcuts") }
        }.id("settings-header").padding(.bottom, 0)
    }
    @ViewBuilder private var section: some View {
        switch root.selectedSection {
        case .general: GeneralPane(model: root.general)
        case .appearance: SettingsAppearance(root: root)
        case .shortcuts: ShortcutsPane(model: root.shortcuts)
        case .tabsArchive: SettingsArchiveControls(root: root)
        case .profiles: ProfilesPane(model: root.profiles)
        case .links: LinksPane(root: root)
        case .advanced: SettingsAdvancedSection(root: root)
        case .previews: SettingsPreviewsSection(root: root)
        case .search: SettingsSearchSection(root: root)
        case .downloads: SettingsDownloadsSection(root: root)
        case .adBlocking:
            if let ad = root.adBlock { SettingsAdBlockingSection(root: root, model: ad) }
            else { SettingsInlineMessage(text: "Ad blocking settings could not be opened.") }
        case .sitePermissions, .passwordsCards, .browsingData, .extensions: SettingsDestinationSection(root: root)
        }
    }
}

struct SettingsProfilePill: View {
    let root: SettingsViewModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        OpenSettingsPop(title: "Profile", value: Binding(get: { root.selectedProfileID }, set: { root.profiles.select($0) }), options: root.model.profiles.map { ($0.name, $0.id) }, profile: true, accent: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark))
            .disabled(root.selectedSection == .adBlocking && root.adBlock?.busy == true)
    }
}

struct SettingsArchiveControls: View {
    let root: SettingsViewModel
    @Bindable var profiles: ProfilesViewModel
    init(root: SettingsViewModel) { self.root = root; profiles = root.profiles }
    var body: some View {
        OpenSettingsGroup("Archive") {
            OpenSettingsRow(root: root, id: "tabs-archive/archive-after", title: "Archive tabs after", help: "Today tabs you have not used move to the Archive.", changed: profiles.profile?.settings.autoArchiveAfter != .twelveHours,
                reset: { profiles.proposeArchive(.twelveHours); profiles.applyArchive(all: false) }) {
                OpenSettingsPop(title: "Archive tabs after", value: Binding(get: { profiles.profile?.settings.autoArchiveAfter ?? .twelveHours }, set: { profiles.proposeArchive($0); profiles.applyArchive(all: false); root.archiveApplyAvailable = true }), options: AutoArchiveInterval.allCases.map { ($0.settingsTitle, $0) })
            }
            OpenSettingsRow(root: root, id: "tabs-archive/little-open-archive", title: "Archive Little Open windows after", changed: profiles.profile?.settings.littleOpenAutoArchiveAfter != .sixHours, last: true,
                reset: { root.links.littleOpenAutoArchiveAfter = .sixHours; root.commitLinks() }) {
                OpenSettingsPop(title: "Archive Little Open windows after", value: Binding(get: { root.links.littleOpenAutoArchiveAfter }, set: { root.links.littleOpenAutoArchiveAfter = $0; root.commitLinks() }), options: AutoArchiveInterval.allCases.map { ($0.settingsTitle, $0) })
            }
        }
        if root.archiveApplyAvailable {
            HStack { Text("Changed for \(profiles.profile?.name ?? "this Profile").").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)); Spacer()
                Button("Apply to all Profiles") { let value = profiles.profile?.settings.autoArchiveAfter ?? .twelveHours; profiles.proposeArchive(value); profiles.applyArchive(all: true); root.archiveApplyAvailable = false }.buttonStyle(.plain).font(.system(size: 11.5))
            }
        }
        OpenSettingsGroup("Tab numbering") {
            OpenPreferenceRow(root: root, id: "tabs-archive/include-favorites", title: "Include Favorites in tab numbering", key: "open.shortcuts.includeFavoritesInTabNumbering")
            OpenPreferenceRow(root: root, id: "tabs-archive/ninth-tab", title: "Switch to ninth tab", key: "open.shortcuts.switchToNinthEnabled", last: true)
        }
        OpenSettingsGroup("Memory") {
            OpenSettingsRow(root: root, id: "tabs-archive/sleep", title: "Sleep inactive tabs", help: "Sleeping tabs stay in the sidebar. They are not archived. This setting applies to all Profiles.", changed: root.advanced.sleepMode != .automatic, last: true, reset: { root.advanced.sleepMode = .automatic }) {
                OpenSettingsPop(title: "Sleep inactive tabs", value: Binding(get: { root.advanced.sleepMode }, set: { root.advanced.sleepMode = $0 }), options: TabSleepMode.allCases.map { ($0.rawValue.capitalized, $0) })
            }
        }
    }
}

struct SettingsSearchResults: View {
    let root: SettingsViewModel
    @State private var hoveredResultID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(root.searchResults.count) \(root.searchResults.count == 1 ? "result" : "results") for “\(root.searchQuery)”").font(.system(size: 22, weight: .semibold)).tracking(-0.44)
                Text("↑↓ to move · Return to open · Esc to clear").font(.system(size: 12.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            }
            Spacer(minLength: 8)
        }
        if root.searchResults.isEmpty { SettingsInlineMessage(text: "No settings found. Try a shorter name or a shortcut command.") }
        ForEach(SettingsSection.allCases) { section in
            let entries = root.searchResults.filter { $0.section == section }
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                        Spacer()
                        if section.isPerProfile { SettingsProfilePill(root: root) }
                    }.padding(.leading, 4)
                    OpenSettingsCard {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            searchRow(entry, last: index == entries.count - 1)
                        }
                    }
                }
            }
        }
    }
    private func searchRow(_ entry: SettingsSearchEntry, last: Bool) -> some View {
        let selected = root.searchResults.indices.contains(root.searchSelection) && root.searchResults[root.searchSelection].id == entry.id
        return Button {
            root.searchSelection = root.searchResults.firstIndex(where: { $0.id == entry.id }) ?? 0; root.openSearchSelection()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlight(entry.label)).font(.system(size: 13))
                    if !entry.help.isEmpty { Text(highlight(entry.help)).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let id = entry.commandID, let command = CommandRegistry.byID[id] {
                    if let key = root.shortcuts.store.effectiveShortcuts(for: command).first { SettingsKeycaps(shortcut: key) }
                    else if command.isCustomizable { Text("Add shortcut").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).opacity(selected || hoveredResultID == entry.id ? 1 : 0) }
                }
                else if let value = value(entry) { Text(value).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 26).background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 7)) }
                if selected { Text("↩").foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).font(.system(size: 11)) }
            }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: entry.help.isEmpty ? 44 : 60)
                .background(selected ? Color(nsColor: SettingsStyle.accent.nsColor).opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) } }
        }.transition(.opacity).animation((Motion.reduceMotionOverride ?? reduceMotion) ? nil : .easeOut(duration: SettingsStyle.searchDuration), value: root.searchResults.map(\.id)).buttonStyle(.plain).background(SettingsHoverRegion(hovered: Binding(get: { hoveredResultID == entry.id }, set: { hoveredResultID = $0 ? entry.id : nil })).allowsHitTesting(false)).accessibilityLabel(entry.label + ", " + entry.section.title).accessibilityIdentifier("settings-result-" + entry.id)
    }
    private func highlight(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        let words = root.searchQuery.replacingOccurrences(of: "is:changed", with: "").split(whereSeparator: \.isWhitespace)
        for word in words {
            var searchStart = source.startIndex
            while searchStart < source.endIndex, let range = source.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<source.endIndex) {
                if let attributed = Range(range, in: result) { result[attributed].backgroundColor = Color(nsColor: SettingsStyle.sunStart.nsColor).opacity(0.4) }
                searchStart = range.upperBound
            }
        }
        return result
    }
    private func value(_ entry: SettingsSearchEntry) -> String? {
        switch entry.id {
        case "tabs-archive/archive-after": root.profiles.profile?.settings.autoArchiveAfter.settingsTitle
        case "tabs-archive/little-open-archive": root.profiles.profile?.settings.littleOpenAutoArchiveAfter.settingsTitle
        case "tabs-archive/sleep": root.advanced.sleepMode.rawValue.capitalized
        default: nil
        }
    }
}

/// A finite arrival animation; no timer or repeating work remains at rest.
private struct SettingsSectionArrival: ViewModifier {
    let section: SettingsSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 1.0
    @State private var rise = 0.0
    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: rise).task(id: section) {
            let reduced = Motion.reduceMotionOverride ?? reduceMotion
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { opacity = 0; rise = reduced ? 0 : 6 }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: SettingsStyle.sectionDuration)) { opacity = 1; rise = 0 }
        }
    }
}

#if DEBUG || OPEN_AUTOMATION
private struct SettingsSectionDrawMarker: NSViewRepresentable {
    let root: SettingsViewModel
    let section: SettingsSection
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.report = { root.onSectionDraw?(section, CACurrentMediaTime()) }
        view.needsDisplay = true
    }
    @MainActor final class Marker: NSView {
        var report: (() -> Void)?
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { report?() }
    }
}
#endif
