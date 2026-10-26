import SwiftUI
import OpenModel

public struct HistorySection: View {
    @Bindable var model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 12) {
            HStack { Text("History").font(.title2); Spacer(); Picker("Profile", selection: $model.historyProfileID) { ForEach(model.model.profiles, id: \.id) { Text($0.name).tag($0.id) } } }
            if model.historyRows.isEmpty { LibraryEmptyState(title: "No history", message: "Pages you visit appear here.", symbol: "clock") }
            else { List(selection: $model.selectedIDs) { ForEach(model.historyRows, id: \.url) { row in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) { Text(row.title.isEmpty ? row.url.host() ?? "Page" : row.title).lineLimit(1); Text(row.url.host() ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text("\(row.visitCount) \(row.visitCount == 1 ? "visit" : "visits")").font(.caption).foregroundStyle(.secondary); Text(row.lastVisit, style: .date).font(.caption)
                    Button("Open") { model.actions.openHistoryItem(url: row.url) }
                }.padding(.vertical, 8).tag(row.url.absoluteString).onTapGesture(count: 2) { model.actions.openHistoryItem(url: row.url) }
            } } }
            Text("History is read-only here. Clear browsing data in Profile Settings.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
