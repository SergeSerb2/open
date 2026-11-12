import AppKit
import OpenEngine
import Security
import QuartzCore
// Not inside OPEN_AUTOMATION: the shipping build uses ImportWizardViewModel and ArcImportProviders below.
// A merge has moved this line back three times (#371, #387, #396); keep it here.
import OpenSettings
#if OPEN_AUTOMATION
import OpenOnboarding
#endif

#if OPEN_AUTOMATION
// e2e runs keep their preferences in a private domain. First statement: nothing may read a preference before it.
AutomationPreferences.installIfRequested()
#endif
// A library injected for a test (DYLD_INSERT_LIBRARIES) is already loaded into this process by now.
// Remove the variable so that no child inherits it: the helpers, apps that Open opens, and
// /usr/bin/profiles, which Chromium runs for its device-management check. That tool is arm64e and
// aborted in dyld on an arm64 probe; its crash dialog then blocked every on-screen suite (2026-11-12).
unsetenv("DYLD_INSERT_LIBRARIES")

// Chromium's message pump needs the CefAppProtocol NSApplication subclass,
// created before anything else touches AppKit.
LaunchTiming.shared.phase("entry")
#if OPEN_AUTOMATION
// Validate the loader without creating NSApplication or a window. This is
// used before the first on-screen launch of a changed link set.
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LOADER_CHECK"] == "1" {
  FileHandle.standardError.write(Data("Open: loader check passed\n".utf8))
  exit(0)
}
LaunchTiming.shared.recordEntryImages()
#endif
let app = OEApplication.shared as! OEApplication
LaunchTiming.shared.mark("main")
// Open restores windows from its own snapshot (OpenStore), never through
// AppKit state restoration, which would also show a "reopen windows?" alert
// after a crash.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
let appDelegate = AppDelegate()
LaunchTiming.shared.phase("delegateCreated")
#if OPEN_AUTOMATION
StartupMainThreadTrace.startIfRequested()
RunLoopTurnTrace.startIfRequested()
#endif
app.delegate = appDelegate
#if OPEN_AUTOMATION
AutomationOwnerWatch.install()
#endif
// Reserved app shortcuts beat the page (Cmd-T, Cmd-W, Cmd-L, ...).
app.keyEquivalentHandler = { event in
  let handled = MainMenu.performReservedShortcut(event)
  #if OPEN_AUTOMATION
  LaunchTiming.shared.recordKeyReadiness(event, handled: handled)
  #endif
  return handled
}

let options = LaunchOptions(arguments: CommandLine.arguments)
LaunchTiming.shared.phase("optionsParsed")
appDelegate.options = options
// A fixture launch (--arc-dir) never scans the real ~/Library for other browsers unless it names a
// synthetic one with --browser-import-library.
ImportWizardViewModel.browserLibraryOverride = options.browserImportLibrary
  ?? options.arcDirectory.map { $0.appendingPathComponent(".no-browser-library", isDirectory: true) }
// The model comes first: the window can be built from it at once, and the
// engine needs the default profile's folder (docs/plans/profiles.md §6.2).
let directories = appDelegate.prepareData()
// Import from Arc ▸ Easels (EZ). Cheap: no Easel file is read until the wizard asks.
ArcImportProviders.all.append(EaselsImportProvider(app: appDelegate))
#if OPEN_AUTOMATION
FixtureImportProvider.registerIfRequested(root: directories.root)
#endif
#if OPEN_AUTOMATION
// A real launch through layout migration, before any window/engine or quit
// saves the model. A normal pre-engine quit must keep its normal save path.
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LAYOUT_ONLY"] == "1" {
  FileHandle.standardError.write(Data("Open: automation layout-only complete\n".utf8))
  exit(0)
}
if let receipt = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SCRIPTING_PREFLIGHT"] {
  AutomationScriptingPreflight.run(app: appDelegate, receipt: URL(fileURLWithPath: receipt))
}
#endif
// Finish AppKit launch and draw the snapshot-backed sidebar before loading
// Chromium. The same sidebar survives engine readiness; no page exists yet.
if appDelegate.isFirstRun { appDelegate.prepareOnboardingSound() }
app.setActivationPolicy(.regular)
LaunchTiming.shared.phase("finishLaunchingBegin")
app.finishLaunching()
LaunchTiming.shared.phase("finishLaunchingEnd")
// First run has no window until the engine and its first native loop burst
// return. Returning launches keep this snapshot-before-engine path unchanged.
if !appDelegate.isFirstRun {
appDelegate.drawWindowsBeforeEngine()
LaunchTiming.shared.phase("sidebarSubmitted")

// Wait for a display callback whose last refresh is later than the flushed
// window transaction. Chromium's observers must first run in its own loop,
// so return from this temporary AppKit loop before calling start.
let firstFrame = FirstWindowFrameObserver(view: appDelegate.firstContentView)
firstFrame.start()
#if OPEN_AUTOMATION
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_EARLY_LITTLE_OPEN"] == "1" {
  appDelegate.openBlankLittleOpen(timestamp: ProcessInfo.processInfo.systemUptime)
}
if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_QUIT_BEFORE_ENGINE"] == "1" {
  appDelegate.quitWarning.harnessQuit = true
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
  appDelegate.scheduleLibraryPrebuildAfterFirstDraw()
  #if OPEN_AUTOMATION
  LaunchTiming.shared.recordSidebarImages()
  appDelegate.recordFirstFrameMenuProbe()
  LaunchTiming.shared.postKeyReadinessProbe(to: appDelegate.frontWindowController?.window)
  #endif
} else {
  // An off-screen/asleep display may never tick. Presentation confirmation
  // is measurement evidence, not a requirement for starting the browser.
  LaunchTiming.shared.mark("firstFrameWaitTimedOut")
  FileHandle.standardError.write(Data("Open: first window frame unconfirmed; continuing engine startup\n".utf8))
}

