import SwiftUI
import AppKit
import OpenModel
import OpenDesign

public struct ArchiveSection: View {
    @Bindable var model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Space", selection: $model.archiveSpaceFilter) { Text("All Spaces").tag(Optional<SpaceID>.none); ForEach(model.model.spaces, id: \.id) { Text(model.model.displayTitle(for: $0)).tag(Optional($0.id)) } }
                Picker("Reason", selection: $model.archiveReasonFilter) { Text("All reasons").tag(Optional<ArchiveReason>.none); ForEach([ArchiveReason.closed, .autoArchived, .clearedToday, .folderDeleted], id: \.self) { Text($0.libraryTitle).tag(Optional($0)) } }
                Picker("Origin", selection: $model.archiveOriginFilter) { Text("All").tag(OriginFilter.all); Text("Spaces").tag(OriginFilter.spaces); Text("Little Open").tag(OriginFilter.littleOpen) }
            }.controlSize(.small)
            HStack { Text("Archive").font(.title2); Spacer(); Button("Delete Selected…", role: .destructive) { model.requestDeleteArchive(model.archiveRows.filter { model.selectedIDs.contains($0.id.description) }.map(\.id)) }.disabled(model.selectedIDs.isEmpty); Button("Clear Archive…") { model.requestClearArchive() } }
            if model.archiveRows.isEmpty && !model.archiveLoading { LibraryEmptyState(title: "No archived tabs", message: "Tabs you close or auto-archive appear here.", symbol: "archivebox") }
            else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.archiveRows) { row in
                        HStack(spacing: 12) {
                            if let data = model.favicons[row.id], let image = NSImage(data: data) { Image(nsImage: image).resizable().frame(width: 20, height: 20) }
                            else { Image(systemName: row.reason == .folderDeleted ? "folder" : "globe").frame(width: 20) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.reason == .folderDeleted ? "Folder · \(model.archivedChildCount(row)) tab(s) · \(row.title)" : row.title).lineLimit(1)
                                Text("\(row.url.host() ?? "") · \(spaceName(row.spaceID)) · \(row.reason.libraryTitle)").font(.caption).foregroundStyle(.secondary)
                            }; Spacer()
                            Text(row.archivedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            Button("Restore") { Task { await model.restore(id: row.id) } }
                            Button { model.requestDeleteArchive([row.id]) } label: { Image(systemName: "trash") }.help("Delete archived tab")
                        }.padding(.vertical, 6).tag(row.id.description)
                        .onTapGesture(count: 2) { Task { await model.restore(id: row.id) } }
                        .contextMenu {
                            Button("Restore") { Task { await model.restore(id: row.id) } }
                            Menu("Restore to Space") { ForEach(model.model.spaces, id: \.id) { space in Button(model.model.displayTitle(for: space)) { Task { await model.restore(id: row.id, to: space.id) } } } }
                            Button("Delete…", role: .destructive) { model.requestDeleteArchive([row.id]) }
                        }
                    }
                    if model.archiveHasMore { ProgressView().frame(maxWidth: .infinity).task { await model.loadNextArchivePage() } }
                }.onDeleteCommand { model.requestDeleteArchive(model.archiveRows.filter { model.selectedIDs.contains($0.id.description) }.map(\.id)) }
            }
        }
        .confirmationDialog("Delete this archived tab? This cannot be undone.", isPresented: Binding(get: { !model.pendingArchiveDeletes.isEmpty }, set: { if !$0 { model.pendingArchiveDeletes = [] } })) { Button("Delete", role: .destructive) { Task { await model.deleteArchiveConfirmed() } } }
        .confirmationDialog("Are you sure you'd like to Clear Archive?", isPresented: $model.confirmsClear, titleVisibility: .visible) { Button("Clear Archive", role: .destructive) { Task { await model.clearArchiveConfirmed() } } } message: { Text("This deletes every archived tab. This cannot be undone.") }
    }
    private func spaceName(_ id: SpaceID?) -> String { id.flatMap { model.model.space(id: $0) }.map { model.model.displayTitle(for: $0) } ?? "Little Open" }
}
extension ArchiveReason {
    var libraryTitle: String { switch self { case .closed: "Closed"; case .autoArchived: "Auto-archived"; case .clearedToday: "Cleared"; case .folderDeleted: "Folder deleted" } }
}
struct LibraryEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View { VStack(spacing: 12) { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary); NativeEmptyStateTitle(title: title).frame(height: 26); Text(message).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine).accessibilityLabel(title + ". " + message) }
}

/// Native text gives never-ordered hosting windows the same concrete AX headline as the app.
private struct NativeEmptyStateTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.alignment = .center
        label.font = Typography.commandBarInput.font; label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText); label.setAccessibilityLabel(title)
        return label
    }
    func updateNSView(_ label: NSTextField, context: Context) { label.stringValue = title; label.setAccessibilityLabel(title) }
}
