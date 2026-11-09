import AppKit
import SwiftUI
import OpenDesign
import OpenModel

public enum BoostsPresentation: String, Sendable { case list, gallery }

public struct BoostItemSnapshot: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let domain: String
    public let pathPrefix: String?
    public let isEnabled: Bool
    public init(id: String, name: String, domain: String, pathPrefix: String? = nil, isEnabled: Bool) {
        self.id = id; self.name = name; self.domain = domain; self.pathPrefix = pathPrefix; self.isEnabled = isEnabled
    }
}
@MainActor public protocol BoostsProvider: AnyObject {
    func boosts(profileID: ProfileID) -> [BoostItemSnapshot]
}

/// Value snapshots keep OpenSettings independent of OpenBoosts and OpenEngine.
public struct BoostsSection: View {
    @Bindable var model: LibraryViewModel
    @AppStorage(BoostPreferences.globallyEnabledKey) private var globallyEnabled = true
    @State private var rename: (item: BoostItemSnapshot, profileID: ProfileID)?
    @State private var renameText = ""
    @State private var deleting: (item: BoostItemSnapshot, profileID: ProfileID)?
    public init(model: LibraryViewModel) {
        self.model = model
        _globallyEnabled = AppStorage(wrappedValue: true, BoostPreferences.globallyEnabledKey, store: model.defaults)
    }
    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Picker("Boosts layout", selection: $model.boostsPresentation) {
                    Text("List").tag(BoostsPresentation.list)
                    Text("Gallery").tag(BoostsPresentation.gallery)
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                    .font(Font(SettingsTokens.label.font))
                    .accessibilityIdentifier("boosts.layout")
            }
            if !globallyEnabled {
                HStack {
                    Text("Boosts are off. Turn them on in Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn On") { globallyEnabled = true }.buttonStyle(SettingsButtonStyle())
                }
            }
            if model.boostItems.isEmpty {
                LibraryEmptyState(title: "Nothing Boosted Yet!", message: "Open a site and choose New Boost in Site Controls.", symbol: "paintbrush.pointed.fill")
            } else if model.boostsPresentation == .gallery {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 22) {
                        ForEach(model.boostItems) { item in
                            BoostGalleryCard(item: item, enabled: enabled(item), edit: edit(item), delete: { requestDelete(item) })
                                .contextMenu { actions(item) }
                        }
                    }
                }.accessibilityIdentifier("boosts.gallery")
            } else {
                List {
                    ForEach(model.boostItems) { item in
                        HStack(spacing: 10) {
                            BoostFavicon(model: model, domain: item.domain).frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name.isEmpty ? item.domain : item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("Made for \(item.domain)\(item.pathPrefix ?? "")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Toggle("Enable \(item.name.isEmpty ? item.domain : item.name)", isOn: enabled(item))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Menu { actions(item) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Boost actions")
                        }.frame(height: 52)
                        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }.listStyle(.plain).accessibilityIdentifier("boosts.list")
            }
        }
        .alert("Rename this Boost", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Boost name", text: $renameText)
            Button("Done") { if let target = rename { model.actions.renameBoost(id: target.item.id, to: renameText, profileID: target.profileID) }; rename = nil }
            Button("Cancel", role: .cancel) { rename = nil }
        }
        .alert("Delete this Boost?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let target = deleting { model.actions.deleteBoost(id: target.item.id, profileID: target.profileID) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .onChange(of: model.historyProfileID) { _, _ in rename = nil; deleting = nil }
    }
    private func enabled(_ item: BoostItemSnapshot) -> Binding<Bool> {
        let profileID = model.historyProfileID
        let actions = model.actions
        return Binding(get: { item.isEnabled }, set: { actions.setBoostEnabled(id: item.id, enabled: $0, profileID: profileID) })
    }
    private func edit(_ item: BoostItemSnapshot) -> () -> Void {
        let profileID = model.historyProfileID
        let actions = model.actions
        return { actions.editBoost(id: item.id, profileID: profileID) }
    }
    private func requestDelete(_ item: BoostItemSnapshot) { deleting = (item, model.historyProfileID) }
    @ViewBuilder private func actions(_ item: BoostItemSnapshot) -> some View {
        Button("Edit…", action: edit(item))
        Button("Rename…") { renameText = item.name; rename = (item, model.historyProfileID) }
        Button("Delete…", role: .destructive) { requestDelete(item) }
    }
}
private struct BoostFavicon: View {
    let model: LibraryViewModel
    let domain: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() }
            else { Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Color(nsColor: Core.brandBlue.nsColor)) }
        }.task(id: domain) {
            if let url = URL(string: "https://\(domain)/"), let data = await model.faviconStore?.icon(for: url)?.png32 { image = NSImage(data: data) }
        }
    }
}

public extension LibraryViewModel {
    var boostItems: [BoostItemSnapshot] {
        (boostsProvider?.boosts(profileID: historyProfileID) ?? []).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.domain.localizedCaseInsensitiveContains(query)
        }
    }
}
