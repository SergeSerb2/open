import AppKit
import Foundation

/// Requests activation of one already-running e2e app. It never launches an
/// application or resolves a bundle identifier to another worktree's instance.
@main
struct ActivateOwnApp {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let pid = Int32(args[1]),
              let app = NSRunningApplication(processIdentifier: pid),
              let executable = app.executableURL,
              executable.resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().standardizedFileURL else {
            FileHandle.standardError.write(Data("Refused activation: PID does not match the exact e2e executable.\n".utf8))
            exit(2)
        }
        let accepted = app.activate(options: [])
        print("{\"pid\":\(pid),\"accepted\":\(accepted)}")
        exit(accepted ? 0 : 1)
    }
}
