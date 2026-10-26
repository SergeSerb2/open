import AppKit
import OpenDesign
import OpenModel
import OpenStore

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        try RenderCLI.run(args)
    } catch {
        FileHandle.standardError.write(Data("sidebar-render: \(error)\n".utf8))
        exit(1)
    }
}
