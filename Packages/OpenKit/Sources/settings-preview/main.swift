import AppKit
import SwiftUI
import OpenSettings
import OpenModel
import OpenCommands
import OpenStore
import OpenImport
import CryptoKit

@MainActor final class PreviewActions: SettingsActions {
    var log: [String] = []
    var extensionConflicts: [ExtensionShortcutConflict] = []
    var openedURLs: [(URL, ProfileID)] = []
    func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict] { extensionConflicts }
    static let sampleExtensionConflicts: [ExtensionShortcutConflict] = [
        .init(extensionName: "Action Probe", commandDescription: "Open action", shortcut: .init(key: "y", modifiers: [.shift, .command]), openCommandID: "copy-url"),
        .init(extensionName: "Search Probe", commandDescription: "Search", shortcut: .cmd("t"), openCommandID: "new-tab")
    ]
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
    func deleteProfileData(profileID: ProfileID, dataDirectoryName: String) async -> String? { record("deleteProfileData \(profileID)"); return nil }
    func chooseProfileIcon(profileID: ProfileID, anchor: NSView) { record("chooseProfileIcon \(profileID)") }
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
    func openURL(_ url: URL, profileID: ProfileID) { openedURLs.append((url, profileID)); record("openURL host=\(url.host() ?? "") \(profileID)") }
    func openHelp(topic: String) { record("openHelp \(topic)") }
    func copyText(_ text: String) { record("copyText") }
    func openLibrary() { record("openLibrary") }
    var spaceManagerAvailable = true
    private(set) var spaceManagerMakeCount = 0
    func openEssentialShortcuts() { record("openEssentialShortcuts") }
    func makeSpaceManagerView() -> NSView? {
        spaceManagerMakeCount += 1
        record("makeSpaceManagerView")
        guard spaceManagerAvailable else { return nil }
        let view = NSView()
        let label = NSTextField(labelWithString: "Space Manager preview")
        label.setAccessibilityElement(true); label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("Space Manager preview")
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        return view
    }
}

