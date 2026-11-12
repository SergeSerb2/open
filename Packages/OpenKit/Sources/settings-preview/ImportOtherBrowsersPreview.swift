import Foundation
import SwiftUI
import OpenSettings
import OpenImport

/// IMF look frames: Firefox and Safari in the import sheet, light and dark. Synthetic fixtures only
/// (`SyntheticFirefoxFixture`, `SyntheticSafariFixture`) under the preview root.
@MainActor func renderImportOtherBrowsers(output: URL, scales: [Int]) async throws {
    let environment = try PreviewEnvironment(); defer { environment.close() }
    let base = environment.root.appendingPathComponent("Example Import")
    let library = base.appendingPathComponent("Library"), files = base.appendingPathComponent("files")
    _ = try SyntheticFirefoxFixture.write(to: library.appendingPathComponent("Application Support/Firefox"), visits: 200)
    let safari = try SyntheticSafariFixture.write(to: files, historyItems: 40)
    try FileManager.default.copyItem(at: safari.liveDirectory, to: library.appendingPathComponent("Safari"))
    ImportWizardViewModel.browserLibraryOverride = library
    environment.actions.canImportBrowserPasswords = true
    environment.actions.importHandler = { _ in
        ImportOutcome(counts: ["Bookmarks": 6, "History": 160, "Passwords": 3, ImportOutcomeKeys.history: 160])
    }
    var wizard = ImportWizardViewModel(root: environment.settings, startsWithSource: true)
    func frames(_ name: String) async throws {
        for dark in [false, true] { for scale in scales {
            try await render(ImportWizard(model: wizard).buttonStyle(SettingsButtonStyle()), size: CGSize(width: 640, height: 520), scale: scale,
                             dark: dark, to: output.appendingPathComponent("import-\(name)-\(dark ? "dark" : "light")@\(scale)x.png"))
        } }
    }
    func start(_ id: String) async throws {
        wizard = ImportWizardViewModel(root: environment.settings, startsWithSource: true)
        await wizard.loadSources()
        wizard.selectedSourceID = id
        try require(wizard.canContinueFromSource, "\(id) is selectable")
    }

    try await start("firefox")
    try await frames("other-source")
    await wizard.continueFromSource()
    try require(wizard.step == .choose && wizard.readable && wizard.plan.passwords, "Firefox Choose with passwords")
    try await frames("firefox-choose")
    await wizard.selectProfile("syn0002.work")
    wizard.plan.passwords = true
    try require(wizard.needsPrimaryPassword && !wizard.canContinue, "Primary Password field blocks Next")
    try await frames("firefox-primary-password")
    wizard.plan.primaryPassword = "example"
    wizard.review(); await wizard.beginImport()
    try require(wizard.step == .report, "Firefox report")
    try await frames("firefox-report")
    wizard.finish()

    // A running Firefox: another process holds the profile lock, as Firefox does.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = ["-c", "import fcntl,sys,os;f=os.open(sys.argv[1],os.O_RDWR);fcntl.lockf(f,fcntl.LOCK_EX);print('locked',flush=True);sys.stdin.read()",
                        library.appendingPathComponent("Application Support/Firefox/Profiles/syn0001.default-release/.parentlock").path]
    let input = Pipe(), out = Pipe()
    holder.standardInput = input; holder.standardOutput = out
    try holder.run()
    _ = out.fileHandleForReading.availableData
    try await start("firefox")
    await wizard.continueFromSource()
    try require(wizard.step == .access && wizard.accessBlocker == .quitBrowser, "Quit Firefox step")
    try await frames("firefox-quit")
    wizard.finish()
    try input.fileHandleForWriting.close(); holder.waitUntilExit()

    // Safari without Full Disk Access.
    let safariDirectory = library.appendingPathComponent("Safari")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: safariDirectory.path)
    do {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safariDirectory.path) }
        try await start("safari")
        await wizard.continueFromSource()
        try require(wizard.step == .access && wizard.accessBlocker == .fullDiskAccess && wizard.fullDiskAccessRequests == 1, "Full Disk Access step")
        try await frames("safari-access")
        wizard.finish()
    }

    try await start("safari")
    await wizard.continueFromSource()
    try require(wizard.step == .choose && wizard.readable, "Safari Choose (live files)")
    try await frames("safari-choose")
    await wizard.useSafariExport(safari.exportZip)
    await wizard.usePasswordsFile(safari.passwordsCSV)
    try require(wizard.plan.safariFiles.exportArchive != nil && wizard.plan.passwords, "Safari export + passwords")
    try await frames("safari-export")
    wizard.finish()
}
