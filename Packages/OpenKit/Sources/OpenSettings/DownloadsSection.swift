import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel

public struct DownloadsSection: View {
    @Bindable var model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Downloads").font(.title2); Spacer()
                Picker("Status", selection: $model.downloadStateFilter) { Text("All").tag(Optional<DownloadState>.none); Text("In Progress").tag(Optional(DownloadState.inProgress)); Text("Completed").tag(Optional(DownloadState.completed)); Text("Failed").tag(Optional(DownloadState.failed)) }
                Picker("Profile", selection: $model.downloadProfileFilter) { Text("All Profiles").tag(Optional<ProfileID>.none); ForEach(model.model.profiles, id: \.id) { Text($0.name).tag(Optional($0.id)) } }
            }
            if model.downloadItems.isEmpty { LibraryEmptyState(title: "No downloads", message: "Files you download appear here.", symbol: "arrow.down.circle") }
            else { List(selection: $model.selectedIDs) { ForEach(model.downloadItems) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(fileURLWithPath: item.fileName).pathExtension) ?? .data)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(item.fileName).lineLimit(1); Spacer(); Text(item.state == .inProgress ? "Downloading" : item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                        Text("Download from \(item.sourceHost)").font(.caption).foregroundStyle(.secondary)
                        if item.state == .inProgress || item.state == .paused {
                            if let progress = item.progress { ProgressView(value: progress).accessibilityLabel("Download progress").accessibilityValue("\(Int(progress * 100)) percent") } else { ProgressView().controlSize(.small) }
                            Text("\(bytes(item.receivedBytes))\(item.totalBytes.map { " of " + bytes($0) } ?? "") · \(bytes(item.bytesPerSecond))/s").font(.caption).foregroundStyle(.secondary)
                        }
                        if item.state == .completed { Text(model.fileAvailable(item) ? model.downloadLocation(item) : "File moved or deleted.").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        HStack {
                            if item.state == .inProgress { Button("Pause") { model.actions.pauseDownload(id: item.id) }; Button("Cancel") { model.actions.cancelDownload(id: item.id) } }
                            if item.state == .paused { Button("Resume") { model.actions.resumeDownload(id: item.id) }; Button("Cancel") { model.actions.cancelDownload(id: item.id) } }
                            if item.state == .failed { Button("Retry") { model.retryDownload(item) } }
                            if item.state == .completed { Button("Show in Finder") { model.revealDownload(item) }.disabled(!model.fileAvailable(item)); Button("Open") { model.actions.openDownload(id: item.id) }.disabled(!model.fileAvailable(item)) }
                            Spacer(); Button("Remove from List") { model.actions.removeDownload(id: item.id) }
                        }.controlSize(.small)
                    }
                }.padding(.vertical, 10).tag(item.id).onTapGesture(count: 2) { if item.state == .completed { model.revealDownload(item) } }
            } } }
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
