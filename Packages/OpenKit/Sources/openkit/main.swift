import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: openkit <import-arc|dump|roundtrip|bench|commands-demo> ...")
    exit(2)
}
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "import-arc":
        try await MainActor.run { try runImportArc(args: rest) }
    case "dump":
        try await MainActor.run { try runDump(args: rest) }
    case "roundtrip":
        try await MainActor.run { try runRoundtrip(args: rest) }
    case "bench":
        await runBench()
    case "commands-demo":
        try await MainActor.run { try runCommandsDemo(args: rest) }
    default:
        print("unknown command: \(command)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
