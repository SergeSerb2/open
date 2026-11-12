import AppKit
import OpenEasel
import OpenFeatures
import OpenLibrary
import OpenModel

/// Library › Easels (EZ): every Easel document on disk, also those whose row or Space is
/// gone (Arc keeps them in the Library too). Open selects the Easel's row, or adds one at
/// the top of Today in the focused Space.
@MainActor
final class EaselLibraryProvider: LibraryEaselsProvider {
  unowned let app: AppDelegate
  weak var controller: BrowserWindowController?
  init(app: AppDelegate) { self.app = app }

  var factory: EngineWebContentHostFactory? {
    controller.flatMap { app.hostFactories[$0.windowID] } ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
  }

  func libraryEasels() async -> [LibraryEaselItem] {
    let store = app.easels
    for factory in app.hostFactories.values { for host in factory.easelHosts.values { host.canvas.commitPendingEdits() } }
    let pending = store.pendingDocuments
    let directory = store.directory
    var entries = await Task.detached(priority: .userInitiated) { EaselStore.readIndex(directory: directory) }.value
    // A save still waiting for its debounce wins over the file.
    for doc in pending {
      let entry = EaselStore.IndexEntry(id: doc.id, title: doc.displayTitle, modifiedAt: doc.modifiedAt, objectCount: doc.objects.count)
      if let i = entries.firstIndex(where: { $0.id == doc.id }) { entries[i] = entry } else { entries.append(entry) }
    }
    return entries.sorted { $0.modifiedAt > $1.modifiedAt }.map {
      LibraryEaselItem(id: $0.id.uuidString.lowercased(), title: $0.title, modifiedAt: $0.modifiedAt, objectCount: $0.objectCount)
    }
  }

  func openEasel(id: String) {
    guard let documentID = UUID(uuidString: id), let factory else { return }
    app.settingsPresenter.closeLibrary()
    factory.showEasel(documentID: documentID)
  }

  func deleteEasel(id: String) {
    guard let documentID = UUID(uuidString: id) else { return }
    for factory in app.hostFactories.values {
      while let tab = factory.easelRow(documentID: documentID) {
        factory.deleteEasel(tabID: tab.id)
        if factory.easelRow(documentID: documentID)?.id == tab.id { break }
      }
    }
    let folder = app.easels.fileURL(for: documentID).deletingLastPathComponent()
    app.easels.flush()
    if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
  }

  /// "Export All Easels →": a save sheet for an archive "Open Easels - yyyy-MM-dd HH.mm"
  /// (Arc: "Arc Easels - ‹date time›", findings §3.8), then a zip of every Easel as web pages.
  func exportAllEasels(from window: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
    guard let window else { done(false); return }
    let panel = NSSavePanel()
    panel.message = "Save an archive of all your Easels as web pages you can open anywhere."
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm"
    panel.nameFieldStringValue = "Open Easels - \(stamp.string(from: Date())).zip"
    panel.allowedContentTypes = [.zip]
    panel.prompt = "Export"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { done(false); return }
      let ok = self.writeArchive(to: url)
      self.lastExport = ok ? url.path : nil
      self.factory?.controller?.toasts.show(ToastContent(title: ok ? "Your Easels are saved" : "We couldn't finish saving your Easels. Please try again."))
      done(ok)
    }
  }
  private(set) var lastExport: String?

  /// Writes a folder of web pages into a temporary place, then zips it to `url`.
  func writeArchive(to url: URL) -> Bool {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("open-easels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let folder = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      _ = try app.exportAllEasels(to: folder)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
      let ditto = Process()
      ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      ditto.arguments = ["-c", "-k", "--keepParent", folder.path, url.path]
      try ditto.run(); ditto.waitUntilExit()
      return ditto.terminationStatus == 0
    } catch { return false }
  }

  func easelThumbnail(id: String, pixels: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void) {
    guard let documentID = UUID(uuidString: id), let doc = app.easels.load(documentID) else { completion(nil); return }
    let store = app.easels
    // Drawn on the next turn: row configuration never waits for it.
    DispatchQueue.main.async {
      completion(EaselThumbnail.render(doc, imageURL: { store.imageURL(document: documentID, file: $0) }, pixels: pixels))
    }
  }
}
