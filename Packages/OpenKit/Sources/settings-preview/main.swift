import AppKit
import SwiftUI
import OpenSettings
import OpenModel
import OpenCommands
import OpenStore
import CryptoKit

@MainActor final class PreviewActions: SettingsActions {
    var log: [String] = []
    var defaultError: String?
    var canImportPasswordsAndCookies = false
    var importHandler: (@MainActor (ImportPlan) async -> ImportOutcome)?
    var importPlansWithConsent = 0
    func record(_ text: String) { log.append(text); print("ACTION \(text)") }
    func setAsDefaultBrowser() -> String? { record("setAsDefaultBrowser"); defer { defaultError = nil }; return defaultError }
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
    func runImport(plan: ImportPlan) async -> ImportOutcome { if plan.secretsConsented {importPlansWithConsent += 1}; record("runImport consent=\(plan.secretsConsented)"); return await importHandler?(plan) ?? ImportOutcome(errorText: "Import adapter unavailable.") }
    func setAdBlockEnabled(_ on: Bool, profileID: ProfileID) { record("setAdBlockEnabled \(on) \(profileID)") }
    func setEnabledBlockLists(_ ids: [String], profileID: ProfileID) { record("setEnabledBlockLists \(ids.joined(separator: ",")) \(profileID)") }
    func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID) { record("setAdBlockExcludedDomains \(domains.joined(separator: ",")) \(profileID)") }
    func adBlockDebugInfo(profileID: ProfileID) -> String { "synthetic" }
    func setTabSleepMode(_ mode: TabSleepMode) { record("setTabSleepMode \(mode.rawValue)") }
    func setApplicationIcon(id: String) { record("setApplicationIcon \(id)") }
    func resetTranslatePrompts(profileID: ProfileID) -> String? { record("resetTranslatePrompts \(profileID)"); return nil }
    func openURL(_ url: URL, profileID: ProfileID) { record("openURL host=\(url.host() ?? "") \(profileID)") }
    func openHelp(topic: String) { record("openHelp \(topic)") }
    func copyText(_ text: String) { record("copyText") }
    func openLibrary() { record("openLibrary") }
}

