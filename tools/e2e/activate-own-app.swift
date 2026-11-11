import AppKit
import Foundation

/// Requests activation of one already-running e2e app. It never launches an
/// application or resolves a bundle identifier to another worktree's instance.
private func sameExecutableFile(_ actual: URL, _ expected: URL) -> Bool {
    // Chromium's persistent CodeSignClones executable is a hard link. Compare
    // the file identity, never just a name, prefix, or equal contents.
    guard let first = try? FileManager.default.attributesOfItem(atPath: actual.path),
          let second = try? FileManager.default.attributesOfItem(atPath: expected.path),
          let firstDevice = first[.systemNumber] as? NSNumber,
          let firstInode = first[.systemFileNumber] as? NSNumber,
          let secondDevice = second[.systemNumber] as? NSNumber,
          let secondInode = second[.systemFileNumber] as? NSNumber else { return false }
    return firstDevice == secondDevice && firstInode == secondInode
}

@main
struct ActivateOwnApp {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let pid = Int32(args[1]),
              let app = NSRunningApplication(processIdentifier: pid),
              let executable = app.executableURL,
              sameExecutableFile(executable, URL(fileURLWithPath: args[2])) else {
            FileHandle.standardError.write(Data("Refused activation: PID does not match the exact e2e executable.\n".utf8))
            exit(2)
        }
        let accepted = app.activate(options: [])
        print("{\"pid\":\(pid),\"accepted\":\(accepted)}")
        exit(accepted ? 0 : 1)
    }
}
