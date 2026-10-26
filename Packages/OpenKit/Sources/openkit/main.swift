import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: openkit <import-arc|archive-list|dump|roundtrip|bench|commands-demo|suggest|suggest-check|route> ...")
    exit(2)
}
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "import-arc":
        try await runImportArc(args: rest)
    case "archive-list":
        await runArchiveList(args: rest)
    case "dump":
        try await MainActor.run { try runDump(args: rest) }
    case "roundtrip":
        try await MainActor.run { try runRoundtrip(args: rest) }
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