@discardableResult @MainActor func render<V: View>(_ view: V, size: CGSize, scale: Int, dark: Bool, to url: URL) async throws -> [String] {
    let previousAppearance=NSApp.appearance
    let appearance=NSAppearance(named:dark ? .darkAqua:.aqua)!
    NSApp.appearance=appearance
    defer {NSApp.appearance=previousAppearance}
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance=appearance
    host.frame = CGRect(origin: .zero, size: size)
    let window = RenderWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.scale = CGFloat(scale); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
    for _ in 0..<3 {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for:.milliseconds(50))
    }
    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    guard host.bitmapImageRepForCachingDisplay(in: host.bounds) != nil else { throw CheckFailure(description: "hosting view has no bitmap surface") }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "render", code: 1) }
    rep.size = size; host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), data.count > 1000 else { throw NSError(domain: "render", code: 2) }
    guard let pixels = rep.bitmapData else { throw CheckFailure(description: "missing pixels") }
    var opaque = true; var colors = Set<UInt32>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 8) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
        let offset = y * rep.bytesPerRow + x * 4
        opaque = opaque && pixels[offset + 3] == 255
        colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset+1]) << 8 | UInt32(pixels[offset+2]))
    } }
    guard opaque && colors.count > 1 else { throw CheckFailure(description: "transparent or blank PNG") }
    let labels = accessibilityLabels(host)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try data.write(to: url); print("PNG \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(data.count) bytes sha256=\(hash)")
    window.contentView = nil; window.close()
    return labels
}
@MainActor func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") { print("settings-preview render --out DIR [--scale 1|2|both]\nsettings-preview check [--only NAME]\nsettings-preview dump-keys --root DIR"); return }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0+1] : nil } }
    if args[0] == "dump-keys" { guard let root = value("--root") else { throw CheckFailure(description: "--root is required") }; try dumpKeys(root: URL(fileURLWithPath: root)); return }
    if args[0] == "check" { try await runChecks(only: value("--only")); return }
    let env = try PreviewEnvironment(); defer { env.close() }
    let settings = env.settings
    let library = env.library
    try await env.prepareAdBlock()
    try await env.prepareLibrary()
    if args[0] == "render" {
        guard let out = value("--out") else { throw NSError(domain: "--out required", code: 2) }
        let output = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        settings.set(true,for:"open.general.searchSuggestNoticeDismissed") // render an acknowledged synthetic Profile
        let rawScale = value("--scale") ?? "both"
        guard ["1", "2", "both"].contains(rawScale) else { throw NSError(domain: "invalid scale", code: 2) }
        let scales = rawScale == "both" ? [1,2] : [Int(rawScale)!]
        for pane in PaneID.allCases {
            settings.selectedPane = pane
            for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: true, to: output.appendingPathComponent("\(pane == .appIcon ? "app-icon" : pane.rawValue)@\(scale)x.png")) }
        }
        for section in LibrarySection.allCases {
            library.section = section
            for scale in scales { try await render(LibraryContent(viewModel: library), size: CGSize(width: 960, height: 640), scale: scale, dark: true, to: output.appendingPathComponent("library-\(section.rawValue)@\(scale)x.png")) }
        }
        for pane in [PaneID.general, .profiles] { settings.selectedPane = pane; for dark in [false,true] { for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: dark, to: output.appendingPathComponent("\(pane.rawValue)-\(dark ? "dark" : "light")@\(scale)x.png")) } } }
        settings.links.testURLString="example.com/x";settings.links.runTest()
        // Tall panes have additional viewport captures, using the same view and scroll entry point.
        for (pane, target, name) in [(PaneID.links, "links-rules", "links-rules"), (.links, "links-test", "links-test"), (.advanced, "advanced-adblock", "advanced-adblock"), (.advanced, "advanced-sleep", "advanced-sleep-data")] {
            settings.selectedPane = pane; settings.scrollTarget = target
            for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: true, to: output.appendingPathComponent("\(name)@\(scale)x.png")) }
        }
        settings.scrollTarget = nil; settings.selectedPane = .shortcuts; settings.shortcuts.query = "New Tab"
        for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 684, height: 650), scale: scale, dark: false, to: output.appendingPathComponent("shortcuts-custom@\(scale)x.png")) }
        settings.shortcuts.query = ""
        let originalBindings=try Data(contentsOf:settings.shortcuts.fileURL)
        settings.shortcuts.selectedCommandID="go-to-tab-1";settings.shortcuts.basics=false
        settings.shortcuts.query="Go to Tab"
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:684,height:650),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-tab-controls@\(scale)x.png"))}
        settings.shortcuts.query="New Window";settings.shortcuts.beginRecording("new-window")
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:684,height:650),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-recording@\(scale)x.png"))}
        settings.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:"new-tab")
        settings.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:"new-window")
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:684,height:650),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-conflict@\(scale)x.png"))}
        settings.shortcuts.revert();settings.shortcuts.reset("new-tab");settings.shortcuts.query=""
        try originalBindings.write(to:settings.shortcuts.fileURL,options:.atomic)
        for scale in scales {
            try await render(PreviewsSheet(model:settings.general),size:CGSize(width:480,height:320),scale:scale,dark:false,to:output.appendingPathComponent("sheet-previews@\(scale)x.png"))
            settings.profiles.select(settings.model.profiles[1].id)
            try await render(SearchEnginesSheet(model:settings.profiles),size:CGSize(width:520,height:420),scale:scale,dark:false,to:output.appendingPathComponent("sheet-search-engines@\(scale)x.png"))
            try await render(ClearBrowsingDataSheet(model:settings.profiles),size:CGSize(width:460,height:360),scale:scale,dark:false,to:output.appendingPathComponent("sheet-clear-data@\(scale)x.png"))
            await settings.adBlock?.openSelectedProfile()
            try await render(AdBlockSettingsSheet(model:settings.adBlock!),size:CGSize(width:600,height:560),scale:scale,dark:true,to:output.appendingPathComponent("sheet-adblock@\(scale)x.png"))
            try await render(LinkRuleSheet(root:settings,draft:settings.links.drafts[1]),size:CGSize(width:520,height:380),scale:scale,dark:true,to:output.appendingPathComponent("sheet-link-rule@\(scale)x.png"))
            settings.profiles.nameDraft="Example New Profile"
            try await render(ProfileNameSheet(model:settings.profiles,create:true),size:CGSize(width:440,height:330),scale:scale,dark:false,to:output.appendingPathComponent("sheet-profile-create@\(scale)x.png"))
            settings.profiles.nameDraft="Example Work"
            try await render(ProfileNameSheet(model:settings.profiles,create:false),size:CGSize(width:440,height:180),scale:scale,dark:false,to:output.appendingPathComponent("sheet-profile-rename@\(scale)x.png"))
            settings.profiles.proposeArchive(.oneHour)
            try await render(ArchiveScopeSheet(model:settings.profiles),size:CGSize(width:500,height:160),scale:scale,dark:false,to:output.appendingPathComponent("sheet-archive-scope@\(scale)x.png"));settings.profiles.cancelArchive()
        }
        let customEngineID=settings.profiles.profile!.settings.customSearchEngines[0].id
        for scale in scales {
            try await render(SearchEnginesSheet(model:settings.profiles,editingEngineID:customEngineID),size:CGSize(width:520,height:540),scale:scale,dark:false,to:output.appendingPathComponent("sheet-search-engine-edit@\(scale)x.png"))
            var invalid=settings.links.drafts[1];invalid.pattern=""
            try await render(LinkRuleSheet(root:settings,draft:invalid),size:CGSize(width:520,height:380),scale:scale,dark:true,to:output.appendingPathComponent("sheet-link-rule-invalid@\(scale)x.png"))
        }
        let noticeEnvironment=try PreviewEnvironment();defer {noticeEnvironment.close()}
        noticeEnvironment.settings.profiles.presentSuggestNotice()
        for scale in scales {try await render(SuggestNoticeSheet(model:noticeEnvironment.settings.profiles),size:CGSize(width:400,height:180),scale:scale,dark:false,to:output.appendingPathComponent("sheet-suggestion-notice@\(scale)x.png"))}
        settings.profiles.select(settings.model.profiles[0].id)
        let empty=try PreviewEnvironment();defer {empty.close()};empty.downloadFeed.downloads=[]
        for section in [LibrarySection.archive,.downloads,.captures,.history] {
            empty.library.section=section;await empty.library.reload()
            for scale in scales {try await render(LibraryContent(viewModel:empty.library),size:CGSize(width:960,height:640),scale:scale,dark:true,to:output.appendingPathComponent("library-\(section.rawValue)-empty@\(scale)x.png"))}
        }
        let wizardEnvironment = try PreviewEnvironment(); defer { wizardEnvironment.close() }
        let source = wizardEnvironment.root.appendingPathComponent("Example Import")
        try SyntheticData.writeImportFixture(to: source)
        let wizard = ImportWizardViewModel(root: wizardEnvironment.settings, directory: source)
        await wizard.refreshCounts()
        for scale in scales { try await render(ImportWizard(model: wizard), size: CGSize(width: 640, height: 520), scale: scale, dark: false, to: output.appendingPathComponent("import-choose@\(scale)x.png")) }
        wizard.plan.secretsRequested=true;wizard.review()
        for scale in scales {try await render(ImportWizard(model:wizard),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-review@\(scale)x.png"))}
        await wizard.beginImport()
        try require(wizard.step == .consent && wizardEnvironment.actions.importPlansWithConsent == 0 && wizardEnvironment.actions.log.isEmpty, "wizard rendering must stop at consent")
        for scale in scales { try await render(ImportWizard(model: wizard), size: CGSize(width: 640, height: 520), scale: scale, dark: false, to: output.appendingPathComponent("import-consent@\(scale)x.png")) }
        await wizard.skipSecrets()
        try require(wizard.step == .report && wizard.outcome?.errorText == nil && wizardEnvironment.actions.importPlansWithConsent == 0,"count-only wizard report")
        for scale in scales {try await render(ImportWizard(model:wizard),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-report@\(scale)x.png"))}
        wizardEnvironment.actions.canImportPasswordsAndCookies=true
        let readyWizard=ImportWizardViewModel(root:wizardEnvironment.settings,directory:source)
        await readyWizard.refreshCounts();readyWizard.plan.secretsRequested=true;readyWizard.review();await readyWizard.beginImport()
        let importCalls=wizardEnvironment.actions.log.count
        try require(readyWizard.step == .consent && !readyWizard.plan.secretsConsented,"ready-copy render must stop before consent")
        for scale in scales {try await render(ImportWizard(model:readyWizard),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-passwords-ready@\(scale)x.png"))}
        try require(wizardEnvironment.actions.importPlansWithConsent == 0 && wizardEnvironment.actions.log.count == importCalls,"ready-copy rendering invoked import")
        readyWizard.finish();wizardEnvironment.actions.canImportPasswordsAndCookies=false
        for scale in scales {
            for (first,second) in [("links-rules","links-test"),("advanced-adblock","advanced-sleep-data")] {
                try require(try Data(contentsOf:output.appendingPathComponent("\(first)@\(scale)x.png")) != Data(contentsOf:output.appendingPathComponent("\(second)@\(scale)x.png")),"detail targets produced the same viewport")
            }
        }
        // Retain the synthetic caller fixture so dump-keys can independently inspect every store.
        try settings.flush(); _ = try env.diskDefaults()
        let fixture = output.appendingPathComponent("fixture")
        if FileManager.default.fileExists(atPath: fixture.path) {
            guard (try? String(contentsOf: fixture.appendingPathComponent("State/settings-preview.marker"), encoding: .utf8)) == "synthetic-settings-v1" else { throw CheckFailure(description: "existing fixture directory is not owned by settings-preview") }
            try FileManager.default.removeItem(at: fixture)
        }
        try FileManager.default.copyItem(at: env.root, to: fixture)
    } else { throw NSError(domain: "command not implemented", code: 2) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in do { try await run(); exit(0) } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) } }
app.run()

@MainActor func accessibilityLabels(_ root: NSObject) -> [String] {
    var visited = Set<ObjectIdentifier>(), labels: [String] = []
    func visit(_ node: NSObject) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        let label = NSSelectorFromString("accessibilityLabel"), children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: label), let value = node.perform(label)?.takeUnretainedValue() as? String { labels.append(value) }
        if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] { values.forEach(visit) }
        if let view = node as? NSView { view.subviews.forEach(visit) }
    }
    visit(root); return labels
}

@MainActor final class RenderWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}
