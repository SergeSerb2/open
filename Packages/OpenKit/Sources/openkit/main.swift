import Foundation
import OpenImport

let sweptImportCopies = sweepStaleImportCopies()
if sweptImportCopies > 0 {
    FileHandle.standardError.write(Data("import cleanup: removed \(sweptImportCopies) stale copies\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: openkit <import-arc|import-arc-history|import-arc-secrets|verify-secrets-fixture|archive-list|dump|roundtrip|bench|commands-demo|suggest|suggest-check|route|favicons|profiles|sleep-demo|sleep-sim> ...")
    exit(2)
}
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "verify-secrets-fixture":
        try runSyntheticSecretsFixture()
    case "import-arc-secrets":
        await Task.detached(priority: .utility) { runImportArcSecrets(args: rest) }.value
    case "import-arc-history":
        await runImportArcHistory(args: rest)
    case "import-arc":
        try await runImportArc(args: rest)
    case "sleep-demo": try await runSleepDemo(args: rest)
    case "sleep-sim": try await runSleepSimulation(args: rest)
    case "archive-list":
        await runArchiveList(args: rest)
    case "dump":
        try await MainActor.run { try runDump(args: rest) }
    case "roundtrip":
        try await MainActor.run { try runRoundtrip(args: rest) }
    case "profiles":
        try await MainActor.run { try runProfiles(args: rest) }
    case "route":
        try await MainActor.run { try runRoute(args: rest) }
    case "bench":
        await runBench()
    case "commands-demo":
        try await runCommandsDemo(args: rest)
    case "suggest", "suggest-check": await runSuggestCommand(command, args: rest)
    case "favicons": try await runFavicons(args: rest)
    default:
        print("unknown command: \(command)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