@discardableResult @MainActor func render<V: View>(_ view: V, size: CGSize, scale: Int, dark: Bool, active:Bool=true, to url: URL, validatePreviewControls: Bool = false, enhanceAccessibility: Bool = false) async throws -> [String] {
    let previousAppearance=NSApp.appearance
    let appearance=NSAppearance(named:dark ? .darkAqua:.aqua)!
    NSApp.appearance=appearance
    defer {NSApp.appearance=previousAppearance}
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState,active ? .key:.inactive).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance=appearance
    host.frame = CGRect(origin: .zero, size: size)
    let window = RenderWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.scale = CGFloat(scale); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
    defer { window.contentView = nil; window.close() }
    // SwiftUI lazily vends AX nodes after this process enables its AX interface.
    // Scope that state to the real sheet render; never change system AX settings.
    let axRead = NSSelectorFromString("accessibilityAttributeValue:")
    let axWrite = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    let enhancedAX = "AXEnhancedUserInterface"
    let needsAX = validatePreviewControls || enhanceAccessibility
    let previousAX = needsAX && NSApp.responds(to: axRead) ? NSApp.perform(axRead, with: enhancedAX)?.takeUnretainedValue() : nil
    if needsAX, NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: NSNumber(value: true), with: enhancedAX) }
    defer { if needsAX, NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: previousAX ?? NSNumber(value: false), with: enhancedAX) } }
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
    if validatePreviewControls { try checkPreviewsControls(host) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try data.write(to: url); print("PNG \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(data.count) bytes sha256=\(hash)")
    return labels
}
@MainActor func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") { print("settings-preview render --out DIR [--scale 1|2|both] [--first-run-only]\nsettings-preview check [--only NAME]\nsettings-preview dump-keys --root DIR\nsettings-preview probe --arc-dir DIR"); return }
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0+1] : nil } }
    if args[0] == "probe" {
        guard let directory=value("--arc-dir") else {throw CheckFailure(description:"--arc-dir is required")}
        let start=DispatchTime.now().uptimeNanoseconds
        let result=await ArcProbe(arcDirectory:URL(fileURLWithPath:directory)).run()
        struct Receipt:Codable {let probe:ArcProbeResult;let seconds:Double}
        let data=try JSONEncoder().encode(Receipt(probe:result,seconds:Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000_000))
        print(String(decoding:data,as:UTF8.self));return
    }
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
        if args.contains("--first-run-only") {try await renderFirstRunScreens(output:output,scales:scales);return}
        if args.contains("--profiles-shell-only") {try await renderProfilesShell(output:output,scales:scales);return}
        settings.selectedPane = .shortcuts
        env.actions.extensionConflicts = PreviewActions.sampleExtensionConflicts
        for dark in [false,true] { for scale in scales {
            try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: dark,
                             to: output.appendingPathComponent("shortcuts-extension-conflicts-\(dark ? "dark" : "light")@\(scale)x.png"))
        } }
        env.actions.extensionConflicts = []
        if args.contains("--extension-shortcuts-only") { return }
        for pane in PaneID.allCases {
            settings.selectedPane = pane
            for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: true, to: output.appendingPathComponent("\(pane == .appIcon ? "app-icon" : pane.rawValue)@\(scale)x.png")) }
        }
        for section in SettingsSection.allCases {
            settings.navigate(to: section)
            for dark in [false, true] { for scale in scales {
                try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: dark,
                                 to: output.appendingPathComponent("section-\(section.rawValue)-\(dark ? "dark" : "light")@\(scale)x.png"))
            } }
        }
        try await renderProfilesShell(output:output,scales:scales)
        for section in LibrarySection.allCases {
            library.section = section
            for scale in scales { try await render(LibraryContent(viewModel: library), size: CGSize(width: 960, height: 640), scale: scale, dark: true, to: output.appendingPathComponent("library-\(section.rawValue)@\(scale)x.png")) }
        }
        for pane in [PaneID.general, .profiles] { settings.selectedPane = pane; for dark in [false,true] { for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: dark, to: output.appendingPathComponent("\(pane.rawValue)-\(dark ? "dark" : "light")@\(scale)x.png")) } } }
        settings.links.testURLString="example.com/x";settings.links.runTest()
        // Tall panes have additional viewport captures, using the same view and scroll entry point.
        for (pane, target, name) in [(PaneID.links, "links-rules", "links-rules"), (.links, "links-test", "links-test"), (.advanced, "advanced-adblock", "advanced-adblock"), (.advanced, "advanced-sleep", "advanced-sleep-data")] {
            settings.selectedPane = pane
            switch target {
            case "advanced-adblock": settings.navigate(to: .adBlocking)
            case "advanced-sleep": settings.navigate(to: .tabsArchive, row: "sleep")
            case "links-rules": settings.navigate(to: .links, row: "rules")
            default: settings.navigate(to: .links, row: "test")
            }
            for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: true, to: output.appendingPathComponent("\(name)@\(scale)x.png")) }
        }
        settings.scrollTarget = nil; settings.selectedPane = .shortcuts; settings.shortcuts.query = "New Tab"
        for scale in scales { try await render(SettingsContent(viewModel: settings), size: CGSize(width: 960, height: 660), scale: scale, dark: false, to: output.appendingPathComponent("shortcuts-custom@\(scale)x.png")) }
        settings.shortcuts.query = ""
        let originalBindings=try Data(contentsOf:settings.shortcuts.fileURL)
        settings.shortcuts.selectedCommandID="go-to-tab-1"
        settings.shortcuts.query="Go to Tab"
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:960,height:660),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-tab-controls@\(scale)x.png"))}
        settings.shortcuts.query="New Window";settings.shortcuts.beginRecording("new-window")
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:960,height:660),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-recording@\(scale)x.png"))}
        settings.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:"new-tab")
        settings.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:"new-window")
        for scale in scales {try await render(SettingsContent(viewModel:settings),size:CGSize(width:960,height:660),scale:scale,dark:false,to:output.appendingPathComponent("shortcuts-conflict@\(scale)x.png"))}
        settings.shortcuts.revert();settings.shortcuts.reset("new-tab");settings.shortcuts.query=""
        // Essential Keyboard Shortcuts window content (commandbar-completion §4.5), light and dark, and with a custom key.
        let eduSize = NSHostingView(rootView: EssentialShortcutsView(store: settings.shortcuts.store)).fittingSize
        for dark in [false, true] { for scale in scales {
            try await render(EssentialShortcutsView(store: settings.shortcuts.store), size: eduSize, scale: scale, dark: dark, to: output.appendingPathComponent("essential-shortcuts-\(dark ? "dark" : "light")@\(scale)x.png"))
        } }
        var custom = settings.shortcuts.store
        custom.setOverride(KeyBindingOverride(shortcuts: [.init(key: "y", modifiers: [.control, .option, .command])], priority: nil), for: "new-tab")
        custom.setOverride(KeyBindingOverride(shortcuts: [], priority: nil), for: "copy-url")
        for scale in scales { try await render(EssentialShortcutsView(store: custom), size: eduSize, scale: scale, dark: false, to: output.appendingPathComponent("essential-shortcuts-custom-key@\(scale)x.png")) }
        try originalBindings.write(to:settings.shortcuts.fileURL,options:.atomic)
        for scale in scales {
            try await render(PreviewsSheet(model:settings.general).buttonStyle(SettingsButtonStyle()),size:CGSize(width:480,height:320),scale:scale,dark:false,to:output.appendingPathComponent("sheet-previews@\(scale)x.png"),validatePreviewControls:true)
            settings.profiles.select(settings.model.profiles[1].id)
            try await render(SearchEnginesSheet(model:settings.profiles).buttonStyle(SettingsButtonStyle()),size:CGSize(width:520,height:420),scale:scale,dark:false,to:output.appendingPathComponent("sheet-search-engines@\(scale)x.png"))
            try await render(ClearBrowsingDataSheet(model:settings.profiles).buttonStyle(SettingsButtonStyle()),size:CGSize(width:460,height:360),scale:scale,dark:false,to:output.appendingPathComponent("sheet-clear-data@\(scale)x.png"))
            await settings.adBlock?.openSelectedProfile()
            try await render(AdBlockSettingsSheet(model:settings.adBlock!).buttonStyle(SettingsButtonStyle()),size:CGSize(width:600,height:560),scale:scale,dark:true,to:output.appendingPathComponent("sheet-adblock@\(scale)x.png"))
            try await render(LinkRuleSheet(root:settings,draft:settings.links.drafts[1]).buttonStyle(SettingsButtonStyle()),size:CGSize(width:520,height:380),scale:scale,dark:true,to:output.appendingPathComponent("sheet-link-rule@\(scale)x.png"))
            var profileDraft=settings.links.drafts[1]
            profileDraft.destination = .littleOpen(profile:settings.model.profiles[1].id)
            try await render(LinkRuleSheet(root:settings,draft:profileDraft).buttonStyle(SettingsButtonStyle()),size:CGSize(width:520,height:380),scale:scale,dark:true,to:output.appendingPathComponent("sheet-link-rule-profile-work@\(scale)x.png"))
            settings.profiles.nameDraft="Example New Profile"
            try await render(ProfileNameSheet(model:settings.profiles,create:true).buttonStyle(SettingsButtonStyle()),size:CGSize(width:440,height:330),scale:scale,dark:false,to:output.appendingPathComponent("sheet-profile-create@\(scale)x.png"))
            settings.profiles.nameDraft="Example Work"
            try await render(ProfileNameSheet(model:settings.profiles,create:false).buttonStyle(SettingsButtonStyle()),size:CGSize(width:440,height:180),scale:scale,dark:false,to:output.appendingPathComponent("sheet-profile-rename@\(scale)x.png"))
            settings.profiles.proposeArchive(.oneHour)
            try await render(ArchiveScopeSheet(model:settings.profiles).buttonStyle(SettingsButtonStyle()),size:CGSize(width:500,height:160),scale:scale,dark:false,to:output.appendingPathComponent("sheet-archive-scope@\(scale)x.png"));settings.profiles.cancelArchive()
        }
        let customEngineID=settings.profiles.profile!.settings.customSearchEngines[0].id
        for scale in scales {
            try await render(SearchEnginesSheet(model:settings.profiles,editingEngineID:customEngineID).buttonStyle(SettingsButtonStyle()),size:CGSize(width:520,height:540),scale:scale,dark:false,to:output.appendingPathComponent("sheet-search-engine-edit@\(scale)x.png"))
            var invalid=settings.links.drafts[1];invalid.pattern=""
            try await render(LinkRuleSheet(root:settings,draft:invalid).buttonStyle(SettingsButtonStyle()),size:CGSize(width:520,height:380),scale:scale,dark:true,to:output.appendingPathComponent("sheet-link-rule-invalid@\(scale)x.png"))
        }
        let noticeEnvironment=try PreviewEnvironment();defer {noticeEnvironment.close()}
        noticeEnvironment.settings.profiles.presentSuggestNotice()
        for scale in scales {try await render(SuggestNoticeSheet(model:noticeEnvironment.settings.profiles).buttonStyle(SettingsButtonStyle()),size:CGSize(width:400,height:180),scale:scale,dark:false,to:output.appendingPathComponent("sheet-suggestion-notice@\(scale)x.png"))}
        settings.profiles.select(settings.model.profiles[0].id)
        let empty=try PreviewEnvironment();defer {empty.close()};empty.downloadFeed.downloads=[]
        for section in [LibrarySection.archive,.downloads,.captures,.boosts,.history] {
            empty.library.section=section;await empty.library.reload()
            for scale in scales {try await render(LibraryContent(viewModel:empty.library),size:CGSize(width:960,height:640),scale:scale,dark:true,to:output.appendingPathComponent("library-\(section.rawValue)-empty@\(scale)x.png"))}
        }
        let wizardEnvironment = try PreviewEnvironment(); defer { wizardEnvironment.close() }
        let source = wizardEnvironment.root.appendingPathComponent("Example Import")
        try SyntheticData.writeImportFixture(to: source)
        let wizard = ImportWizardViewModel(root: wizardEnvironment.settings, directory: source)
        await wizard.refreshCounts()
        for scale in scales { try await render(ImportWizard(model: wizard).buttonStyle(SettingsButtonStyle()), size: CGSize(width: 640, height: 520), scale: scale, dark: false, to: output.appendingPathComponent("import-choose@\(scale)x.png")) }
        wizard.plan.secretsRequested=false;wizard.review()
        for scale in scales {try await render(ImportWizard(model:wizard).buttonStyle(SettingsButtonStyle()),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-review@\(scale)x.png"))}
        wizard.step = .consent // Capability-OFF copy reference; the disabled checkbox cannot navigate here.
        try require(wizard.step == .consent && wizardEnvironment.actions.importPlansWithConsent == 0 && wizardEnvironment.actions.log.isEmpty, "wizard rendering must stop at consent")
        for scale in scales { try await render(ImportWizard(model: wizard).buttonStyle(SettingsButtonStyle()), size: CGSize(width: 640, height: 520), scale: scale, dark: false, to: output.appendingPathComponent("import-consent@\(scale)x.png")) }
        await wizard.skipSecrets()
        try require(wizard.step == .report && wizard.outcome?.errorText == nil && wizardEnvironment.actions.importPlansWithConsent == 0,"count-only wizard report")
        for scale in scales {try await render(ImportWizard(model:wizard).buttonStyle(SettingsButtonStyle()),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-report@\(scale)x.png"))}
        wizardEnvironment.actions.canImportPasswordsAndCookies=true
        let readyWizard=ImportWizardViewModel(root:wizardEnvironment.settings,directory:source)
        await readyWizard.refreshCounts();readyWizard.plan.secretsRequested=true;readyWizard.review();await readyWizard.beginImport()
        let importCalls=wizardEnvironment.actions.log.count
        try require(readyWizard.step == .consent && !readyWizard.plan.secretsConsented,"ready-copy render must stop before consent")
        for scale in scales {try await render(ImportWizard(model:readyWizard).buttonStyle(SettingsButtonStyle()),size:CGSize(width:640,height:520),scale:scale,dark:false,to:output.appendingPathComponent("import-passwords-ready@\(scale)x.png"))}
        try require(wizardEnvironment.actions.importPlansWithConsent == 0 && wizardEnvironment.actions.log.count == importCalls,"ready-copy rendering invoked import")
        readyWizard.finish();wizardEnvironment.actions.canImportPasswordsAndCookies=false
        for scale in scales {
            for (first,second) in [("links-rules","links-test"),("advanced-adblock","advanced-sleep-data")] {
                try require(try Data(contentsOf:output.appendingPathComponent("\(first)@\(scale)x.png")) != Data(contentsOf:output.appendingPathComponent("\(second)@\(scale)x.png")),"detail targets produced the same viewport")
            }
        }
        try await renderFirstRunScreens(output:output,scales:scales)
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

/// Hosts `view` offscreen with SwiftUI's accessibility nodes on (process-scoped, as `render` does), then
/// calls `body` with the hosting view.
@MainActor func withAccessibleHost<V: View>(_ view: V, size: CGSize, _ body: @MainActor (NSView) throws -> Void) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = RenderWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    let axRead = NSSelectorFromString("accessibilityAttributeValue:"), axWrite = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    let enhancedAX = "AXEnhancedUserInterface"
    let previousAX = NSApp.responds(to: axRead) ? NSApp.perform(axRead, with: enhancedAX)?.takeUnretainedValue() : nil
    if NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: NSNumber(value: true), with: enhancedAX) }
    defer { if NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: previousAX ?? NSNumber(value: false), with: enhancedAX) } }
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    try body(host)
}

