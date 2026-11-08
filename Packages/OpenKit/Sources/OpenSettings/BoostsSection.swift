import AppKit
import SwiftUI
import OpenDesign
import OpenModel

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
    @AppStorage("open.advanced.enableBoosts") private var globallyEnabled = true
    @State private var rename: BoostItemSnapshot?
    @State private var renameText = ""
    @State private var deleting: BoostItemSnapshot?
    public init(model: LibraryViewModel) {
        self.model = model
        _globallyEnabled = AppStorage(wrappedValue: true, "open.advanced.enableBoosts", store: model.defaults)
    }
    public var body: some View {
        VStack(spacing: 12) {
            if !globallyEnabled {
                HStack {
                    Text("Boosts are off. Turn them on in Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn On") { globallyEnabled = true }.buttonStyle(SettingsButtonStyle())
                }
            }
            if model.boostItems.isEmpty {
                LibraryEmptyState(title: "Nothing Boosted Yet!", message: "Open a site and choose New Boost in Site Controls.", symbol: "paintbrush.pointed.fill")
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
                            Toggle("Enable \(item.name.isEmpty ? item.domain : item.name)", isOn: Binding(get: { item.isEnabled }, set: {
                                model.actions.setBoostEnabled(id: item.id, enabled: $0, profileID: model.historyProfileID)
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Menu {
                                Button("Edit…") { model.actions.editBoost(id: item.id, profileID: model.historyProfileID) }
                                Button("Rename…") { renameText = item.name; rename = item }
                                Button("Delete…", role: .destructive) { deleting = item }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Boost actions")
                        }.frame(height: 52)
                        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }.listStyle(.plain)
            }
        }
        .alert("Rename this Boost", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Boost name", text: $renameText)
            Button("Done") { if let item = rename { model.actions.renameBoost(id: item.id, to: renameText, profileID: model.historyProfileID) }; rename = nil }
            Button("Cancel", role: .cancel) { rename = nil }
        }
        .alert("Delete this Boost?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let item = deleting { model.actions.deleteBoost(id: item.id, profileID: model.historyProfileID) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
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
