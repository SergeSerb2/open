import AppKit
import Foundation
import Observation
import SwiftUI
import OpenDesign
import OpenOnboarding

@MainActor @Observable public final class GeneralViewModel {
    unowned let root: SettingsViewModel
    public var errorText = ""
    public var isDefault: Bool
    public init(root: SettingsViewModel) { self.root = root; isDefault = root.actions.isDefaultBrowser() }
    public var updates: Bool { get { root.bool("open.general.automaticallyUpdate") } set { root.set(newValue, for: "open.general.automaticallyUpdate") } }
    public var warn: Bool { get { root.bool("open.general.warnBeforeQuitting") } set { root.set(newValue, for: "open.general.warnBeforeQuitting") } }
    public func refresh() { isDefault = root.actions.isDefaultBrowser() }
    public func setDefault() { errorText = root.actions.setAsDefaultBrowser() ?? ""; isDefault = root.actions.isDefaultBrowser() }
    public func checkForUpdates() { root.actions.checkForUpdates() }
    public func openUpdatesHelp() { root.actions.openURL(URL(string: "https://github.com/SergeSerb2/open#updates")!, profileID: root.selectedProfileID) }
    public func openPreviews() { root.navigate(to: .previews) }
}
public struct GeneralPane: View {
    @Bindable var model: GeneralViewModel
    @Environment(\.colorScheme) private var scheme
    public init(model: GeneralViewModel) { self.model = model }
    public var body: some View {
        if !model.isDefault { defaultBrowser.padding(.top, 18) }
        SettingsInlineMessage(text: model.errorText.isEmpty ? model.root.advanced.statusText : model.errorText)
        OpenSettingsGroup("Startup") {
            OpenPreferenceRow(root: model.root, id: "general/restore-windows", title: "Restore windows from the previous session", key: "open.advanced.restoreWindowsOnLaunch")
            OpenPreferenceRow(root: model.root, id: "general/warn-before-quitting", title: "Warn before quitting", key: "open.general.warnBeforeQuitting", help: "Ask before quitting with downloads in progress.", last: true)
                .accessibilityIdentifier("warnBeforeQuitPreference")
        }
        OpenSettingsGroup("Updates") {
            OpenSettingsRow(root: model.root, id: "general/automatic-updates", title: "Update Open automatically", help: "Keep Open up to date.", changed: !model.updates, last: true, reset: { model.updates = true }, helpAction: { model.openUpdatesHelp() }) {
                Toggle("Update Open automatically", isOn: $model.updates).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(model.root.settingsAccentSource, dark: scheme == .dark)), label: "Update Open automatically"))
            }
        }
        OpenSettingsGroup("Move in") {
            OpenSettingsRow(root: model.root, id: "general/import", title: "Import from Arc", help: "Bring your Spaces, tabs, bookmarks, and passwords into Open.") {
                Button("Import…") { model.root.showsImport = true }
            }
            OpenSettingsRow(root: model.root, id: "general/export", title: "Export your Open data", last: true) {
                Button("Export…") { exportData() }
            }
        }

    }
    private var defaultBrowser: some View {
        HStack(spacing: 16) {
            SettingsDoorwayMark().frame(width: 42, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text("Make Open your default browser").font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                Text("Links from Mail, Messages, and other apps will open here.").font(.system(size: 12)).foregroundStyle(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Set as default") { model.setDefault() }.buttonStyle(OpenSettingsButtonStyle(attention: true)).fixedSize()
        }.padding(.horizontal, 18).frame(minHeight: 92)
            .foregroundStyle(Color(nsColor: SettingsStyle.white.nsColor))
            .background(RadialGradient(colors: SettingsStyle.hero.map { Color(nsColor: $0.nsColor) }, center: .bottomLeading, startRadius: 0, endRadius: 650), in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottomLeading) {
                Ellipse().fill(Color(nsColor: SettingsStyle.sunEnd.nsColor).opacity(0.3)).frame(width: 160, height: 32).blur(radius: 24).offset(x: -30, y: 12).allowsHitTesting(false)
            }.clipShape(RoundedRectangle(cornerRadius: 14))
            .id("general/default-browser").accessibilityIdentifier("general/default-browser")
    }
    private func exportData() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Open-export.json"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.root.advanced.export(to: url) } }
    }
}

struct SettingsDoorwayMark: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            SettingsDoorwayShape()
                .fill(LinearGradient(colors: [Color(nsColor: SettingsStyle.sunStart.nsColor).opacity(0.5), Color(nsColor: SettingsStyle.sunEnd.nsColor).opacity(0.12)], startPoint: .topTrailing, endPoint: .bottomLeading))
                .overlay(SettingsDoorwayShape().stroke(Color(nsColor: SettingsStyle.white.nsColor), lineWidth: 3))
                .frame(width: 32, height: 46).offset(x: -7, y: 6)
            Circle().fill(RadialGradient(colors: [Color(nsColor: SettingsStyle.white.nsColor), Color(nsColor: SettingsStyle.sunStart.nsColor), Color(nsColor: SettingsStyle.sunEnd.nsColor)], center: .topLeading, startRadius: 0, endRadius: 20)).frame(width: 18, height: 18)
                .shadow(color: Color(nsColor: SettingsStyle.sunStart.nsColor).opacity(0.55), radius: 8)
        }
    }
}
private struct SettingsDoorwayShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The shared mark landed with PR306. Keep the approved compact
        // Settings proportions, 5 pt lower corners and 3 pt white stroke.
        Path(OnboardingBrandMark.path(in: rect, bottomCornerRadius: 5))
    }
}

public struct PreviewsSheet: View {
    @Bindable var model: GeneralViewModel
    public init(model:GeneralViewModel) {self.model=model}
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Previews").font(.title2)
            PreferenceToggle(title: "Show Open Previews:", key: "open.general.previewsEnabled", root: model.root)
            PreferenceToggle(title: "Folders", key: "open.general.previewsFolders", root: model.root).disabled(!model.root.bool("open.general.previewsEnabled"))
            PreferenceToggle(title: "Pinned tabs and Favorites", key: "open.general.previewsPages", root: model.root).disabled(!model.root.bool("open.general.previewsEnabled"))
            Spacer(); HStack { Spacer(); Button("Done") { model.root.showsPreviews = false }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true)) }
        }.padding(24).frame(width: 480, height: 320).buttonStyle(SettingsButtonStyle())
    }
}
