import AppKit
import OpenEngine
import OpenModel

/// Destination selection only. Never publishes a DownloadsProvider history row.
@MainActor
final class IncognitoDownloads {
  private let files = DownloadFiles()
  private var closed = false
  private var choices: [UInt32: DownloadDestinationChoice] = [:]
  private var reserved: [UInt32: URL] = [:]
  /// Bumped by reset(): a choice that started for the previous private context ends without
  /// a reservation or a sheet (review r1 of #651).
  private var generation = 0
  /// A destination sheet is open (the transfer waits for it).
  var hasOpenChoices: Bool { !choices.isEmpty }
  func decide(_ download: OEDownload, filename: String, directory: URL?, profile: Profile?, window: NSWindow?,
              completion: @escaping @MainActor (URL?) -> Void) {
    guard !closed else { completion(nil); return }
    let name = filename.isEmpty ? "download" : (filename as NSString).lastPathComponent
    guard !name.isEmpty, ![".", "..", "/"].contains(name), name.utf8.count <= 255 else { completion(nil); return }
    let started = generation
    Task { @MainActor [weak self, weak window] in
      guard let self else { completion(nil); return }
      do {
        let target = try await files.directory(directory?.path ?? profile?.settings.downloadDirectory ?? "")
        guard !closed, generation == started else { completion(nil); return }
        if directory == nil, profile?.settings.askWhereToSaveEachFile == true {
          guard let window else { completion(nil); return }
          let key = download.identifier
          let choice = DownloadDestinationChoice { [weak self] url in
            self?.choices[key] = nil; completion(url)
          }
          choices[key] = choice; choice.present(in: window, filename: name, directory: target.url)
        } else {
          let url = try await files.unique(in: target.url, name: name)
          guard !closed, generation == started else { await files.release(url); completion(nil); return }
          reserved[download.identifier] = url
          completion(url)
        }
      } catch { completion(nil) }
    }
  }
  func updated(_ download: OEDownload) {
    switch download.state {
    case .complete, .cancelled, .interrupted:
      if let url = reserved.removeValue(forKey: download.identifier) { Task { await files.release(url) } }
    default: break
    }
  }
  func close() {
    guard !closed else { return }
    closed = true
    reset()
  }
  /// Cancels open choices and releases reservations, and keeps taking new requests: a renewed
  /// private context numbers its downloads from 1 again (bug sweep r5 item 3).
  func reset() {
    generation &+= 1
    let pending = Array(choices.values); choices.removeAll()
    for choice in pending { choice.cancel() }
    let urls = Array(reserved.values); reserved.removeAll()
    Task { for url in urls { await files.release(url) } }
  }
}