@MainActor private func renderProfilesShell(output: URL, scales: [Int]) async throws {
    // Deletion renders mutate Profiles; keep the exported dump-keys fixture intact.
    let environment = try PreviewEnvironment(); defer { environment.close() }
    let settings = environment.settings
    settings.set(true,for:"open.general.searchSuggestNoticeDismissed")
    settings.selectedPane = .profiles
    if settings.model.profiles.count > 1 {
        settings.profiles.setIcon(.symbol("briefcase.fill"),profileID:settings.model.profiles[1].id)
    }
    for scale in scales {
        try await render(SettingsContent(viewModel:settings),size:CGSize(width:960,height:660),scale:scale,dark:true,to:output.appendingPathComponent("profile-icons@\(scale)x.png"))
    }
    _ = settings.profiles.create(name:"Example Unused Profile")
    settings.profiles.beginDelete()
    for scale in scales {
        try await render(ProfileDeleteSheet(model:settings.profiles),size:CGSize(width:508,height:310),scale:scale,dark:true,to:output.appendingPathComponent("profile-delete-disabled@\(scale)x.png"))
    }
    settings.profiles.deleteConfirmation=settings.profiles.deleteToken
    for scale in scales {
        try await render(ProfileDeleteSheet(model:settings.profiles),size:CGSize(width:508,height:310),scale:scale,dark:true,to:output.appendingPathComponent("profile-delete-enabled@\(scale)x.png"))
    }
    settings.profiles.confirmsDelete=false;settings.profiles.beginDelete(unused:true)
    for scale in scales {
        try await render(ProfileDeleteSheet(model:settings.profiles),size:CGSize(width:508,height:360),scale:scale,dark:true,to:output.appendingPathComponent("profile-delete-unused@\(scale)x.png"))
    }
    settings.profiles.confirmsUnused=false
}

