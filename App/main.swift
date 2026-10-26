import AppKit
import OpenEngine

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
// Unknown --switches on our command line reach Chromium directly (CEF reads
// argv), so only add what the app itself decides.
var switches: [String] = []
#if DEBUG
  // CEF stores its cookie key in the shared "Chromium Safe Storage" keychain
  // item. Ad-hoc signed dev builds would get a keychain prompt on every
  // rebuild, so dev builds use Chromium's mock keychain.
  switches.append("--use-mock-keychain")
#endif
configuration.additionalSwitches = switches

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
