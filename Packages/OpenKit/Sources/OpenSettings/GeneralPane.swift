import Foundation
import Observation
import SwiftUI

@MainActor @Observable public final class GeneralViewModel {
    unowned let root: SettingsViewModel
    public var errorText = ""
    public var isDefault: Bool
    public init(root: SettingsViewModel) { self.root = root; isDefault = root.actions.isDefaultBrowser() }
    public var updates: Bool { get { root.bool("open.general.automaticallyUpdate") } set { root.set(newValue, for: "open.general.automaticallyUpdate") } }
    public var warn: Bool { get { root.bool("open.general.warnBeforeQuitting") } set { root.set(newValue, for: "open.general.warnBeforeQuitting") } }
    public func refresh() { isDefault = root.actions.isDefaultBrowser() }
    public func setDefault() { errorText = root.actions.setAsDefaultBrowser() ?? ""; isDefault = root.actions.isDefaultBrowser() }
    public func openPreviews() { root.showsPreviews = true; root.actions.openPreviewsSettings() }
    public var previewDelay: Double { get { _ = root.preferenceRevision; return root.defaults.double(forKey: "open.general.previewsDelaySeconds") } set { root.set(newValue, for: "open.general.previewsDelaySeconds") } }
}
public struct GeneralPane: View {
    @Bindable var model: GeneralViewModel
    public init(model: GeneralViewModel) { self.model = model }
    public var body: some View {
        SettingsGroup("") {
            SettingsSwitch("Automatically update Open", isOn: $model.updates).help("Open checks for updates in the background.")
            Divider()
            SettingsSwitch("Warn before quitting", isOn: $model.warn).accessibilityIdentifier("warnBeforeQuitPreference")
        }.toggleStyle(.switch).controlSize(.small)
        SettingsGroup("") {
            PreferenceToggle(title: "Previews", key: "open.general.previewsEnabled", root: model.root)
            HStack { Spacer(); Button("Previews Settings…") { model.openPreviews() } }
        }
        SettingsGroup("") {
            Text("Manage your default search engine, Auto-Archive, and downloads in Profile Settings.").foregroundStyle(.secondary)
            HStack { Spacer(); Button("Profile Settings…") { model.root.selectedPane = .profiles } }
        }
        SettingsGroup("Default Browser") {
            Text(model.isDefault ? "Open is your default browser." : "Open isn't your default browser.")
            Button("Set as Default Browser") { model.setDefault() }.disabled(model.isDefault)
            SettingsError(text: model.errorText)
        }
        SettingsGroup("Import") { Button("Import from Arc…") { model.root.showsImport = true } }
    }
}
struct PreviewsSheet: View {
    @Bindable var model: GeneralViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Previews").font(.title2)
            PreferenceToggle(title: "Previews", key: "open.general.previewsEnabled", root: model.root)
            PreferenceToggle(title: "Show previews when hovering links", key: "open.general.previewsOnHover", root: model.root)
            Picker("Delay", selection: $model.previewDelay) { Text("0.3 s").tag(0.3); Text("0.5 s").tag(0.5); Text("1 s").tag(1.0) }
            Spacer(); HStack { Spacer(); Button("Done") { model.root.showsPreviews = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480, height: 320)
    }
}
