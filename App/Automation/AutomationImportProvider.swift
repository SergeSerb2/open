#if OPEN_AUTOMATION
import Foundation
import UniformTypeIdentifiers
import OpenModel
import OpenSettings

/// e2e only (`OPEN_AUTOMATION_FIXTURE_IMPORT_PROVIDER=1`): a provider that proves the wizard → runner → Undo/Redo
/// path of `ArcImportProviders` before a real one (EZ's Easels) lands. It "imports" each file name of the chosen
/// folder as an empty marker file under `<data root>/ImportProviderFixture/` and removes exactly those on Undo.
@MainActor final class FixtureImportProvider: ArcImportDataProvider {
  let id = "fixture", title = "Example items", help = "Synthetic e2e data type.", symbol = "shippingbox"
  let fileTypes: [UTType] = [.folder]
  let destination: URL
  init(root: URL) { destination = root.appendingPathComponent("ImportProviderFixture", isDirectory: true) }

  static func registerIfRequested(root: URL) {
    guard ProcessInfo.processInfo.environment["OPEN_AUTOMATION_FIXTURE_IMPORT_PROVIDER"] == "1" else { return }
    ArcImportProviders.all.append(FixtureImportProvider(root: root))
  }

  private func names(_ file: URL?) -> [String]? {
    guard let file, let names = try? FileManager.default.contentsOfDirectory(atPath: file.path) else { return nil }
    return names.filter { !$0.hasPrefix(".") }.sorted()
  }
  func count(arcDirectory: URL, file: URL?) async -> Int? { names(file)?.count }
  func run(arcDirectory: URL, file: URL?, profileID: ProfileID) async -> ArcImportProviderResult {
    guard let names = names(file) else { return ArcImportProviderResult(failure: "Not found") }
    let fm = FileManager.default
    try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let added = names.filter { !fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
    for name in added { fm.createFile(atPath: destination.appendingPathComponent(name).path, contents: Data()) }
    let destination = destination
    return ArcImportProviderResult(imported: added.count, duplicates: names.count - added.count,
      undo: { for name in added { try? FileManager.default.removeItem(at: destination.appendingPathComponent(name)) } },
      redo: { for name in added { FileManager.default.createFile(atPath: destination.appendingPathComponent(name).path, contents: Data()) } })
  }
}
#endif
