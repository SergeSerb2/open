import AppKit
import OpenDesign
import OpenWeb
import OpenExtensionsUI
import Darwin

struct CLIError: Error, CustomStringConvertible { let description: String }
@MainActor func main() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, Scenes.names.contains(command) || ["all", "check", "menus"].contains(command) else {
        throw CLIError(description: "usage: extensions-render <scene|all|check|menus> [--scale 1|2] [--appearance light|dark] [--out DIR]")
    }
    var scale: CGFloat = 2, appearance = ContentAppearance.light
    var out = URL(fileURLWithPath: "extensions-renders", isDirectory: true), i = 1
    var seen = Set<String>()
    while i < args.count {
        let flag = args[i]
        guard ["--scale", "--appearance", "--out"].contains(flag), !seen.contains(flag), i + 1 < args.count else { throw CLIError(description: "invalid or duplicate option: \(flag)") }
        seen.insert(flag)
        switch flag {
        case "--scale": guard ["1", "2"].contains(args[i + 1]) else { throw CLIError(description: "scale must be 1 or 2") }; scale = CGFloat(Int(args[i + 1])!)
        case "--appearance": guard let value = ContentAppearance(rawValue: args[i + 1]) else { throw CLIError(description: "appearance must be light or dark") }; appearance = value
        default: out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        i += 2
    }
    if command == "check", let status = try Checks.relaunchWithObserverIfNeeded() { return status }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = appearance.nsAppearance
    if command == "check" { return try Checks.run() ? 0 : 1 }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    if command == "menus" {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, model) in Synthetic.menuModels() { try encoder.encode(model).write(to: out.appendingPathComponent("\(name).json")) }
        let context = Synthetic.contextMenuItems()
        func relabeled(_ items: [OpenWeb.ExtensionMenuItem]) -> [OpenWeb.ExtensionMenuItem] {
            items.map { value in var item = value; item.title = ExtensionsMenuBuilder.relabel(value.title); item.submenu = relabeled(value.submenu); return item }
        }
        try encoder.encode(context).write(to: out.appendingPathComponent("context-chromium.json"))
        try encoder.encode(relabeled(context)).write(to: out.appendingPathComponent("context-open.json"))
        print("menus: bar, overflow, little-open, context (Chromium/Open) → \(out.path)"); return 0
    }
    let renderer = ExtensionsRenderer()
    for name in command == "all" ? Scenes.names : [command] {
        let view = Scenes.make(name, appearance: appearance)
        let image = renderer.render(view, scale: scale)
        let file = out.appendingPathComponent("\(name)-\(appearance.rawValue)-\(Int(scale))x.png")
        try ExtensionsRenderer.writePNG(image, to: file)
        guard FileManager.default.fileExists(atPath: file.path) else { throw CLIError(description: "PNG write failed") }
        print("PASS \(name) \(image.width)×\(image.height) → \(file.path)")
    }
    return 0
}
do { exit(try main()) }
catch { fputs("extensions-render: \(error)\n", stderr); exit(2) }
