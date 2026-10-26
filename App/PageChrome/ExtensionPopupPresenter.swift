import AppKit
import OpenEngine

/// The existing OpenEngine popup contract, without reaching into Chromium.
/// The borderless panel/radius is a guess; no extension-popup Arc capture is supplied.
@MainActor
final class ExtensionPopupPresenter {
  private weak var browser: OEBrowser?
  private weak var parent: NSWindow?
  private(set) var panel: ExtensionPopupPanel?
  private weak var content: OEWebContent?
  private var pointerMonitor: Any?
  private var resignationObserver: (any NSObjectProtocol)?

  func show(_ page: OEWebContent, browser: OEBrowser, parent: NSWindow, anchor: NSView?, title: String) {
    dismiss()
    self.browser = browser; self.parent = parent; content = page
    let panel = ExtensionPopupPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
    self.panel = panel; panel.title = title; panel.isReleasedWhenClosed = false
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
    panel.level = .floating; panel.hidesOnDeactivate = false
    let root = NSView(frame: panel.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 360, height: 480))
    root.wantsLayer = true; root.layer?.cornerRadius = 8; root.layer?.masksToBounds = true
    panel.contentView = root
    page.view.frame = root.bounds; page.view.autoresizingMask = [.width, .height]; root.addSubview(page.view)
    page.enableAutoResize(minimumSize: NSSize(width: 25, height: 25), maximumSize: NSSize(width: 800, height: 600))
    let anchorRect = anchor.map { parent.convertToScreen($0.convert($0.bounds, to: nil)) } ?? parent.convertToScreen(CGRect(x: parent.contentLayoutRect.maxX - 40, y: parent.contentLayoutRect.maxY - 40, width: 30, height: 30))
    panel.setFrameTopLeftPoint(NSPoint(x: min(anchorRect.minX, (parent.screen?.visibleFrame.maxX ?? anchorRect.maxX) - 360), y: anchorRect.minY - 4))
    panel.onDismiss = { [weak self] in self?.dismiss() }
    parent.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil); page.focusPage()
    pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        if let self, let panel = self.panel {
          var candidate = event.window
          while let window = candidate, window !== panel { candidate = window.parent }
          if candidate == nil { self.dismiss() }
        }
      }
      return event
    }
    resignationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }
  func owns(_ page: OEWebContent) -> Bool { content === page }
  func resize(_ size: NSSize) {
    guard let panel else { return }
    let size = NSSize(width: min(800, max(25, size.width)), height: min(600, max(25, size.height)))
    let top = panel.frame.maxY
    panel.setFrame(CGRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
  }
  func dismiss() { browser?.closeExtensionPopup(); cleanup() }
  func cleanup() {
    if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; pointerMonitor = nil
    if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }; resignationObserver = nil
    content?.view.removeFromSuperview(); content = nil
    if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil) }; panel = nil
    browser = nil; parent = nil
  }
  var state: [String: Any] {
    ["visible": panel?.isVisible == true, "window": panel?.windowNumber ?? 0,
      "size": panel.map { [$0.frame.width, $0.frame.height] } ?? [], "content": content?.identifier ?? 0,
      "extension": content?.extensionPopupIdentifier ?? "", "pending": "#93"]
  }
  isolated deinit {
    if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    if let resignationObserver { NotificationCenter.default.removeObserver(resignationObserver) }
  }
}
@MainActor
final class ExtensionPopupPanel: NSPanel {
  var onDismiss: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
