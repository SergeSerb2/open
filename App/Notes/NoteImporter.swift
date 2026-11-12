import AppKit
import OpenDocuments
import OpenFeatures
import OpenModel

/// Import from Arc, Notes half: the zip that Arc's Help ▸ Export Arc Notes writes
/// (`ExportedARCDocument {id, title, html, lastUpdatedAt}` per Note, §4.6; files inside
/// are a GUESS, so `.html` pages and `.json` records are both read). A Note that Import
/// from Arc created as a placeholder is filled (matched by Arc id, else by title);
/// every other exported Note becomes a new Note tab at the top of Today.
@MainActor
enum NoteImporter {
  struct Outcome: Equatable { var filled = 0, added = 0, alreadyPresent = 0, unreadable = 0, droppedImages = 0; var error: String? }
  private(set) static var last: Outcome?
  static let maxZipBytes = 512 << 20
  static let maxEntries = 5000

  static func importWithPanel(factory: EngineWebContentHostFactory) {
    guard let window = factory.window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
    panel.message = "Choose the zip that Arc's Help ▸ Export Arc Notes saved."
    panel.beginSheetModal(for: window) { [weak factory] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated {
        guard let factory else { return }
        let outcome = importZip(url, factory: factory)
        let toasts = factory.app.frontWindowController?.toasts
        if let error = outcome.error { toasts?.show(ToastContent(title: error)) }
        else {
          let count = outcome.filled + outcome.added
          // GUESS: Arc has no import of its own export; our own wording.
          toasts?.show(ToastContent(title: count == 0 ? "No new Notes in this export." : count == 1 ? "Imported 1 Note" : "Imported \(count) Notes"))
        }
      }
    }
  }

  /// The import itself (after the panel). Synchronous; zips of Notes are small.
  @discardableResult
  static func importZip(_ zip: URL, factory: EngineWebContentHostFactory) -> Outcome {
    var outcome = Outcome()
    defer { last = outcome }
    let fm = FileManager.default
    guard let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxZipBytes else {
      outcome.error = "This file is not an Arc Notes export."; return outcome
    }
    let folder = fm.temporaryDirectory.appendingPathComponent("open-notes-import-" + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: folder) }
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", "--norsrc", zip.path, folder.path]
    ditto.standardError = FileHandle.nullDevice
    do { try ditto.run(); ditto.waitUntilExit() } catch { outcome.error = "This file is not an Arc Notes export."; return outcome }
    guard ditto.terminationStatus == 0 else { outcome.error = "This file is not an Arc Notes export."; return outcome }
    var files: [URL] = []
    if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) {
      for case let url as URL in walker {
        if url.pathComponents.contains("__MACOSX") || url.lastPathComponent.hasPrefix(".") { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
          ["html", "htm", "json"].contains(url.pathExtension.lowercased()) else { continue }
        files.append(url)
        if files.count > maxEntries { outcome.error = "This export has too many files."; return outcome }
      }
    }
    files.sort { $0.path < $1.path }
    let store = factory.app.notes
    let tabs = factory.model.allTabsForNotes()
    // Placeholders created by Import from Arc, by Note id and by title.
    var placeholders: [UUID: NoteDocument] = [:]
    // An export page without an Arc id is "already present" when a Note has its title and text.
    var present = Set<String>()
    for tab in tabs {
      guard let id = NoteLink.id(from: tab.url), let note = store.load(id) else { continue }
      if note.importPlaceholder == true { placeholders[id] = note } else { present.insert(note.title + "\u{0}" + note.text) }
    }
    var newIDs: [UUID] = []
    for file in files {
      guard let data = try? Data(contentsOf: file), var parsed = ArcNotes.exported(fileName: file.lastPathComponent, data: data) else {
        outcome.unreadable += 1; continue
      }
      outcome.droppedImages += parsed.droppedImages
      var target: UUID?
      if parsed.arcID != nil {
        let id = parsed.note.id
        if placeholders[id] != nil { target = id }
        else if store.load(id) != nil || store.isUnreadable(id) { outcome.alreadyPresent += 1; continue }
      }
      if target == nil, parsed.arcID == nil, present.contains(parsed.note.title + "\u{0}" + parsed.note.text) {
        outcome.alreadyPresent += 1; continue
      }
      if target == nil, let match = placeholders.first(where: { $0.value.title == parsed.note.title && !parsed.note.title.isEmpty })?.key {
        target = match
      }
      let id = target ?? (parsed.arcID != nil ? parsed.note.id : UUID())
      parsed.note.id = id
      // Images: header-checked, then stored like a pasted image.
      var renamed: [String: String] = [:]
      for (key, (bytes, ext)) in parsed.images {
        guard NoteImages.image(bytes) != nil, let name = try? store.writeAsset(bytes, ext: ext, note: id) else { outcome.droppedImages += 1; continue }
        renamed[key] = name
      }
      parsed.note.formats = parsed.note.formats.compactMap { format in
        guard format.type == "image" else { return format }
        guard let name = format.url.flatMap({ renamed[$0] }) else { return nil }
        var f = format; f.url = name; return f
      }
      parsed.note.importPlaceholder = nil
      if target != nil {
        store.replace(parsed.note)
        placeholders[id] = nil
        outcome.filled += 1
        refresh(noteID: id, title: parsed.note.title, factory: factory)
      } else {
        guard store.importIfAbsent(parsed.note) else { outcome.alreadyPresent += 1; continue }
        newIDs.append(id)
        outcome.added += 1
      }
    }
    // New Notes go to the top of Today in the focused Space, in export order.
    if let space = factory.focusedSpace, !factory.isIncognito {
      for id in newIDs.reversed() {
        let note = store.load(id)
        let tab = factory.model.newTab(in: space.id, url: NoteLink.url(for: id),
                                       title: note.map { $0.title.isEmpty ? NoteTab.untitled : $0.title } ?? NoteTab.untitled, at: 0)
        tab.live.faviconPNG = NoteTab.faviconPNG
      }
      if !newIDs.isEmpty { factory.controller?.refresh(); factory.scheduleSave() }
    }
    return outcome
  }

  /// A filled placeholder: rows take the real title; a shown editor reloads from the file.
  private static func refresh(noteID: UUID, title: String, factory: EngineWebContentHostFactory) {
    for owner in factory.app.hostFactories.values {
      for tab in owner.model.allTabsForNotes() where NoteLink.id(from: tab.url) == noteID {
        tab.title = title.isEmpty ? NoteTab.untitled : title
        if let host = owner.noteHosts[tab.id] { owner.controller?.container.closeHost(for: tab.id); host.close() }
      }
      owner.showSelection(focus: false); owner.scheduleSave()
    }
  }
}
