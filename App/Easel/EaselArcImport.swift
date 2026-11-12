import AppKit
import OpenEasel
import OpenModel

/// Arc's "Export All Easels" output → Open Easels. An Easel whose row already exists (same
/// document id, e.g. an imported Arc sidebar row) gets its content; others get a new row at
/// the top of Today in the focused Space.
extension EngineWebContentHostFactory {
  struct EaselImportReport { var imported = 0; var newRows = 0; var skipped: [String] = []; var droppedObjects = 0 }

  func importArcEaselExport(_ source: URL) -> EaselImportReport {
    var report = EaselImportReport()
    var folder = source
    var temporary: URL?
    if source.pathExtension.lowercased() == "zip" {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-easel-import-\(UUID().uuidString)")
      let ditto = Process()
      ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      ditto.arguments = ["-x", "-k", source.path, dir.path]
      do { try ditto.run(); ditto.waitUntilExit() } catch { report.skipped.append("archive: \(error.localizedDescription)"); return report }
      guard ditto.terminationStatus == 0 else { report.skipped.append("archive: could not unpack"); return report }
      temporary = dir
      // An archive usually holds one top-level folder.
      let top = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      folder = top.count == 1 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("easel.json").path) ? top[0] : dir
    }
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    let read = EaselImporter.read(folder: folder)
    report.skipped = read.skipped
    report.droppedObjects = read.droppedObjects
    let store = app.easels
    for item in read.easels {
      let id = item.document.id
      let (doc, dropped) = EaselImporter.resolvePictures(item) { data in store.addImage(data, document: id) }
      report.droppedObjects += dropped
      guard doc.isValid else { report.skipped.append("\(doc.displayTitle): limits"); continue }
      let row = easelRow(documentID: id)
      if let row, let host = easelHosts[row.id], !host.closed {
        controller?.container.closeHost(for: row.id); host.close()
      }
      store.save(doc)
      if let row {
        row.title = doc.displayTitle
      } else if let space = focusedSpace, !isIncognito {
        let tab = model.newTab(in: space.id, url: EaselTab.url(for: id), title: doc.displayTitle, at: 0)
        tab.live.faviconPNG = EaselIcon.faviconPNG
        report.newRows += 1
      }
      report.imported += 1
    }
    store.flush()
    controller?.refresh(); scheduleSave()
    if let selected = selectedTab, EaselTab.matches(selected.url) { showSelection(focus: false) }
    return report
  }

  /// The sidebar row of an Easel document, in any Space.
  func easelRow(documentID: UUID) -> Tab? {
    for space in model.spaces {
      if let tab = flattened(space.pinned + space.today).first(where: { EaselTab.documentID($0.url) == documentID }) { return tab }
    }
    return nil
  }
}
