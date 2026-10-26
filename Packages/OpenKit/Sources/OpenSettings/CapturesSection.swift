import SwiftUI
import AppKit

public struct CapturesSection: View {
    @Bindable var model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 16) {
            if model.captureItems.isEmpty { LibraryEmptyState(title: "No captures", message: "Captures you save in Open appear here.", symbol: "camera") }
            else {
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 22) { ForEach(model.captureItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geometry in
                            ZStack {
                                RoundedRectangle(cornerRadius:8).fill(.quaternary)
                                if let data=model.thumbnails[item.id],let image=NSImage(data:data) {Image(nsImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:150).clipped()}
                                else {Image(systemName:"photo").foregroundStyle(.secondary)}
                            }.frame(width:geometry.size.width,height:150).clipShape(RoundedRectangle(cornerRadius:8))
                        }.frame(height:150).task {await model.loadThumbnail(item)}
                        Text(item.fileName).lineLimit(1)
                        Text("\(item.createdAt.formatted(.dateTime.month(.abbreviated).day())) · \(item.sourceHost)").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(10).background(model.selectedIDs.contains(item.id.uuidString) ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { model.selectedIDs = [item.id.uuidString] }
                    .onTapGesture(count: 2) { model.actions.openCapture(id: item.id) }
                    .contextMenu { captureActions(item) }
                } } }
            }
        }.confirmationDialog("This will permanently delete your capture.", isPresented: Binding(get: { model.pendingCaptureDelete != nil }, set: { if !$0 { model.pendingCaptureDelete = nil } })) { Button("Delete Capture", role: .destructive) { model.deleteCaptureConfirmed() } }
    }
    private func kind(_ kind: CaptureKind) -> String { switch kind { case .area: "Capture"; case .fullPage: "Full Page"; case .portrait: "Portrait"; case .screenshot: "Screenshot" } }
    @ViewBuilder private func captureActions(_ item: CaptureItemSnapshot) -> some View {
        Button("Open") { model.actions.openCapture(id: item.id) }
        Button("Copy Image") { model.actions.copyCapture(id: item.id) }
        Button("Save As…") { let panel = NSSavePanel(); panel.nameFieldStringValue = item.fileName; if panel.runModal() == .OK, let url = panel.url { model.saveCapture(item, to: url) } }
        Button("Show in Finder") { model.actions.revealCapture(id: item.id) }
        Button("Delete…", role: .destructive) { model.pendingCaptureDelete = item.id }
    }
}
