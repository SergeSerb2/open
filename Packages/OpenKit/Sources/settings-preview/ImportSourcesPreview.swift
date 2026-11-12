import Foundation
import SQLite3
import SwiftUI
import OpenSettings
import OpenImport

/// IMC I-1 look frames: source picker, Chromium Choose, and Report, in light and dark.
/// Every source file is synthetic and written under the preview root.
@MainActor func renderImportSources(output: URL, scales: [Int]) async throws {
    let environment = try PreviewEnvironment(); defer { environment.close() }
    let library = environment.root.appendingPathComponent("Example Library")
    try writeSyntheticBrowserLibrary(library)
    ImportWizardViewModel.browserLibraryOverride = library
    environment.actions.importHandler = { _ in
        ImportOutcome(counts: ["Bookmarks": 4, "History": 5, "Search settings": 1, ImportOutcomeKeys.history: 5])
    }
    let wizard = ImportWizardViewModel(root: environment.settings, startsWithSource: true)
    await wizard.loadSources()
    try require(wizard.step == .source && wizard.selectedSourceID == "chrome", "source picker selects the detected Chrome")
    func frames(_ name: String) async throws {
        for dark in [false, true] { for scale in scales {
            try await render(ImportWizard(model: wizard).buttonStyle(SettingsButtonStyle()), size: CGSize(width: 640, height: 520), scale: scale,
                             dark: dark, to: output.appendingPathComponent("import-\(name)-\(dark ? "dark" : "light")@\(scale)x.png"))
        } }
    }
    try await frames("source")
    await wizard.continueFromSource()
    try require(wizard.step == .choose && wizard.readable, "Chrome Choose step is readable")
    try await frames("browser-choose")
    wizard.review(); try await frames("browser-review")
    await wizard.beginImport()
    try require(wizard.step == .report, "browser report")
    try await frames("browser-report")
}

private func writeSyntheticBrowserLibrary(_ library: URL) throws {
    let fm = FileManager.default
    let chrome = library.appendingPathComponent("Application Support/Google/Chrome")
    for directory in ["Default", "Profile 1"] { try fm.createDirectory(at: chrome.appendingPathComponent(directory), withIntermediateDirectories: true) }
    try fm.createDirectory(at: library.appendingPathComponent("Application Support/BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)
    try fm.createDirectory(at: library.appendingPathComponent("Application Support/Firefox/Profiles"), withIntermediateDirectories: true)
    try fm.createDirectory(at: library.appendingPathComponent("Application Support/Microsoft Edge/Default"), withIntermediateDirectories: true)
    func json(_ value: Any, _ path: String, in root: URL = chrome) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
    }
    try json(["profile": ["info_cache": ["Default": ["name": "Example Person"], "Profile 1": ["name": "Example Work"]], "profiles_order": ["Default", "Profile 1"]]], "Local State")
    func url(_ guid: String, _ name: String, _ href: String) -> [String: Any] { ["type": "url", "guid": guid, "name": name, "url": href] }
    let bookmarks: [String: Any] = ["roots": [
        "bookmark_bar": ["type": "folder", "guid": "bar", "name": "Bookmarks bar", "children": [
            url("1", "Example One", "https://one.example.com/"), url("2", "Example Two", "https://two.example.com/"),
            ["type": "folder", "guid": "3", "name": "Example Folder", "children": [url("4", "Example Nested", "https://nested.example.com/")]]]],
        "other": ["type": "folder", "guid": "other", "name": "Other bookmarks", "children": [url("5", "Example Other", "https://other.example.com/")]]]]
    try json(bookmarks, "Default/Bookmarks")
    try json(bookmarks, "Profile 1/Bookmarks")
    try json(["default_search_provider_data": ["template_url_data": ["short_name": "DuckDuckGo", "keyword": "ddg", "url": "https://duckduckgo.com/?q={searchTerms}"]]], "Default/Preferences")
    try json(["roots": ["bookmark_bar": ["type": "folder", "children": [url("e1", "Example Edge", "https://edge.example.com/")]]]], "Default/Bookmarks",
             in: library.appendingPathComponent("Application Support/Microsoft Edge"))
    var db: OpaquePointer?
    guard sqlite3_open(chrome.appendingPathComponent("Default/History").path, &db) == SQLITE_OK else { throw CheckFailure(description: "history fixture") }
    defer { sqlite3_close(db) }
    let now = (Int64(Date().timeIntervalSince1970) - 3600) * 1_000_000 + 11_644_473_600_000_000
    let sql = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES('version','70');
    CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, hidden INTEGER DEFAULT 0);
    CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, transition INTEGER DEFAULT 0, incremented_omnibox_typed_score INTEGER DEFAULT 0);
    CREATE TABLE keyword_search_terms(keyword_id INTEGER, url_id INTEGER, term TEXT);
    INSERT INTO urls VALUES(1,'https://one.example.com/','Example One',0),(2,'https://two.example.com/','Example Two',0);
    INSERT INTO visits(url,visit_time) VALUES(1,\(now)),(1,\(now - 1000000)),(1,\(now - 2000000)),(2,\(now - 3000000)),(2,\(now - 4000000));
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure(description: "history fixture") }
}