appDelegate.firstRunWindowController?.startProbeAfterDisplay()
}

// Initialize outside the temporary AppKit runloop. Chromium installs native
// runloop observers during start; those must first run in CefRunMessageLoop.
#if OPEN_AUTOMATION
let engineConfigurationRegion = IntroPacingTrace.begin("engine.configuration")
#endif
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
// CEF main_runner.cc starts Chrome's MainThreadStackSamplingProfiler even in
// our unbranded Release build (thread_profiler_configuration.cc treats it as
// local). Open does not use its startup or periodic sampling collections.
configuration.additionalSwitches.append("--disable-stack-profiler")
// Widevine DRM (F3 option D): off by default; Open has no Widevine licence or
// VMP signature. With the Advanced setting on, the engine registers Google's CDM
// component (patch 0012) and the component updater downloads it.
if UserDefaults.standard.bool(forKey: "open.advanced.enableWidevine") {
  configuration.additionalSwitches.append("--open-enable-widevine")
}
// No userAgentProduct: Chrome's own User-Agent, as Arc does. A non-Chrome
// product token replaces "Chrome/156", and sites and extensions then take
// their Safari path (Bitwarden never finished loading).
// Ad-hoc signed builds (no Team ID) get a new signature on every build, so
// macOS would ask for keychain access each time; they use Chromium's mock key.
// Developer ID builds use the "Open Safe Storage" keychain item.
configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier
#if OPEN_AUTOMATION
// The engine's test hooks run only with this switch; normal Release builds
// never pass it. E2E launchers separately suppress macOS notification setup.
configuration.additionalSwitches = configuration.additionalSwitches + ["--open-automation"]
// No automation launch touches a real camera or microphone. With fake devices Chromium also skips the
// macOS permission check and request (system_media_capture_permissions_mac.mm), so no suite can raise
// "Allow 'Open' to access your microphone?". On a rented Mac that prompt blocked every on-screen run.
configuration.additionalSwitches.append("--use-fake-device-for-media-stream")
// Fixtures may exercise save prompts under the public mock key. This switch
// never permits imported real secrets under that key.
if CommandLine.arguments.contains("--open-allow-mock-keychain-secrets") {
  configuration.additionalSwitches.append("--open-allow-mock-keychain-secrets")
}
if AutomationNotificationSetup.suppressesSystemSetup {
  configuration.additionalSwitches.append(AutomationNotificationSetup.skipSwitch)
}
#endif

#if OPEN_AUTOMATION
engineConfigurationRegion?.end()
#endif
OEEngine.shared.delegate = appDelegate
LaunchTiming.shared.mark("engineStart")
#if OPEN_AUTOMATION
if appDelegate.isFirstRun { appDelegate.onboardingStartup["engineStartBeginHostTime"] = CACurrentMediaTime() }
if let data = try? JSONSerialization.data(withJSONObject: LaunchTiming.shared.report, options: [.sortedKeys]) {
  FileHandle.standardError.write(Data("Open: pre-engine timing ".utf8) + data + Data("\n".utf8))
}
#endif
do {
  #if OPEN_AUTOMATION
  let pacingRegion = IntroPacingTrace.begin("engine.start")
  defer { pacingRegion?.end() }
  #endif
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
#if OPEN_AUTOMATION
if appDelegate.isFirstRun { appDelegate.onboardingStartup["engineStartEndHostTime"] = CACurrentMediaTime() }
#endif

#if OPEN_AUTOMATION
IntroPacingTrace.current?.engineMessageLoopWillStart()
#endif
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
    #if OPEN_AUTOMATION
    let region = Thread.isMainThread ? MainActor.assumeIsolated { IntroPacingTrace.begin("engine.signatureCheck") } : nil
    defer { if let region { MainActor.assumeIsolated { region.end() } } }
    #endif
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
    LaunchTiming.shared.phase("frameObserverStarted")
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
    LaunchTiming.shared.phase("frameCallback")
    presented = true; CFRunLoopStop(CFRunLoopGetMain())
  }
  func stop() { link?.invalidate(); link = nil; timeout?.invalidate(); timeout = nil }
}
