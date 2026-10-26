import AppKit
import OpenEngine
import Security

// Chromium's message pump needs the CefAppProtocol NSApplication subclass,
// created before anything else touches AppKit.
let app = OEApplication.shared as! OEApplication
LaunchTiming.shared.mark("main")
// Open restores windows from its own snapshot (OpenStore), never through
// AppKit state restoration, which would also show a "reopen windows?" alert
// after a crash.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
let appDelegate = AppDelegate()
app.delegate = appDelegate
// Reserved app shortcuts beat the page (Cmd-T, Cmd-W, Cmd-L, ...).
app.keyEquivalentHandler = { event in MainMenu.performReservedShortcut(event) }

let options = LaunchOptions(arguments: CommandLine.arguments)
appDelegate.options = options
// The model comes first: the window can be built from it at once, and the
// engine needs the default profile's folder (docs/plans/profiles.md §6.2).
let directories = appDelegate.prepareData()
// Finish AppKit launch and draw the snapshot-backed sidebar before loading
// Chromium. The same sidebar survives engine readiness; no page exists yet.
app.setActivationPolicy(.regular)
app.finishLaunching()
appDelegate.drawWindowsBeforeEngine()

// CEF owns the main message loop after initialization. Give AppKit one
// runloop turn first so the window transaction reaches the window server.
var firstWindowTurnFinished = false
RunLoop.main.perform {
  MainActor.assumeIsolated {
    firstWindowTurnFinished = true
    CFRunLoopStop(CFRunLoopGetMain())
  }
}
while !firstWindowTurnFinished { CFRunLoopRun() }

// Initialize outside the temporary AppKit runloop. Chromium installs native
// runloop observers during start; those must first run in CefRunMessageLoop.
let configuration = OEEngineConfiguration()
// root_cache_path = <root>/Profiles. The default profile's engine data is
// then Profiles/Default/ (CEF's fixed name for the global context); other
// profiles use Profiles/<dir>/Engine/ (BrowserWindowController.context(for:)).
configuration.userDataDirectory = directories.root.appendingPathComponent("Profiles", isDirectory: true)
configuration.logFile = directories.root.appendingPathComponent("State/engine.log")
configuration.defaultRuntimeStyle = options.defaultStyle
configuration.remoteDebuggingPort = options.remoteDebuggingPort
configuration.verboseLogging = options.verboseLogging
configuration.userAgentProduct = "Open/0.1"
// Ad-hoc signed builds (no Team ID) get a new signature on every build, so
// macOS would ask for keychain access each time; they use Chromium's mock key.
// Developer ID builds use the "Open Safe Storage" keychain item.
configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier

OEEngine.shared.delegate = appDelegate
LaunchTiming.shared.mark("engineStart")
#if OPEN_AUTOMATION
if let data = try? JSONSerialization.data(withJSONObject: LaunchTiming.shared.report, options: [.sortedKeys]) {
  FileHandle.standardError.write(Data("Open: pre-engine timing ".utf8) + data + Data("\n".utf8))
}
#endif
do {
  try OEEngine.shared.start(configuration: configuration)
} catch {
  FileHandle.standardError.write(Data("Open: engine failed to start: \(error)\n".utf8))
  FileHandle.standardError.write(Data("Open: launch timing: \(LaunchTiming.shared.report)\n".utf8))
  exit(1)
}
LaunchTiming.shared.mark("engineStarted")

OEEngine.shared.runMessageLoop()
appDelegate.saveState()
OEEngine.shared.shutdown()
exit(0)

/// The running app's code signature.
enum CodeSignature {
  static var hasTeamIdentifier: Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let dict = info as? [String: Any]
    else { return false }
    return dict[kSecCodeInfoTeamIdentifier as String] != nil
  }
}