/// Presses the first accessibility element labeled `label` (the real AX press path). False when absent.
@MainActor func pressAccessibilityElement(_ root: NSObject, label wanted: String) -> Bool {
    var visited = Set<ObjectIdentifier>()
    func visit(_ node: NSObject) -> Bool {
        guard visited.insert(ObjectIdentifier(node)).inserted, visited.count < 4096 else { return false }
        let label = NSSelectorFromString("accessibilityLabel"), press = NSSelectorFromString("accessibilityPerformPress")
        if node.responds(to: label), node.perform(label)?.takeUnretainedValue() as? String == wanted, node.responds(to: press) {
            _ = node.perform(press); return true
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] { for c in values where visit(c) { return true } }
        if let view = node as? NSView { for c in view.subviews where visit(c) { return true } }
        return false
    }
    return visit(root)
}

@MainActor func accessibilityLabels(_ root: NSObject) -> [String] {
    var visited = Set<ObjectIdentifier>(), labels: [String] = []
    func visit(_ node: NSObject) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        let children = NSSelectorFromString("accessibilityChildren")
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String { labels.append(value) }
        }
        if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] { values.forEach(visit) }
        if let view = node as? NSView { view.subviews.forEach(visit) }
    }
    visit(root); return labels
}

/// Inspect the real rendered sheet, including static-text values and native popup roles.
@MainActor private func checkPreviewsControls(_ root: NSObject) throws {
    var visited = Set<ObjectIdentifier>(), text = Set<String>(), popups = 0
    func visit(_ node: NSObject) throws {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        try require(visited.count <= 4096, "Previews accessibility tree exceeds 4096 nodes")
        for name in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String {
                text.insert(value)
            }
        }
        let role = NSSelectorFromString("accessibilityRole")
        if node.responds(to: role), let value = node.perform(role)?.takeUnretainedValue() as? String,
           value == NSAccessibility.Role.popUpButton.rawValue { popups += 1 }
        let children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
            for child in values { try visit(child) }
        }
        if let view = node as? NSView { for child in view.subviews { try visit(child) } }
    }
    try visit(root)
    let expected = ["Show Open Previews:", "Folders", "Pinned tabs and Favorites", "Done"]
    try require(expected.allSatisfy(text.contains), "Previews sheet is missing controls (\(visited.count) AX/view nodes): \(text.sorted())")
    try require(!text.contains("Delay") && popups == 0, "Previews sheet has unexpected controls: popups=\(popups), labels=\(text.sorted())")
    print("PREVIEWS-CONTROLS delay=absent popups=\(popups) expected-labels=present")
}

