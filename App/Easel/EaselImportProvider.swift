import AppKit
import OpenEasel
import OpenModel
import OpenSettings
import UniformTypeIdentifiers

/// "Easels" in Import from Arc (IMC's provider API, IMC-questions.md 03:35 / EZ 03:25).
/// Without a file it counts Arc's Easel rows (they arrive with the sidebar as empty Easels).
/// With Arc's "Export All Easels" folder or zip it fills those Easels by id, and gives Easels
/// without a row a new row at the top of Today in the first Space of the destination Profile.
@MainActor
final class EaselsImportProvider: ArcImportDataProvider {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }

  let id = "easels"
  let title = "Easels"
  let help = "Choose the folder or .zip that Arc’s “Export All Easels” saved. Without it, Easels arrive empty with their titles."
  let symbol = "scribble.variable"
  let fileTypes: [UTType] = [.folder, .zip]

  func count(arcDirectory: URL, file: URL?) async -> Int? {
    if let file {
      return await Task.detached(priority: .userInitiated) { () -> Int? in
        guard let folder = EaselArchive.unpack(file) else { return nil }
        defer { folder.cleanup() }
        let n = EaselImporter.read(folder: folder.url).easels.count
        return n
      }.value
    }
    let sidebar = arcDirectory.appendingPathComponent("StorableSidebar.json")
    return await Task.detached(priority: .userInitiated) { Self.sidebarEaselCount(sidebar) }.value
  }

  /// Arc sidebar items `{"data": {"easel": {"easelID": …}}}` (the ones that become Easel rows).
  nonisolated static func sidebarEaselCount(_ url: URL) -> Int? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= 256 << 20,
          let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any] else { return nil }
    var n = 0
    for case let container as [String: Any] in containers {
      for case let item as [String: Any] in container["items"] as? [Any] ?? [] {
        if let easel = (item["data"] as? [String: Any])?["easel"] as? [String: Any], let id = easel["easelID"] as? String, !id.isEmpty { n += 1 }
      }
    }
    return n
  }

  func run(arcDirectory: URL, file: URL?, profileID: ProfileID) async -> ArcImportProviderResult {
    guard let file else { return ArcImportProviderResult() }
    let unpacked = await Task.detached(priority: .userInitiated) { EaselArchive.unpack(file) }.value
    guard let unpacked else { return ArcImportProviderResult(failure: "Could not be read") }
    defer { unpacked.cleanup() }
    let read = await Task.detached(priority: .userInitiated) { EaselImporter.read(folder: unpacked.url) }.value
    let result = app.applyEaselImport(read, profileID: profileID)
    let failure = read.easels.isEmpty ? (read.skipped.isEmpty ? "No Easels found" : "Could not be read") : nil
    return ArcImportProviderResult(imported: result.imported, duplicates: 0, failure: failure,
      undo: { [weak app] in app?.undoEaselImport(result) },
      redo: { [weak app] in app?.redoEaselImport(result) })
  }
}

/// A folder to read: the chosen folder itself, or a zip unpacked into a temporary folder.
struct EaselArchive: Sendable {
  let url: URL
  let temporary: URL?
  func cleanup() { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

  static func unpack(_ source: URL) -> EaselArchive? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return nil }
    if isDirectory.boolValue { return EaselArchive(url: source, temporary: nil) }
    guard source.pathExtension.lowercased() == "zip" else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-easel-import-\(UUID().uuidString)")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", source.path, dir.path]
    do { try ditto.run(); ditto.waitUntilExit() } catch { return nil }
    guard ditto.terminationStatus == 0 else { try? FileManager.default.removeItem(at: dir); return nil }
    let top = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let folder = top.count == 1 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("easel.json").path) ? top[0] : dir
    return EaselArchive(url: folder, temporary: dir)
  }
}

/// What one Easel import changed, so Undo and Redo restore exactly that.
struct EaselImportChange: @unchecked Sendable {
  var imported = 0
  var newRows = 0
  /// Document id → its file before the import (nil: there was none).
  var before: [UUID: Data?] = [:]
  /// Document id → its file after the import.
  var after: [UUID: Data] = [:]
  /// Rows this import added: (document, row id, Space).
  var rows: [(UUID, ItemID, SpaceID)] = []
  var titles: [UUID: String] = [:]
}

