import Foundation
import OpenImport
import OpenStore

private let historyImportUsage = "usage: openkit import-arc-history --arc-user-data DIR --db PATH [--profile NAME]"

struct ImportCLIArguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var profile: String { values["--profile"] ?? "Default" }

    init(_ args: [String], values allowedValues: Set<String>, flags allowedFlags: Set<String> = []) throws {
        var index = 0
        while index < args.count {
            let flag = args[index]
            if allowedValues.contains(flag), index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                guard values[flag] == nil else { throw ImportCLIUsageError.invalid }
                index += 1
                values[flag] = args[index]
            } else if allowedFlags.contains(flag) {
                guard flags.insert(flag).inserted else { throw ImportCLIUsageError.invalid }
            } else { throw ImportCLIUsageError.invalid }
            index += 1
        }
        guard values["--arc-user-data"]?.isEmpty == false,
              !profile.isEmpty, profile != ".", profile != "..", !profile.contains("/"),
              !profile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportCLIUsageError.invalid
        }
    }
}

enum ImportCLIUsageError: Error { case invalid }

func importCLIError(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func importCLIProfile(_ args: ImportCLIArguments) -> URL {
    let root = URL(fileURLWithPath: args.values["--arc-user-data"]!, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        importCLIError("error: Arc user data dir not found at \(root.path).", code: 4)
    }
    let profile = root.appendingPathComponent(args.profile, isDirectory: true)
    guard FileManager.default.fileExists(atPath: profile.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        importCLIError("error: profile \(args.profile) not found.", code: 4)
    }
    return profile
}

func importPath(_ destination: URL, isWithin source: URL) -> Bool {
    let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
    let root = source.resolvingSymlinksInPath().standardizedFileURL.path
    return target == root || target.hasPrefix(root + "/")
}

func runImportArcHistory(args: [String]) async {
    let options: ImportCLIArguments
    do {
        options = try ImportCLIArguments(args, values: ["--arc-user-data", "--db", "--profile"])
        guard options.values["--db"]?.isEmpty == false else { throw ImportCLIUsageError.invalid }
    } catch { importCLIError(historyImportUsage, code: 2) }
    let profile = importCLIProfile(options)
    let source = profile.appendingPathComponent("History")
    let destination = URL(fileURLWithPath: options.values["--db"]!)
    let arcRoot = URL(fileURLWithPath: options.values["--arc-user-data"]!)
    guard !importPath(destination, isWithin: arcRoot),
          !importPath(destination, isWithin: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc")) else {
        importCLIError("error: destination must be outside Arc data.", code: 2)
    }
    let dataRoot: OpenDataRoot.Preparation
    do { dataRoot = try await OpenDataRoot.prepare(storeFileURL: destination) }
    catch { importCLIError("error: cannot prepare destination: \(error)", code: 1) }
    defer { withExtendedLifetime(dataRoot) {} }
    let start = ContinuousClock.now
    let result: (report: ArcHistoryReadReport, inserted: Int, duplicates: Int, urlCount: Int, failed: Bool)
    do {
        result = try await Task.detached(priority: .utility) {
            let writer = HistoryBatchWriter(destination: destination, profile: options.profile)
            let report = try await ArcHistoryReader(historyFileURL: source).readBatches { batch in
                await writer.write(batch)
            }
            let summary = await writer.summary()
            return (report, summary.inserted, summary.duplicates, summary.urlCount, summary.failed)
        }.value
    } catch ArcHistoryImportError.missingHistoryFile {
        importCLIError("error: History file not found at \(source.path).", code: 4)
    } catch ArcHistoryImportError.schemaVersionMismatch(let version) {
        importCLIError("error: History schema version \(version) outside 65...75.", code: 4)
    } catch ArcHistoryImportError.schemaMismatch {
        importCLIError("error: History schema mismatch.", code: 4)
    } catch { importCLIError("error: History copy failed. Quit Arc and run again.", code: 4) }
    let duration = ContinuousClock.now - start
    let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    let inserted = result.inserted, duplicates = result.duplicates, urlCount = result.urlCount
    let report = result.report
    let readSum = report.keptVisits + report.skippedInternal + report.skippedSubframe + report.skippedInvalidTime
    let writeSum = inserted + duplicates
    let readOK = readSum == report.sourceVisitRows
    let writeOK = writeSum == report.keptVisits && !result.failed
    print("history import:")
    print("  source profile=\(options.profile) urlRows=\(report.sourceURLRows) visitRows=\(report.sourceVisitRows)")
    print("  kept=\(report.keptVisits) inserted=\(inserted) duplicates=\(duplicates)")
    print("  skipped internal=\(report.skippedInternal) subframe=\(report.skippedSubframe) invalidTime=\(report.skippedInvalidTime)")
    print("  keywordSearchTerms=\(report.keywordSearchTermRows) (not imported)")
    print("  urls in store=\(urlCount)")
    print(String(format: "  elapsed=%.3fs visitsPerSecond=%d", elapsed, Int(Double(report.keptVisits) / max(elapsed, 0.000001))))
    print("  check read: kept+skipped=\(readSum) visitRows=\(report.sourceVisitRows) \(readOK ? "OK" : "MISMATCH")")
    print("  check write: inserted+duplicates=\(writeSum) kept=\(report.keptVisits) \(writeOK ? "OK" : "MISMATCH")")
    if !readOK || !writeOK { exit(1) }
}

/// Owns write totals while the reader awaits each batch. No visit array survives a write.
private actor HistoryBatchWriter {
    let store: HistoryStore
    let profile: String
    var inserted = 0
    var duplicates = 0
    var failed = false

    init(destination: URL, profile: String) {
        store = HistoryStore(fileURL: destination)
        self.profile = profile
    }

    func write(_ batch: [ArcHistoryVisitRecord]) async {
        guard !failed else { return }
        let result = await store.importHistoryBatch(batch.map {
            ImportedHistoryVisit(chromiumVisitID: $0.chromiumVisitID, urlString: $0.urlString, title: $0.title,
                                 time: $0.time, transition: $0.transition, isTyped: $0.isTyped)
        }, sourceProfileKey: profile)
        inserted += result.insertedVisits
        duplicates += result.duplicateVisits
        failed = !result.succeeded
    }

    func summary() async -> (inserted: Int, duplicates: Int, urlCount: Int, failed: Bool) {
        // An empty transaction validates the destination even when there are no kept visits.
        let ready = await store.importHistoryBatch([], sourceProfileKey: profile)
        return (inserted, duplicates, await store.urlCount(), failed || !ready.succeeded)
    }
}
