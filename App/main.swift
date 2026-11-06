import AppKit
import OpenEngine
import Security
import QuartzCore

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
#if OPEN_AUTOMATION
AutomationOwnerWatch.install()
#endif
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

// Wait for a display callback whose last refresh is later than the flushed
// window transaction. Chromium's observers must first run in its own loop,
// so return from this temporary AppKit loop before calling start.
let firstFrame = FirstWindowFrameObserver(view: appDelegate.windowControllers.first?.window?.contentView)
firstFrame.start()
#if OPEN_AUTOMATION
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_EARLY_LITTLE_OPEN"] == "1" {
  appDelegate.openBlankLittleOpen(timestamp: ProcessInfo.processInfo.systemUptime)
}
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_QUIT_BEFORE_ENGINE"] == "1" {
  RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
}
if let input = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_EARLY_NAVIGATION"] {
  appDelegate.frontWindowController.flatMap { appDelegate.hostFactories[$0.windowID] }?.navigateBeforeEngineForAutomation(input)
}
#endif
while !firstFrame.presented && !firstFrame.timedOut && !appDelegate.terminationRequested { CFRunLoopRun() }
firstFrame.stop()
if appDelegate.terminationRequested {
  LaunchTiming.shared.mark("terminationSkippedEngine")
  appDelegate.saveState()
  FileHandle.standardError.write(Data("Open: termination before engine; timing \(LaunchTiming.shared.report)\n".utf8))
  exit(0)
}
LaunchTiming.shared.recordFirstFrame(confirmed: firstFrame.presented)
if firstFrame.presented {
  LaunchTiming.shared.mark("sidebarDrawn")
} else {
  // An off-screen/asleep display may never tick. Presentation confirmation
  // is measurement evidence, not a requirement for starting the browser.
  LaunchTiming.shared.mark("firstFrameWaitTimedOut")
  FileHandle.standardError.write(Data("Open: first window frame unconfirmed; continuing engine startup\n".utf8))
}

// Initialize outside the temporary AppKit runloop. Chromium installs native
// runloop observers during start; those must first run in CefRunMessageLoop.
let configuration = OEEngineConfiguration()
// root_cache_path = <root>/Engine. The default profile's engine data is
// Engine/Default (CEF's fixed name for the global context); other profiles
// use Engine/<dir> (EngineWebContentHostFactory.context(for:)). CEF loads a
// disk profile only for a direct child of root_cache_path
// (docs/plans/profiles.md §6.2). The launch's engine layout step moved older
// data there; if it could not, this launch uses the old root (<root>/Profiles).
configuration.userDataDirectory = appDelegate.engine.engineRoot
configuration.logFile = directories.root.appendingPathComponent("State/engine.log")
configuration.defaultRuntimeStyle = options.defaultStyle
configuration.remoteDebuggingPort = options.remoteDebuggingPort
configuration.verboseLogging = options.verboseLogging
// No userAgentProduct: Chrome's own User-Agent, as Arc does. A non-Chrome
// product token replaces "Chrome/156", and sites and extensions then take
// their Safari path (Bitwarden never finished loading).
// Ad-hoc signed builds (no Team ID) get a new signature on every build, so
// macOS would ask for keychain access each time; they use Chromium's mock key.
// Developer ID builds use the "Open Safe Storage" keychain item.
configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier
#if OPEN_AUTOMATION
// The engine's notification test hooks (page-platform EP-7) run only with this
// switch; release builds never pass it.
configuration.additionalSwitches = configuration.additionalSwitches + ["--open-automation"]
#endif

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
  appDelegate.saveState()
  let alert = NSAlert()
  alert.messageText = "Open could not start its browser engine."
  alert.informativeText = error.localizedDescription
  alert.addButton(withTitle: "Quit")
  #if OPEN_AUTOMATION
  if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_DISMISS_ENGINE_FAILURE"] == "1" {
    FileHandle.standardError.write(Data("Open: engine failure alert shown; button=Quit\n".utf8))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { alert.buttons.first?.performClick(nil) }
  }
  #endif
  alert.runModal()
  exit(1)
}
LaunchTiming.shared.mark("engineStarted")

OEEngine.shared.runMessageLoop()
appDelegate.saveState()
appDelegate.prepareForEngineShutdown()
appDelegate.recordShutdownPhase("engineShutdownBegin")
OEEngine.shared.shutdown()
appDelegate.recordShutdownPhase("engineShutdownEnd")
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


/// A display tick reports the last screen refresh. A refresh after submission
/// confirms that the window server has had the flushed sidebar transaction.
@MainActor
final class FirstWindowFrameObserver: NSObject {
  private weak var view: NSView?
  private var link: CADisplayLink?
  private var timeout: Timer?
  private var submittedAt: CFTimeInterval = 0
  private(set) var presented = false
  private(set) var timedOut = false
  init(view: NSView?) { self.view = view }
  func start() {
    submittedAt = CACurrentMediaTime()
    var observeDisplay = true
    #if OPEN_AUTOMATION
    observeDisplay = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SKIP_DISPLAY_LINK"] != "1"
    #endif
    if observeDisplay {
      link = view?.displayLink(target: self, selector: #selector(frame(_:)))
      link?.add(to: .main, forMode: .common)
    }
    timeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.timedOut = true; CFRunLoopStop(CFRunLoopGetMain()) }
    }
  }
  @objc private func frame(_ link: CADisplayLink) {
    guard link.timestamp >= submittedAt else { return }
    presented = true; CFRunLoopStop(CFRunLoopGetMain())
  }
  func stop() { link?.invalidate(); link = nil; timeout?.invalidate(); timeout = nil }
}
