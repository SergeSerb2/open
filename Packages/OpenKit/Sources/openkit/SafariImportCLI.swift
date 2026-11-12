import Foundation
import OpenImport
import OpenModel
import OpenStore

private let safariUsage = """
usage: openkit safari-fixture --out DIR [--history N]
       openkit import-safari --db PATH (--export ZIP | --passwords CSV | --live SAFARI_DIR) [--expect FIXTURE_ROOT]
       openkit safari-access [--dir SAFARI_DIR]   (open/close probe of Bookmarks.plist only; reads no data)
"""

private func safariFail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}

private func safariArgs(_ args: [String], values: Set<String>) -> [String: String] {
    var result: [String: String] = [:], index = 0
    while index < args.count {
        guard values.contains(args[index]), index + 1 < args.count, result[args[index]] == nil else { safariFail(safariUsage, code: 2) }
        result[args[index]] = args[index + 1]; index += 2
    }
    return result
}

func runSafariFixture(args: [String]) throws {
    let values = safariArgs(args, values: ["--out", "--history"])
    guard let out = values["--out"] else { safariFail(safariUsage, code: 2) }
    let fixture = try SyntheticSafariFixture.write(to: URL(fileURLWithPath: out), historyItems: values["--history"].flatMap(Int.init) ?? 6_000)
    print("safari fixture: root=\(fixture.root.path)")
    print("  export=\(fixture.exportZip.lastPathComponent) passwords=\(fixture.passwordsCSV.lastPathComponent) notPasswords=\(fixture.notPasswords.lastPathComponent) live=Library/Safari")
}

