import AppKit
import OpenEngine

// Chromium's message pump needs the CefAppProtocol NSApplication subclass,
// created before anything else touches AppKit.
LaunchTiming.shared.mark("main")
let app = EngineApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate

let options = LaunchOptions(arguments: CommandLine.arguments)
let configuration = EngineConfiguration()
configuration.userDataDirectory = options.userDataDirectory
configuration.defaultRuntimeStyle = options.defaultStyle
configuration.remoteDebuggingPort = options.remoteDebuggingPort
configuration.verboseLogging = options.verboseLogging
#if DEBUG
  // CEF stores its cookie key under the shared "Chromium Safe Storage"
  // keychain item. Ad-hoc signed dev builds would trigger a keychain access
  // prompt on every rebuild, so dev builds use Chromium's mock keychain.
  configuration.additionalSwitches = ["--use-mock-keychain"]
#endif

Engine.shared.delegate = appDelegate
appDelegate.options = options
LaunchTiming.shared.mark("engineStart")
do {
  try Engine.shared.start(configuration: configuration)
} catch {
  FileHandle.standardError.write(Data("Open: engine failed to start: \(error)\n".utf8))
  exit(1)
}
LaunchTiming.shared.mark("engineStarted")

Engine.shared.runMessageLoop()
Engine.shared.shutdown()
exit(0)
