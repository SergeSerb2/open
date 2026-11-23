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
    modified = Dictionary(entries.map { ($0.id, $0.modifiedAt) }, uniquingKeysWith: { first, _ in first })
    thumbnails = thumbnails.filter { modified[$0.key] == $0.value.modified }
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
    app.deleteEaselEverywhere(documentID)
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
  /// How long the last archive's `ditto` ran (automation read-back). `waitUntilExit()` runs the
  /// main run loop while it waits, so the main thread keeps turning (e2e E37b measures it).
  private(set) var lastDittoMilliseconds = 0.0
  /// When the last archive's `ditto` started and ended (system uptime; automation read-back).
  private(set) var lastDittoInterval: ClosedRange<Double>?


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
      let started = ProcessInfo.processInfo.systemUptime
      try ditto.run(); ditto.waitUntilExit()
      let ended = ProcessInfo.processInfo.systemUptime
      lastDittoMilliseconds = (ended - started) * 1000; lastDittoInterval = started...ended
      return ditto.terminationStatus == 0
    } catch { return false }
  }

  /// Each Easel's modification date in the last list read (`libraryEasels`).
  private var modified: [UUID: Date] = [:]
  /// Rendered thumbnails, kept while the Easel's date in the list is the one the picture was drawn
  /// from. Each row configuration, each prefetch and each Library open read the document and drew
  /// the whole canvas again on the main thread (bug sweep r7 X-04).
  /// The picture also depends on the appearance it was drawn in (light or dark canvas).
  private var thumbnails: [UUID: (modified: Date, pixels: CGFloat, appearance: NSAppearance.Name, image: NSImage?)] = [:]
  /// Requests for an Easel whose picture is being drawn: one draw answers the ones of the same size
  /// and appearance.
  private var drawing: [String: [@MainActor (NSImage?) -> Void]] = [:]
  #if OPEN_AUTOMATION
  private(set) var thumbnailRenders = 0
  #endif

  /// An edit (in any window) makes the cached picture and list date stale: the next request draws
  /// the current document (review of #669 round 2, nit 1).
  func forget(_ documentID: UUID) { thumbnails[documentID] = nil; modified[documentID] = nil }

  func easelThumbnail(id: String, pixels: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void) {
    guard let documentID = UUID(uuidString: id) else { completion(nil); return }
    let appearance = NSApp.effectiveAppearance, name = appearance.name
    if let cached = thumbnails[documentID], cached.pixels == pixels, cached.appearance == name,
       cached.modified == modified[documentID] { completion(cached.image); return }
    let key = "\(documentID)|\(pixels)|\(name.rawValue)"
    if drawing[key] != nil { drawing[key]?.append(completion); return }
    guard let doc = app.easels.load(documentID) else { completion(nil); return }
    let store = app.easels, listed = modified[documentID]
    drawing[key] = [completion]
    // Drawn on the next turn: row configuration never waits for it.
    DispatchQueue.main.async { [weak self] in
      let image = EaselThumbnail.render(doc, imageURL: { store.imageURL(document: documentID, file: $0) }, pixels: pixels, appearance: appearance)
      guard let self else { completion(image); return }
      #if OPEN_AUTOMATION
      self.thumbnailRenders += 1
      #endif
      // Keyed by the drawn document's own date. The list date follows it unless a newer list read ran
      // meanwhile: a saved file keeps whole seconds only, and an edit in another window does not
      // reload this list, so the dates differed and every request drew again (review of #669 #3).
      self.thumbnails[documentID] = (doc.modifiedAt, pixels, name, image)
      if self.modified[documentID] == listed { self.modified[documentID] = doc.modifiedAt }
      for callback in self.drawing.removeValue(forKey: key) ?? [completion] { callback(image) }
    }
  }
}