@MainActor final class RenderWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}

/// Deliberate preview-only action boundary. It never calls Keychain or a browser service.
@MainActor final class PreviewFirstRunActions:FirstRunActions {
    var canImportPasswordsAndCookies=false
    var plans:[ImportPlan]=[]
    var events:[String]=[]
    var simulatedKeychainRequests=0
    var nextOutcome=ImportOutcome()
    var holdImport=false
    var pending:CheckedContinuation<Void,Never>?
    var defaultBrowser=false
    var declineDefault=false
    var defaultError:String?
    func runImport(plan:ImportPlan) async -> ImportOutcome {
        plans.append(plan)
        let line="runImport spaces=\(plan.spaces) archive=\(plan.archive) history=\(plan.history) secrets=\(plan.secretsConsented)"
        events.append(line);print("ACTION \(line)")
        if plan.secretsConsented {simulatedKeychainRequests += 1}
        if holdImport {await withCheckedContinuation {pending=$0}}
        var result=nextOutcome
        if !plan.spaces {for key in [ImportOutcomeKeys.spaces,ImportOutcomeKeys.tabs,"Spaces","Pinned and Today tabs","Imported tabs","Favorites","Folders","Search settings"] {result.counts[key]=0}}
        if !plan.archive {result.counts["Archive"]=0;result.counts[ImportOutcomeKeys.archive]=0}
        if !plan.history {result.counts["History"]=0;result.counts[ImportOutcomeKeys.history]=0}
        result.counts["Passwords and cookies"]=0
        return result
    }
    func releaseImport() {holdImport=false;let continuation=pending;pending=nil;continuation?.resume()}
    func isDefaultBrowser()->Bool {defaultBrowser}
    func setAsDefaultBrowser()->String? {events.append("setAsDefaultBrowser");print("ACTION setAsDefaultBrowser");if defaultError == nil && !declineDefault {defaultBrowser=true};return defaultError}
    func finishFirstRun(imported:Bool) {let line="finishFirstRun imported=\(imported)";events.append(line);print("ACTION \(line)")}
}