func runSafariAccess(args: [String]) {
    let values = safariArgs(args, values: ["--dir"])
    let dir = values["--dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SafariLiveReader.defaultDirectory
    let access = SafariAccess.check(safariDirectory: dir)
    print("safari access: \(access)")
    if access == .denied {
        print("  Full Disk Access is needed to import Safari history and bookmarks.")
        print("  settings=\(SafariAccess.settingsURL.absoluteString)")
    }
}

@MainActor
func runImportSafari(args: [String]) async throws {
    let values = safariArgs(args, values: ["--db", "--export", "--passwords", "--live", "--expect"])
    guard let dbPath = values["--db"], [values["--export"], values["--passwords"], values["--live"]].compactMap({ $0 }).count == 1 else {
        safariFail(safariUsage, code: 2)
    }
    let expected = values["--expect"].map { root -> SyntheticSafariFixture.Expected in
        guard let e = SyntheticSafariFixture.readExpected(root: URL(fileURLWithPath: root)) else { safariFail("error: --expect needs a synthetic fixture root", code: 2) }
        return e
    }
    var ok = true
    func check(_ label: String, _ actual: Int, _ want: Int?) {
        guard let want else { return }
        ok = ok && actual == want
        print("  expect \(label)=\(want) actual=\(actual) \(actual == want ? "OK" : "MISMATCH")")
    }
    func checkRoots(_ folder: Folder, _ want: [String]?) {
        guard let want else { return }
        let actual = folder.children.compactMap { $0.folder?.title }
        ok = ok && actual == want
        print("  expect roots=\(want) actual=\(actual) \(actual == want ? "OK" : "MISMATCH")")
    }
    func printBookmarks(_ result: (roots: [ImportedBookmark], report: ImportedBookmarksReport), sourceKey: String) -> Folder {
        let folder = importedBookmarksFolder(result.roots, browserName: "Safari", sourceKey: sourceKey)
        let r = result.report
        print("bookmarks: rows=\(r.sourceRows) urls=\(r.urls) folders=\(r.folders) separators=\(r.skippedSeparators) unsupported=\(r.skippedUnsupportedURL) emptyFolders=\(r.skippedEmptyFolders) other=\(r.skippedOther)")
        print("  folder \"\(folder.title)\" id=\(folder.id.rawValue.uuidString.prefix(8)) children=\(folder.children.count)")
        print("  check accounted=\(r.accounted) rows=\(r.sourceRows) \(r.accounted == r.sourceRows ? "OK" : "MISMATCH")")
        ok = ok && r.accounted == r.sourceRows
        return folder
    }
    func passwords(_ read: () throws -> (logins: [ImportedLoginRecord], report: PasswordsCSVReport)) {
        do {
            var result = try read()
            defer { for i in result.logins.indices { result.logins[i].zeroSecrets() } }
            let r = result.report
            print("passwords: rows=\(r.sourceRows) kept=\(r.kept) unsupported=\(r.skippedUnsupportedOrigin) emptyPassword=\(r.skippedEmptyPassword) oversize=\(r.skippedOversize)")
            ok = ok && r.accounted == r.sourceRows
            check("passwordRows", r.sourceRows, expected?.passwordRows)
            check("passwordsKept", r.kept, expected?.passwordsKept)
            check("passwordsUnsupported", r.skippedUnsupportedOrigin, expected?.passwordsUnsupported)
            check("passwordsEmpty", r.skippedEmptyPassword, expected?.passwordsEmpty)
            if expected != nil {
                let quoted = result.logins.first { $0.username == "synthetic-user-2" }
                let shape = quoted?.passwordBytes == Array("synthetic-pass-\"2\"".utf8) && quoted?.signonRealm == "https://login2.example.com:8443/"
                    && quoted?.noteBytes == Array("multi\r\nline note".utf8)
                    && result.logins.contains { $0.signonRealm == "https://login3.example.com/" }
                ok = ok && shape
                print("  expect quoted/multiline/no-scheme rows parsed \(shape ? "OK" : "MISMATCH")")
            }
        } catch SafariImportError.notPasswordsFile {
            print("passwords: The file you uploaded doesn't look like a passwords file.")
            ok = false
        } catch { print("passwords: error \(error)"); ok = false }
    }
    let destination = URL(fileURLWithPath: dbPath)
    let dataRoot = try OpenDataRoot.prepare(storeFileURL: destination)
    defer { withExtendedLifetime(dataRoot) {} }

    if let path = values["--passwords"] {
        passwords { try PasswordsCSVReader.read(try Data(contentsOf: URL(fileURLWithPath: path))) }
    } else if let path = values["--export"] {
        let reader: SafariExportReader
        do { reader = try SafariExportReader(url: URL(fileURLWithPath: path)) }
        catch { safariFail("error: not a Safari export archive", code: 4) }
        print("export contents: bookmarks=\(reader.contents.bookmarks) history=\(reader.contents.history) passwords=\(reader.contents.passwords)")
        let folder = printBookmarks(try reader.readBookmarks(), sourceKey: "safari:export")
        let r = try reader.readBookmarks().report
        check("bookmarkRows", r.sourceRows, expected?.exportBookmarkRows); check("bookmarkURLs", r.urls, expected?.exportBookmarkURLs)
        check("bookmarkFolders", r.folders, expected?.exportBookmarkFolders); check("separators", r.skippedSeparators, expected?.exportSeparators)
        check("unsupported", r.skippedUnsupportedURL, expected?.exportUnsupported); check("emptyFolders", r.skippedEmptyFolders, expected?.exportEmptyFolders)
        checkRoots(folder, expected?.exportRootTitles)
        let writer = ImportHistoryWriter(destination: destination, key: "safari:export")
        let h = try await Task.detached(priority: .utility) { try await reader.readHistory { await writer.write($0) } }.value
        let (inserted, duplicates, urls, failed) = await writer.summary()
        print("history: rows=\(h.sourceRows) kept=\(h.kept) internal=\(h.skippedInternal) invalidTime=\(h.skippedInvalidTime) inserted=\(inserted) duplicates=\(duplicates) urlsInStore=\(urls)")
        ok = ok && !failed && inserted + duplicates == h.kept && h.kept + h.skippedInternal + h.skippedInvalidTime == h.sourceRows
        check("historyRows", h.sourceRows, expected?.exportHistoryRows); check("historyKept", h.kept, expected?.exportHistoryKept)
        check("historyInternal", h.skippedInternal, expected?.exportHistoryInternal); check("historyInvalid", h.skippedInvalidTime, expected?.exportHistoryInvalid)
        passwords { try reader.readPasswords() }
    } else if let path = values["--live"] {
        let reader = SafariLiveReader(directory: URL(fileURLWithPath: path, isDirectory: true))
        let bookmarks: (roots: [ImportedBookmark], report: ImportedBookmarksReport)
        do { bookmarks = try reader.readBookmarks() }
        catch SafariImportError.fullDiskAccessRequired {
            print("safari live: Full Disk Access required. settings=\(SafariAccess.settingsURL.absoluteString)")
            exit(6)
        }
        let folder = printBookmarks(bookmarks, sourceKey: "safari:live")
        let r = bookmarks.report
        check("bookmarkRows", r.sourceRows, expected?.liveBookmarkRows); check("bookmarkURLs", r.urls, expected?.liveBookmarkURLs)
        check("bookmarkFolders", r.folders, expected?.liveBookmarkFolders); check("unsupported", r.skippedUnsupportedURL, expected?.liveUnsupported)
        check("emptyFolders", r.skippedEmptyFolders, expected?.liveEmptyFolders); check("other", r.skippedOther, expected?.liveOther)
        checkRoots(folder, expected?.liveRootTitles)
        let writer = ImportHistoryWriter(destination: destination, key: "safari:live")
        let h = try await Task.detached(priority: .utility) { try await reader.readHistory { await writer.write($0) } }.value
        let (inserted, duplicates, urls, failed) = await writer.summary()
        print("history: rows=\(h.sourceRows) kept=\(h.kept) internal=\(h.skippedInternal) invalidTime=\(h.skippedInvalidTime) inserted=\(inserted) duplicates=\(duplicates) urlsInStore=\(urls)")
        ok = ok && !failed && inserted + duplicates == h.kept
        check("historyRows", h.sourceRows, expected?.liveHistoryRows); check("historyKept", h.kept, expected?.liveHistoryKept)
        check("historyInternal", h.skippedInternal, expected?.liveHistoryInternal)
    }
    print(ok ? "RESULT PASS" : "RESULT FAIL")
    if !ok { exit(1) }
}
