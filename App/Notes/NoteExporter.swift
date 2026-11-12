import AppKit
import OpenDocuments
import OpenFeatures
import UniformTypeIdentifiers

/// Help ▸ Export Notes…: every Note as `<title>.html` (self-contained, images inline,
/// like Arc's export, docs/re/easels-notes.md §4.6) and `<title>.md` with its images
/// in `images/`, zipped into one archive. Arc's toasts: "Exporting Notes",
/// "No Notes found to export.", "Notes export failed." (STR).
@MainActor
enum NoteExporter {
  enum Result: Equatable { case none, exported(Int, URL), failed(String) }
  private(set) static var last: Result?
  private(set) static var running = false

  static func exportWithPanel(app: AppDelegate) {
    let (notes, _) = app.notes.allNotes()
    guard !notes.isEmpty else { toast(app, "No Notes found to export."); last = Result.none; return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm"
    panel.nameFieldStringValue = "Open Notes Export \(stamp.string(from: Date())).zip"
    let done: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      export(app: app, to: url)
    }
    if let window = app.frontWindowController?.window { panel.beginSheetModal(for: window, completionHandler: done) }
    else { done(panel.runModal()) }
  }

  /// Writes the archive at `zip` (replacing it). Work runs off the main thread.
  static func export(app: AppDelegate, to zip: URL, completion: (@MainActor (Result) -> Void)? = nil) {
    let (notes, _) = app.notes.allNotes()
    guard !notes.isEmpty else { toast(app, "No Notes found to export."); last = Result.none; completion?(.none); return }
    guard !running else { return }
    running = true
    let handle = app.frontWindowController?.toasts.show(ToastContent(title: "Exporting Notes", isSticky: true))
    let store = app.notes
    let assets: [UUID: URL] = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, store.assetDirectory(for: $0.id)) })
    Task.detached(priority: .userInitiated) {
      let result = write(notes: notes, assets: assets, to: zip)
      await MainActor.run {
        running = false; last = result; handle?.dismiss()
        if case .failed = result { toast(app, "Notes export failed.") }
        completion?(result)
      }
    }
  }

  nonisolated static func write(notes: [NoteDocument], assets: [UUID: URL], to zip: URL) -> Result {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("open-notes-export-" + UUID().uuidString, isDirectory: true)
    let root = folder.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
    defer { try? fm.removeItem(at: folder) }
    do {
      try fm.createDirectory(at: root, withIntermediateDirectories: true)
      var used = Set<String>()
      for note in notes {
        let name = NoteExport.fileName(for: note, used: &used)
        let images = assets[note.id]
        func file(_ asset: String) -> URL? {
          guard asset.range(of: #"^[0-9a-f]{64}\.[a-z]+$"#, options: .regularExpression) != nil else { return nil }
          return images?.appendingPathComponent(asset)
        }
        let html = NoteExport.html(note) { asset in
          guard let url = file(asset), let data = try? Data(contentsOf: url) else { return nil }
          let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
          return (data, mime)
        }
        try Data(html.utf8).write(to: root.appendingPathComponent(name + ".html"))
        let imageFolder = name + " images"
        let markdown = NoteExport.markdown(note) { asset in
          (imageFolder + "/" + asset).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asset
        }
        try Data(markdown.utf8).write(to: root.appendingPathComponent(name + ".md"))
        let used = note.formats.filter { $0.type == "image" }.compactMap { $0.url.flatMap(file) }
        if !used.isEmpty {
          let target = root.appendingPathComponent(imageFolder, isDirectory: true)
          try fm.createDirectory(at: target, withIntermediateDirectories: true)
          for url in Set(used) where fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: target.appendingPathComponent(url.lastPathComponent))
          }
        }
      }
      try? fm.removeItem(at: zip)
      let ditto = Process()
      ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", root.path, zip.path]
      try ditto.run(); ditto.waitUntilExit()
      guard ditto.terminationStatus == 0 else { return .failed("ditto exit \(ditto.terminationStatus)") }
      return .exported(notes.count, zip)
    } catch {
      return .failed("\(error)")
    }
  }

  private static func toast(_ app: AppDelegate, _ title: String) {
    app.frontWindowController?.toasts.show(ToastContent(title: title))
  }
}
