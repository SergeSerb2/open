import AppKit
import OpenDesign
import OpenModel
import OpenStore

MainActor.assumeIsolated {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        // SM6 owns initialization so its disposable preferences precede AppKit.
        if args.first != "sm6-measure" {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }
        try RenderCLI.run(args)
    } catch {
        FileHandle.standardError.write(Data("sidebar-render: \(error)\n".utf8))
        exit(1)
    }
}
