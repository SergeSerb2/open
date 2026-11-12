import Foundation
import Darwin
import OpenImport
import OpenModel
import OpenStore

private let firefoxUsage = """
usage: openkit firefox-fixture --out DIR [--visits N]
       openkit import-firefox --firefox-root DIR --db PATH [--profile NAME] [--primary-password-file FILE] [--expect]
       openkit firefox-fixture-lock PROFILE_DIR   (holds the profile lock until stdin closes)
"""

private func firefoxFail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}

private func firefoxArgs(_ args: [String], values: Set<String>, flags: Set<String> = []) -> ([String: String], Set<String>) {
    var result: [String: String] = [:], set = Set<String>(), index = 0
    while index < args.count {
        let flag = args[index]
        if values.contains(flag), index + 1 < args.count, result[flag] == nil { result[flag] = args[index + 1]; index += 2 }
        else if flags.contains(flag), set.insert(flag).inserted { index += 1 }
        else { firefoxFail(firefoxUsage, code: 2) }
    }
    return (result, set)
}

func runFirefoxFixture(args: [String]) throws {
    let (values, _) = firefoxArgs(args, values: ["--out", "--visits"])
    guard let out = values["--out"] else { firefoxFail(firefoxUsage, code: 2) }
    let visits = values["--visits"].flatMap(Int.init) ?? 7_000
    let fixture = try SyntheticFirefoxFixture.write(to: URL(fileURLWithPath: out), visits: visits)
    print("firefox fixture: root=\(fixture.root.path) profiles=\(fixture.expected.count) visits=\(visits)")
}

