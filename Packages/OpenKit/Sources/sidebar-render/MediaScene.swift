import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Step 2 row scenes only. Mini-player scene/host wiring remains Step 3 (lead clarification).
@MainActor enum MediaScene {
    static func apply(_ args: [String], context: SidebarContext) throws {
        if args.contains("--reduce-motion") { SidebarDiagnostics.mediaReduceMotionOverride = true }
        guard let spec = RenderCLI.value(args, "--media") else { return }
        // LayerCloner does not preserve the native RBSymbolLayer tint. Static SF glyphs
        // use the same left anchor and draw the correct role color (lead D2 option).
        SidebarDiagnostics.mediaReduceMotionOverride = true
        for item in spec.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let id = RenderCLI.resolve(pair[0], context: context), let tab = context.model.tab(id: id) else {
                throw CLIError(description: "invalid row media spec: \(item)")
            }
            let flags = Set(pair[1].split(separator: ":").map(String.init))
            let valid: Set<String> = ["audible", "playing", "paused", "silent", "muted", "recording", "video"]
            guard flags.isSubset(of: valid) else { throw CLIError(description: "invalid row media state: \(pair[1])") }
            tab.live.hasWebContent = true
            tab.live.isAudible = flags.contains("audible") || flags.contains("playing")
            context.model.setMuted(tabID: tab.id, muted: flags.contains("muted"))
            tab.live.isCapturing = flags.contains("recording")
            if let depth = RenderCLI.value(args, "--media-depth").flatMap(Int.init), depth > 0,
               let space = context.focusedSpace {
                var node = tab.id
                for level in 0..<min(depth, 20) {
                    guard let folder = context.model.createFolder(in: .spacePinned(space.id), title: "Media folder \(level + 1)", withNodes: [node]) else { break }
                    node = folder.id
                }
            }
        }
        if let theme = RenderCLI.value(args, "--media-theme"), let space = context.focusedSpace {
            switch theme {
            case "default": space.theme = SpaceTheme()
            case "red":
                space.theme = SpaceTheme(importedArcThemeJSON: Synthetic.themeJSON(base: [0xCC334D, 0xFF6655], overlay: nil, noise: 0,
                    intensity: 0.8, appearance: context.systemAppearance == .dark ? "dark" : "light"))
            default: throw CLIError(description: "invalid media theme: \(theme)")
            }
        }
    }
}
