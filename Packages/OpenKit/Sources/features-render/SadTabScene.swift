import AppKit
import OpenDesign
import OpenFeatures

/// Render the production placeholder without a renderer, window ordering, or crash probe.
@MainActor enum SadTabScene {
    static func render(_ args: [String]) throws {
        let allowed = ["--scene", "--out", "--scale", "--appearance"]
        guard (5...9).contains(args.count), args.count % 2 == 1 else { throw CLIError(description: "invalid sad-tab options") }
        let keys = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        guard keys.allSatisfy({ allowed.contains($0) }), Set(keys).count == keys.count,
              let out = RenderCLI.value(args, "--out"),
              let scale = Double(RenderCLI.value(args, "--scale") ?? "1"), [1, 2].contains(scale),
              let appearance = ["light": NSAppearance.Name.aqua, "dark": .darkAqua][RenderCLI.value(args, "--appearance") ?? "light"]
        else { throw CLIError(description: "sad-tab requires --out FILE [--scale 1|2] [--appearance light|dark]") }
        NSApp.appearance = NSAppearance(named: appearance)
        let view = SadTabView(style: .defaultTheme(system: appearance == .darkAqua ? .dark : .light))
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 540)
        OffscreenRenderer.writePNG(OffscreenRenderer().render(view, scale: scale), to: URL(fileURLWithPath: out))
        print("rendered \(out) 800×540 pt; AX buttons: \(view.reloadButton.accessibilityLabel() ?? ""), \(view.closeButton.accessibilityLabel() ?? ""); default: Reload")
    }
}
