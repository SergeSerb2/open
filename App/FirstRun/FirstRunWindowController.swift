import AppKit
import SwiftUI
import OpenSettings

private final class FirstRunNativeWindow: NSWindow {}

/// A welcome surface, never a BrowserModel window or a snapshot participant.
@MainActor
final class FirstRunWindowController: NSWindowController, NSWindowDelegate {
  let model: FirstRunViewModel
  private var probeTask: Task<Void, Never>?
  private var probeStarted = false

  init(model: FirstRunViewModel) {
    self.model = model
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
  override func showWindow(_ sender: Any?) { super.showWindow(sender); window?.makeKeyAndOrderFront(sender) }
  func startProbeAfterDisplay() {
    guard !probeStarted else { return }; probeStarted = true
    probeTask = Task { [weak self] in
      guard let self else { return }
      await model.refreshProbe()
      guard !Task.isCancelled else { return }
      model.arcIsRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "company.thebrowser.Browser" }
    }
  }
  func windowWillClose(_ notification: Notification) { probeTask?.cancel(); probeTask = nil }
}
