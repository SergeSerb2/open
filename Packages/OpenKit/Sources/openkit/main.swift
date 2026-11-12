import Foundation
import OpenImport

let sweptImportCopies = sweepStaleImportCopies()
if sweptImportCopies > 0 {
    FileHandle.standardError.write(Data("import cleanup: removed \(sweptImportCopies) stale copies\n".utf8))
}

// One append-only entry registers both dispatch and usage. Handlers share the
// main actor; commands that need background work opt out inside their handler.
let commands: [(name: String, handler: @MainActor ([String]) async throws -> Void)] = [
    ("import-arc", { try await runImportArc(args: $0) }),
    ("import-arc-history", { await runImportArcHistory(args: $0) }),
    ("import-arc-secrets", { args in await Task.detached(priority: .utility) { runImportArcSecrets(args: args) }.value }),
    ("firefox-fixture", { try runFirefoxFixture(args: $0) }),
    ("firefox-fixture-lock", { runFirefoxFixtureLock(args: $0) }),
    ("import-firefox", { try await runImportFirefox(args: $0) }),
    ("verify-secrets-fixture",{ try await runSyntheticSecretsFixture(args: $0) }),
    ("archive-list", { await runArchiveList(args: $0) }),
    ("dump", { try runDump(args: $0) }),
    ("roundtrip", { try runRoundtrip(args: $0) }),
    ("bench", { _ in try await runBench() }),
    ("commands-demo", { try await runCommandsDemo(args: $0) }),
    ("suggest", { await runSuggestCommand("suggest", args: $0) }),
    ("suggest-check", { await runSuggestCommand("suggest-check", args: $0) }),
    ("route", { try runRoute(args: $0) }),
    ("favicons", { try await runFavicons(args: $0) }),
    ("profiles", { try runProfiles(args: $0) }),
    ("adblock", { try await runAdBlock(args: $0) }),
    ("media-demo", { try await runMediaDemo(args: $0) }),
    ("sleep-demo", { try await runSleepDemo(args: $0) }),
    ("sleep-sim", { try await runSleepSimulation(args: $0) }),
    ("url-clean", { try runURLClean(args: $0) }),
    ("lang-detect", { try runLangDetect(args: $0) }),
]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, let entry = commands.first(where: { $0.name == command }) else {
    if let command = arguments.first { print("unknown command: \(command)") }
    print("usage: openkit <\(commands.map(\.name).joined(separator: "|"))> ...")
    exit(2)
}

do {
    try await entry.handler(Array(arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