extension AppDelegate {
  /// Writes the read Easels: content by stable id, pictures through the store, new rows for
  /// Easels that have none in any Space. Open canvases of replaced Easels are closed first.
  func applyEaselImport(_ read: EaselImporter.Result, profileID: ProfileID?) -> EaselImportChange {
    var change = EaselImportChange()
    let store = easels
    for item in read.easels {
      let id = item.document.id
      let (doc, _) = EaselImporter.resolvePictures(item) { data in store.addImage(data, document: id) }
      guard doc.isValid, let encoded = try? EaselStore.encoder.encode(doc) else { continue }
      for factory in hostFactories.values {
        if let row = factory.easelRow(documentID: id), let host = factory.easelHosts[row.id] {
          factory.controller?.container.closeHost(for: row.id); host.close()
        }
      }
      // Closing commits the canvas, and saves wait 500 ms: write them now, so Undo
      // restores the Easel as it was, not the file from before the last edits.
      store.flush()
      // `updateValue` keeps a nil entry ("no file before"); a subscript nil assignment would drop the key.
      change.before.updateValue(try? Data(contentsOf: store.fileURL(for: id)), forKey: id)
      store.save(doc)
      change.after[id] = encoded
      change.titles[id] = doc.displayTitle
      change.imported += 1
      if let row = anyEaselRow(documentID: id) { row.title = doc.displayTitle; continue }
      let space = profileID.flatMap { p in model.spaces.first { $0.profileID == p } } ?? model.spaces.first
      guard let space else { continue }
      // The import's own Undo removes this row: no separate model undo step.
      let undo = model.undoManager; undo?.disableUndoRegistration(); defer { undo?.enableUndoRegistration() }
      let tab = model.newTab(in: space.id, url: EaselTab.url(for: id), title: doc.displayTitle, at: 0)
      tab.live.faviconPNG = EaselIcon.faviconPNG
      change.rows.append((id, tab.id, space.id))
      change.newRows += 1
    }
    store.flush()
    for factory in hostFactories.values {
      factory.controller?.refresh()
      if let selected = factory.selectedTab, EaselTab.matches(selected.url) { factory.showSelection(focus: false) }
    }
    scheduleSave()
    return change
  }

  func anyEaselRow(documentID: UUID) -> Tab? {
    for factory in hostFactories.values { if let tab = factory.easelRow(documentID: documentID) { return tab } }
    func visit(_ nodes: [SidebarNode]) -> Tab? {
      for node in nodes {
        switch node {
        case .tab(let t): if EaselTab.documentID(t.url) == documentID { return t }
        case .folder(let f): if let t = visit(f.children) { return t }
        case .split(let s): if let t = s.panes.first(where: { EaselTab.documentID($0.url) == documentID }) { return t }
        }
      }
      return nil
    }
    for space in model.spaces { if let t = visit(space.pinned + space.today) { return t } }
    return nil
  }

  func undoEaselImport(_ change: EaselImportChange) {
    for (_, rowID, _) in change.rows {
      for factory in hostFactories.values { if let host = factory.easelHosts[rowID] { factory.controller?.container.closeHost(for: rowID); host.close() } }
      if model.tab(id: rowID) != nil {
        let undo = model.undoManager; undo?.disableUndoRegistration()
        model.closeTab(id: rowID)
        undo?.enableUndoRegistration()
        model.archiveSink?.discardArchived(ids: [rowID])
      }
    }
    writeEaselFiles(change.before)
  }

  func redoEaselImport(_ change: EaselImportChange) {
    writeEaselFiles(change.after.mapValues { Optional($0) })
    for (id, _, spaceID) in change.rows where anyEaselRow(documentID: id) == nil && model.space(id: spaceID) != nil {
      let undo = model.undoManager; undo?.disableUndoRegistration(); defer { undo?.enableUndoRegistration() }
      let tab = model.newTab(in: spaceID, url: EaselTab.url(for: id), title: change.titles[id] ?? EaselDocument.untitled, at: 0)
      tab.live.faviconPNG = EaselIcon.faviconPNG
    }
    for factory in hostFactories.values { factory.controller?.refresh() }
    scheduleSave()
  }

  /// Puts document files back (nil removes the document folder's `document.json`).
  private func writeEaselFiles(_ files: [UUID: Data?]) {
    // Close the canvases first: a close commits open edits and queues their write, which
    // would land after (and overwrite) the file put back below.
    for id in files.keys {
      for factory in hostFactories.values {
        if let row = factory.easelRow(documentID: id), let host = factory.easelHosts[row.id] {
          factory.controller?.container.closeHost(for: row.id); host.close()
        }
      }
    }
    easels.flush()
    for (id, data) in files {
      let url = easels.fileURL(for: id)
      if let data {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
      } else {
        try? FileManager.default.removeItem(at: url)
      }
    }
    for factory in hostFactories.values {
      factory.controller?.refresh()
      if let selected = factory.selectedTab, EaselTab.matches(selected.url) { factory.showSelection(focus: false) }
    }
  }
}
