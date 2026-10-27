import Foundation
import Observation
import SwiftUI
import OpenDesign

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
}
public struct GeneralPane: View {
    @Bindable var model: GeneralViewModel
    public init(model: GeneralViewModel) { self.model = model }
    public var body: some View {
        if !model.isDefault {
            HStack(spacing: 8) {
                Text("Open isn't your default browser.")
                Button("Make Open your default") { model.setDefault() }.buttonStyle(SettingsButtonStyle(prominent:true))
            }.font(.system(size: 13)).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:6)).frame(maxWidth:.infinity).padding(.bottom, 9)
        }
        SettingsError(text:model.errorText)
        SettingsGroup {
            SettingsRow(height:37) { HStack(spacing:4) {Text("Automatically update Open");Image(systemName:"info.circle").font(.system(size:11)).foregroundStyle(.secondary).help("Open checks for updates in the background.");Spacer();Toggle("Automatically update Open",isOn:$model.updates).labelsHidden().toggleStyle(.switch).controlSize(.mini)} }
            SettingsRow(height:37,divider:false) { SettingsSwitch("Warn before quitting",isOn:$model.warn).accessibilityIdentifier("warnBeforeQuitPreference") }
        }
        SettingsGroup {
            SettingsRow(height:43) { HStack { Text("Previews");Spacer();Button("Previews Settings…") { model.openPreviews() } } }
            SettingsRow(height:47,divider:false) { HStack(spacing:10) {
                Text("Manage your default search engine, Auto-Archive, and downloads in Profile Settings.").fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0);Button("Profile Settings…") { model.root.selectedPane = .profiles }.fixedSize()
            } }
        }
        SettingsGroup { SettingsRow(divider:false) { HStack { Text("Import from Arc");Spacer();Button("Import…") { model.root.showsImport=true } } } }
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