@MainActor func firstRunPreview(_ env:PreviewEnvironment) async throws -> (FirstRunViewModel,PreviewFirstRunActions) {
    let directory=env.root.appendingPathComponent("Example Import")
    try SyntheticData.writeProbeFixture(to:directory)
    let actions=PreviewFirstRunActions()
    let model=FirstRunViewModel(settings:env.settings,actions:actions,directory:directory)
    await model.refreshProbe()
    let parsed=try await Task.detached(priority:.utility) {try ArcImporter(arcDirectory:directory).readSidebar()}.value
    let imported=try ArcImporter(arcDirectory:directory).importAll(sidebar:parsed)
    let r=imported.report
    // Canned preview action, derived from this small synthetic fixture's actual import report.
    actions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.spaces:r.spaces,"Pinned and Today tabs":r.pinnedTabs+r.todayTabs,"Favorites":r.favorites,"Folders":r.folders,"Archive":imported.archiveRecords.count,"History":model.probe?.historyVisits ?? 0,"Search settings":r.profiles,"Passwords and cookies":0,ImportOutcomeKeys.tabs:r.importedTabNodes,"Skipped easels":r.skippedEasels+r.archiveSkippedEasels,"Skipped notes":r.skippedNotes+r.archiveSkippedNotes])
    return (model,actions)
}