/// Holds the Gecko profile lock the way a running Firefox does (fcntl write lock on `.parentlock`).
func runFirefoxFixtureLock(args: [String]) {
    guard args.count == 1 else { firefoxFail(firefoxUsage, code: 2) }
    let fd = Darwin.open(URL(fileURLWithPath: args[0]).appendingPathComponent(".parentlock").path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else { firefoxFail("error: cannot open lock file", code: 1) }
    var lock = flock()
    lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
    guard fcntl(fd, F_SETLK, &lock) == 0 else { firefoxFail("error: lock is held", code: 1) }
    print("locked"); fflush(stdout)
    _ = FileHandle.standardInput.readDataToEndOfFile()
}

actor ImportHistoryWriter {
    let store: HistoryStore, key: String
    var inserted = 0, duplicates = 0, failed = false
    init(destination: URL, key: String) { store = HistoryStore(fileURL: destination); self.key = key }
    func write(_ batch: [ArcHistoryVisitRecord]) async {
        guard !failed else { return }
        let result = await store.importHistoryBatch(batch.map {
            ImportedHistoryVisit(chromiumVisitID: $0.chromiumVisitID, urlString: $0.urlString, title: $0.title,
                                 time: $0.time, transition: $0.transition, isTyped: $0.isTyped)
        }, sourceProfileKey: key)
        inserted += result.insertedVisits; duplicates += result.duplicateVisits; failed = !result.succeeded
    }
    func summary() async -> (Int, Int, Int, Bool) {
        let ready = await store.importHistoryBatch([], sourceProfileKey: key)
        return (inserted, duplicates, await store.urlCount(), failed || !ready.succeeded)
    }
}

@MainActor
func runImportFirefox(args: [String]) async throws {
    let (values, flags) = firefoxArgs(args, values: ["--firefox-root", "--db", "--profile", "--primary-password-file"], flags: ["--expect"])
    guard let rootPath = values["--firefox-root"], let dbPath = values["--db"] else { firefoxFail(firefoxUsage, code: 2) }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let expectedAll = flags.contains("--expect") ? SyntheticFirefoxFixture.readExpected(root: root) : nil
    if flags.contains("--expect"), expectedAll == nil { firefoxFail("error: --expect needs a synthetic fixture root", code: 2) }
    let profiles: [FirefoxProfile]
    do { profiles = try FirefoxProfileCatalog.profiles(root: root) }
    catch { firefoxFail("error: no Firefox profiles at \(root.path) (\(error))", code: 4) }
    print("firefox profiles: \(profiles.count)")
    for profile in profiles { print("  profile \(profile.name) default=\(profile.isDefault) locked=\(FirefoxProfileCatalog.isLocked(profile.directory))") }
    let profile = values["--profile"].flatMap { name in profiles.first { $0.name == name } } ?? profiles[0]
    if values["--profile"] != nil, profile.name != values["--profile"] { firefoxFail("error: profile not found", code: 4) }
    // Arc parity: the source must be quit before import ("Quit Firefox to continue importing").
    if FirefoxProfileCatalog.isLocked(profile.directory) { firefoxFail("error: profile in use. Quit Firefox to continue importing.", code: 5) }
    var primary = ""
    if let file = values["--primary-password-file"] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { firefoxFail("error: cannot read password file", code: 2) }
        primary = text.trimmingCharacters(in: .newlines)
    }
    let destination = URL(fileURLWithPath: dbPath)
    let dataRoot = try OpenDataRoot.prepare(storeFileURL: destination)
    defer { withExtendedLifetime(dataRoot) {} }
    var ok = true
    func check(_ label: String, _ actual: Int, _ expected: Int?) {
        guard let expected else { return }
        let pass = actual == expected
        ok = ok && pass
        print("  expect \(label)=\(expected) actual=\(actual) \(pass ? "OK" : "MISMATCH")")
    }
    let expected = expectedAll?.first { $0.profile == profile.name }
    print("import profile=\(profile.name) key=\(profile.sourceKey)")

    // Bookmarks → "Imported from Firefox" (pinned folder; built as live nodes to prove the model mapping).
    let reader = FirefoxPlacesReader(profileDirectory: profile.directory)
    let started = ContinuousClock.now
    let bookmarks = try await Task.detached(priority: .utility) { try reader.readBookmarks() }.value
    let folder = ImportedBookmarksFolder.make(browserName: "Firefox", sourceKey: profile.sourceKey, roots: bookmarks.roots)
    func countNodes(_ nodes: [SidebarNode]) -> (tabs: Int, folders: Int) {
        nodes.reduce((0, 0)) { sum, node in
            switch node {
            case .tab: return (sum.0 + 1, sum.1)
            case .folder(let f): let inner = countNodes(f.children); return (sum.0 + inner.tabs, sum.1 + 1 + inner.folders)
            case .split(let s): return (sum.0 + s.panes.count, sum.1)
            }
        }
    }
    let live = countNodes(folder.children)
    let r = bookmarks.report
    print("bookmarks: rows=\(r.sourceRows) urls=\(r.urls) folders=\(r.folders) separators=\(r.skippedSeparators) unsupported=\(r.skippedUnsupportedURL) emptyFolders=\(r.skippedEmptyFolders) other=\(r.skippedOther)")
    print("  folder \"\(folder.title)\" id=\(folder.id.rawValue.uuidString.prefix(8)) tabs=\(live.tabs) subfolders=\(live.folders) roots=\(folder.children.compactMap { $0.folder?.title })")
    print("  check accounted=\(r.accounted) rows=\(r.sourceRows) \(r.accounted == r.sourceRows ? "OK" : "MISMATCH")")
    ok = ok && r.accounted == r.sourceRows && live.tabs == r.urls && live.folders == r.folders
    check("bookmarkRows", r.sourceRows, expected?.bookmarkRows)
    check("bookmarkURLs", r.urls, expected?.bookmarkURLs)
    check("bookmarkFolders", r.folders, expected?.bookmarkFolders)
    check("bookmarkSeparators", r.skippedSeparators, expected?.bookmarkSeparators)
    check("bookmarkUnsupported", r.skippedUnsupportedURL, expected?.bookmarkUnsupported)
    check("bookmarkEmptyFolders", r.skippedEmptyFolders, expected?.bookmarkEmptyFolders)
    check("bookmarkOther", r.skippedOther, expected?.bookmarkOther)
    if let titles = expected?.rootTitles {
        let actual = folder.children.compactMap { $0.folder?.title }
        ok = ok && actual == titles
        print("  expect roots=\(titles) \(actual == titles ? "OK" : "MISMATCH")")
    }

    // History → the Profile history store, through the same batch API as Import from Arc.
    let writer = ImportHistoryWriter(destination: destination, key: profile.sourceKey)
    let history = try await Task.detached(priority: .utility) {
        try await reader.readHistory { batch in await writer.write(batch) }
    }.value
    let (inserted, duplicates, urlCount, failed) = await writer.summary()
    let readSum = history.keptVisits + history.skippedInternal + history.skippedSubframe + history.skippedInvalidTime
    print("history: placeRows=\(history.sourceURLRows) visitRows=\(history.sourceVisitRows) kept=\(history.keptVisits) inserted=\(inserted) duplicates=\(duplicates)")
    print("  skipped internal=\(history.skippedInternal) subframe=\(history.skippedSubframe) invalidTime=\(history.skippedInvalidTime) urlsInStore=\(urlCount)")
    print("  check read=\(readSum == history.sourceVisitRows ? "OK" : "MISMATCH") write=\(inserted + duplicates == history.keptVisits && !failed ? "OK" : "MISMATCH")")
    ok = ok && readSum == history.sourceVisitRows && inserted + duplicates == history.keptVisits && !failed
    check("visitRows", history.sourceVisitRows, expected?.visitRows)
    check("visitsKept", history.keptVisits, expected?.visitsKept)
    check("visitsInternal", history.skippedInternal, expected?.visitsInternal)
    check("visitsSubframe", history.skippedSubframe, expected?.visitsSubframe)
    check("visitsInvalidTime", history.skippedInvalidTime, expected?.visitsInvalidTime)
    let top = try reader.topSites(limit: 5)
    print("  topSites=\(top.count) first=\(top.first?.url.host() ?? "-")")

    // Form data. Open has no engine write path for autocomplete entries yet (IMF question); read and count only.
    let formReader = FirefoxFormHistoryReader(profileDirectory: profile.directory)
    let form = try await Task.detached(priority: .utility) { try await formReader.read { _ in } }.value
    print("form data: rows=\(form.sourceRows) kept=\(form.kept) empty=\(form.skippedEmpty) oversize=\(form.skippedOversize) (not written: no engine sink)")
    check("formRows", form.sourceRows, expected?.formRows)
    check("formKept", form.kept, expected?.formKept)

    // Logins. Values never print; with --expect, the synthetic fixture's own values are checked.
    let logins = FirefoxLoginsReader(profileDirectory: profile.directory)
    let needsPrimary = try logins.needsPrimaryPassword()
    print("logins: rows=\(try logins.countOnly()) primaryPassword=\(needsPrimary ? "set" : "none")")
    if let expected { check("primaryPassword", needsPrimary ? 1 : 0, expected.primaryPassword ? 1 : 0) }
    if needsPrimary && primary.isEmpty {
        print("  skipped: Primary Password required")
    } else {
        do {
            var read = try logins.read(primaryPassword: primary)
            defer { for index in read.logins.indices { read.logins[index].zeroSecrets() } }
            let rep = read.report
            print("  kept=\(rep.kept) unsupported=\(rep.skippedUnsupportedOrigin) decryptFailed=\(rep.skippedDecryptFailed) oversize=\(rep.skippedOversize)")
            ok = ok && rep.accounted == rep.sourceRows
            check("loginRows", rep.sourceRows, expected?.loginRows)
            check("loginsKept", rep.kept, expected?.loginsKept)
            check("loginsUnsupported", rep.skippedUnsupportedOrigin, expected?.loginsUnsupported)
            if expected != nil {
                // Synthetic values are generated as "synthetic-user-<seed>-<n>" / "synthetic-pass-<seed>-<n>".
                let shape = read.logins.allSatisfy { login in
                    let suffix = login.username.replacingOccurrences(of: "synthetic-user-", with: "")
                    return login.username.hasPrefix("synthetic-user-") && login.passwordBytes == Array("synthetic-pass-\(suffix)".utf8)
                        && login.signonRealm.hasPrefix(login.originURLString.dropLast()) && login.dateLastUsed != nil
                }
                let realms = read.logins.filter { $0.scheme == 1 }.count
                ok = ok && shape && realms == 1
                print("  expect decrypted values match fixture \(shape ? "OK" : "MISMATCH"); httpAuth=\(realms) \(realms == 1 ? "OK" : "MISMATCH")")
            }
        } catch FirefoxImportError.primaryPasswordRequired {
            print("  skipped: Primary Password is wrong")
            if expected != nil { ok = false }
        }
    }
    let duration = ContinuousClock.now - started
    print(String(format: "elapsed=%.3fs", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18))
    print(ok ? "RESULT PASS" : "RESULT FAIL")
    if !ok { exit(1) }
}
