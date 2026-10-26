import AppKit
import OpenEngine
import Security

// Chromium's message pump needs the CefAppProtocol NSApplication subclass,
// created before anything else touches AppKit.
LaunchTiming.shared.mark("main")
// Open restores windows from its own snapshot (OpenStore), never through
// AppKit state restoration, which would also show a "reopen windows?" alert
// after a crash.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
let app = OEApplication.shared as! OEApplication
let appDelegate = AppDelegate()
app.delegate = appDelegate
// Reserved app shortcuts beat the page (Cmd-T, Cmd-W, Cmd-L, ...).
app.keyEquivalentHandler = { event in MainMenu.performReservedShortcut(event) }

let options = LaunchOptions(arguments: CommandLine.arguments)
let configuration = OEEngineConfiguration()
configuration.userDataDirectory = options.userDataDirectory
configuration.defaultRuntimeStyle = options.defaultStyle
configuration.remoteDebuggingPort = options.remoteDebuggingPort
configuration.verboseLogging = options.verboseLogging
configuration.userAgentProduct = "Open/0.1"
// Ad-hoc signed builds (no Team ID) get a new signature on every build, so
// macOS would ask for keychain access each time; they use Chromium's mock key.
// Developer ID builds use the "Open Safe Storage" keychain item.
configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier

OEEngine.shared.delegate = appDelegate
appDelegate.options = options
LaunchTiming.shared.mark("engineStart")
do {
  try OEEngine.shared.start(configuration: configuration)
} catch {
  FileHandle.standardError.write(Data("Open: engine failed to start: \(error)\n".utf8))
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