@MainActor func renderFirstRunScreens(output:URL,scales:[Int]) async throws {
    let env=try PreviewEnvironment();defer {env.close()}
    let (base,baseActions)=try await firstRunPreview(env)
    let good=base.probe
    func capture(_ model:FirstRunViewModel,_ name:String,active:Bool=true) async throws {
        for dark in [true,false] {for scale in scales {
            let suffix=dark ? "":"-light"
            try await render(FirstRunView(model:model,startsProbe:false),size:FirstRunWindow.size,scale:scale,dark:dark,active:active,to:output.appendingPathComponent("first-run-\(name)\(suffix)@\(scale)x.png"))
        }}
    }
    func fresh(_ actions:PreviewFirstRunActions=PreviewFirstRunActions())->FirstRunViewModel {
        let model=FirstRunViewModel(settings:env.settings,actions:actions,directory:base.wizard.plan.directory)
        model.probe=good;return model
    }
    try await capture(base,"welcome")
    try await capture(base,"welcome-inactive",active:false)
    base.showImport();try await capture(base,"import")
    // OFF reference is intentionally unreachable. Verify the disabled row separately in check.
    base.includeSecrets=true;base.step = .secretsConsent
    try await capture(base,"secrets")
    baseActions.canImportPasswordsAndCookies=true;base.showImport();await base.continueImport()
    try require(base.step == .secretsConsent && baseActions.plans.isEmpty,"first-run adapter gate did not stop import")
    try await capture(base,"secrets-on")
    base.step = .importChoices;try await capture(base,"import-capability-on");base.step = .secretsConsent
    baseActions.holdImport=true
    let importing=Task {await base.skipPasswords()}
    while baseActions.pending == nil {await Task.yield()}
    try await capture(base,"progress")
    base.phaseText="Importing your history…";base.progress=0.42;base.browserHasLanded=true
    try await capture(base,"progress-history-landed")
    baseActions.releaseImport();await importing.value
    try require(base.step == .report,"first-run report missing")
    try await capture(base,"report")
    base.enterDefaultBrowser();try await capture(base,"default-browser")

    let m=fresh();m.probe=nil;try await capture(m,"welcome-counting")
    var none=ArcProbeResult();none.sidebarFound=false;m.probe=none;try await capture(m,"welcome-nodata")
    m.probe=good;m.reportSaveFailure(imported:false);try await capture(m,"welcome-saveerror")
    m.showImport();m.arcIsRunning=true;try await capture(m,"import-arcrunning")
    m.arcIsRunning=false;m.probe=nil;try await capture(m,"import-counting")
    m.probe=none;try await capture(m,"import-nodata")
    var parse=good!;parse.spaces=nil;parse.sidebarItems=nil;m.probe=parse
    try await capture(m,"import-parsehint")
    m.arcIsRunning=true;try await capture(m,"import-parsehint-running")
    var partial=good!;partial.historyPartial=true;partial.savedItemsPartial=true;m.probe=partial;m.arcIsRunning=false
    try await capture(m,"import-partial")

    let worstActions=PreviewFirstRunActions();worstActions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.spaces:120,ImportOutcomeKeys.tabs:12000,"Pinned and Today tabs":11000,"Favorites":1000,"Folders":240,"Search settings":30,"Skipped easels":2,"Skipped notes":1,"Skipped unknown":4,"Duplicates":500],errorText:"Your Spaces and tabs are in. 120 history visits could not be read. You can import history later from Settings.",failures:["History":"Could not read the history database.","Archive":"3 items could not be stored."])
    let worst=fresh(worstActions);worst.showImport();worst.includeHistory=true;await worst.continueImport()
    try await capture(worst,"report-worst")
    worst.reportSaveFailure(imported:true);try await capture(worst,"report-saveerror")
    let failedActions=PreviewFirstRunActions();failedActions.nextOutcome=ImportOutcome(errorText:"Open could not read your Arc data.")
    let failed=fresh(failedActions);failed.showImport();await failed.continueImport();try await capture(failed,"failed")
    let declinedActions=PreviewFirstRunActions();declinedActions.declineDefault=true
    let declined=fresh(declinedActions);declined.enterDefaultBrowser();declined.makeDefault();try await capture(declined,"default-declined")
    let errorActions=PreviewFirstRunActions();errorActions.defaultError="synthetic failure"
    let error=fresh(errorActions);error.enterDefaultBrowser();error.makeDefault();try await capture(error,"default-error")
    let alreadyActions=PreviewFirstRunActions();alreadyActions.defaultBrowser=true
    let already=fresh(alreadyActions);already.enterDefaultBrowser();try await capture(already,"default-already")
    let singularActions=PreviewFirstRunActions()
    singularActions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.spaces:1,ImportOutcomeKeys.tabs:1,"Pinned and Today tabs":1,"Archive":1,"History":1,"Search settings":1,"Skipped easels":1,"Duplicates":1])
    let singular=fresh(singularActions);var one=good!;one.spaces=1;one.sidebarItems=1;one.archiveItems=1;one.historyVisits=1;one.savedItems=1;singular.probe=one
    try await capture(singular,"welcome-singular")
    singular.showImport();try await capture(singular,"import-singular")
    singular.step = .secretsConsent;try await capture(singular,"secrets-singular")
    singular.showImport();singular.includeHistory=true;await singular.continueImport();try await capture(singular,"report-singular")
    let largeActions=PreviewFirstRunActions();largeActions.canImportPasswordsAndCookies=true
    let large=fresh(largeActions);var many=good!;many.spaces=1234;many.sidebarItems=12000;many.archiveItems=10000;many.historyVisits=184203;many.savedItems=100001;many.historyPartial=true;many.savedItemsPartial=true;large.probe=many
    try await capture(large,"welcome-large")
    large.showImport();try await capture(large,"import-large")
    largeActions.canImportPasswordsAndCookies=false;large.step = .secretsConsent;try await capture(large,"secrets-large")
    try require(baseActions.plans.count == 1 && baseActions.plans.allSatisfy{!$0.secretsConsented} && baseActions.simulatedKeychainRequests == 0,"preview crossed the adapter consent gate")
    print("GATE first-run consent-bearing-plans=0 simulated-keychain-requests=0 (preview adapter only)")
}
