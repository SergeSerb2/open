import AppKit
import SwiftUI
import OpenSettings

private final class FirstRunNativeWindow: NSWindow {}

/// A welcome surface, never a BrowserModel window or a snapshot participant.
@MainActor
final class FirstRunWindowController: NSWindowController, NSWindowDelegate {
  let model: FirstRunViewModel
  private var probeTask: Task<Void, Never>?
  private var hasDisplayed = false
  private var probeRequest: UUID?

  init(model: FirstRunViewModel, hostedIn: NSWindow? = nil) {
    self.model = model
    if let hostedIn {
      super.init(window: hostedIn)
      return
    }
    let window = FirstRunNativeWindow(contentRect: NSRect(origin: .zero, size: FirstRunWindow.size),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Open"; window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true; window.isRestorable = false
    window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
    let host = NSHostingController(rootView: FirstRunView(model: model, startsProbe: false))
    host.sizingOptions = []
    window.contentViewController = host
    // Full-size content includes the transparent titlebar. NSWindow's content
    // initializer otherwise adds its 32 pt titlebar to the specified height.
    window.setFrame(NSRect(origin: window.frame.origin, size: FirstRunWindow.size), display: false)
    super.init(window: window)
    window.delegate = self; window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func showWindow(_ sender: Any?) {
    super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    if hasDisplayed && model.probe == nil {
      window?.displayIfNeeded()
      startProbeAfterDisplay()
    }
  }
  func startProbeAfterDisplay() {
    hasDisplayed = true
    guard probeTask == nil, model.probe == nil else { return }
    let request = UUID(); probeRequest = request
    probeTask = Task { [weak self] in
      guard let self else { return }
      defer { if probeRequest == request { probeTask = nil } }
      #if OPEN_AUTOMATION
      if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_PROBE_DELAY_MS"], let delay = Int(raw), delay > 0 {
        try? await Task.sleep(for: .milliseconds(min(delay, 5_000)))
      }
      #endif
      guard !Task.isCancelled else { return }
      await model.refreshProbe()
      guard !Task.isCancelled else { return }
      model.arcIsRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "company.thebrowser.Browser" }
    }
  }
  func windowWillClose(_ notification: Notification) {
    probeRequest = nil; probeTask?.cancel(); probeTask = nil
  }
}
