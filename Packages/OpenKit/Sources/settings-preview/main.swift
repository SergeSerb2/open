import AppKit
import SwiftUI
import OpenSettings
import OpenModel
import OpenCommands
import OpenStore

@MainActor final class PreviewActions: SettingsActions {
    var log: [String] = []
    var defaultError: String?
    func record(_ text: String) { log.append(text); print("ACTION \(text)") }
    func setAsDefaultBrowser() -> String? { record("setAsDefaultBrowser"); return defaultError }
    func isDefaultBrowser() -> Bool { false }
    func checkForUpdates() { record("checkForUpdates") }
    func openMoreSettings() { record("openMoreSettings") }
    func revealOpenDataFolder() { record("revealOpenDataFolder") }
    func copyOpenInfoToPasteboard() { record("copyOpenInfoToPasteboard") }
    func deleteProfileData(profileID: ProfileID) -> String? { record("deleteProfileData \(profileID)"); return nil }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String? { await clearBrowsingData(profileID: profileID, kinds: kinds, range: .all) }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String? { record("clearBrowsingData \(profileID) kinds=\(kinds.rawValue) range=\(range.rawValue)"); return nil }
    func openProfileSubpage(profileID: ProfileID, page: ProfilePage) { record("openProfileSubpage \(profileID) \(page.rawValue)") }
    func openPreviewsSettings() { record("openPreviewsSettings") }
    func keyBindingsDidChange(store: KeyBindingStore) { record("keyBindingsDidChange") }
    func runImport(plan: ImportPlan) async -> ImportOutcome { record("runImport consent=\(plan.secretsConsented)"); return ImportOutcome() }
    func setAdBlockEnabled(_ on: Bool, profileID: ProfileID) { record("setAdBlockEnabled \(on) \(profileID)") }
    func setEnabledBlockLists(_ ids: [String], profileID: ProfileID) { record("setEnabledBlockLists \(ids.joined(separator: ",")) \(profileID)") }
    func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID) { record("setAdBlockExcludedDomains \(domains.joined(separator: ",")) \(profileID)") }
    func adBlockDebugInfo(profileID: ProfileID) -> String { "synthetic" }
    func setTabSleepMode(_ mode: TabSleepMode) { record("setTabSleepMode \(mode.rawValue)") }
    func setApplicationIcon(id: String) { record("setApplicationIcon \(id)") }
    func resetTranslatePrompts(profileID: ProfileID) -> String? { record("resetTranslatePrompts \(profileID)"); return nil }
    func openHelp(topic: String) { record("openHelp \(topic)") }
    func copyText(_ text: String) { record("copyText") }
    func openLibrary() { record("openLibrary") }
}

@MainActor func render<V: View>(_ view: V, size: CGSize, scale: Int, dark: Bool, to url: URL) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "render", code: 1) }
    rep.size = size; host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), data.count > 1000 else { throw NSError(domain: "render", code: 2) }
    try data.write(to: url); print("PNG \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(data.count) bytes")
    window.contentView = nil; window.close()
}
@MainActor func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") { print("settings-preview render --out DIR [--scale 1|2|both]\nsettings-preview check [--only NAME]\nsettings-preview dump-keys --root DIR"); return }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0+1] : nil } }
    if args[0] == "check" { try await runChecks(only: value("--only")); return }
    let env = try PreviewEnvironment(); defer { env.close() }
    let settings = env.settings
    let library = env.library
    if args[0] == "render" {
        guard let out = value("--out") else { throw NSError(domain: "--out required", code: 2) }
        let output = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rawScale = value("--scale") ?? "both"
        guard ["1", "2", "both"].contains(rawScale) else { throw NSError(domain: "invalid scale", code: 2) }
        let scales = rawScale == "both" ? [1,2] : [Int(rawScale)!]
        for (i,pane) in PaneID.allCases.enumerated() {
            settings.selectedPane = pane
            for scale in scales { try render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: i % 2 == 0, to: output.appendingPathComponent("\(pane == .appIcon ? "app-icon" : pane.rawValue)@\(scale)x.png")) }
        }
        for (i,section) in LibrarySection.allCases.enumerated() {
            library.section = section
            for scale in scales { try render(LibraryContent(viewModel: library), size: CGSize(width: 960, height: 640), scale: scale, dark: i % 2 == 0, to: output.appendingPathComponent("library-\(section.rawValue)@\(scale)x.png")) }
        }
        for pane in [PaneID.general, .profiles] { settings.selectedPane = pane; for dark in [false,true] { for scale in scales { try render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: dark, to: output.appendingPathComponent("\(pane.rawValue)-\(dark ? "dark" : "light")@\(scale)x.png")) } } }
    } else { throw NSError(domain: "command not implemented", code: 2) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in do { try await run(); exit(0) } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) } }
app.run()
