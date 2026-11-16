import AppKit
import OpenEngine

/// chrome.windows popup windows have their own hidden Browser and native frame.
/// One hosted page per popup is a guess (child); multi-URL popups are refused.
@MainActor
final class ExtensionWindowController: NSWindowController, NSWindowDelegate, OEWebContentDelegate {
  private(set) static var windows: [Int: ExtensionWindowController] = [:]
  let browser: OEBrowser
  let content: OEWebContent
  let extensionID: String
  private var closing = false

  init(browser: OEBrowser, content: OEWebContent, requestedFrame: NSRect,
       extensionID: String, parent: NSWindow?) {
    self.browser = browser; self.content = content; self.extensionID = extensionID
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.title = content.title ?? ""
    window.contentView = content.view
    content.delegate = self
    browser.window = window
    window.setFrameAutosaveName("ExtensionPopupWindow")
    if !requestedFrame.isEmpty {
      window.setFrame(requestedFrame, display: false)
    } else if !window.setFrameUsingName("ExtensionPopupWindow") {
      let parentFrame = parent?.frame ?? NSScreen.main?.visibleFrame ?? window.frame
      window.setFrame(NSRect(x: parentFrame.midX - 200, y: parentFrame.midY - 300, width: 400, height: 600), display: false)
    }
    Self.windows[browser.identifier] = self
    window.orderFront(nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func windowWillClose(_ notification: Notification) {
    guard !closing else { return }
    closing = true
    window?.saveFrame(usingName: "ExtensionPopupWindow")
    content.close(); browser.close()
    Self.windows.removeValue(forKey: browser.identifier)
  }
  /// Chromium is still inside its delegate callback here: close the page on the next turn,
  /// as the browser window's close path does (`webContentDidRequestClose` in the factory).
  private func closeAfterCallback() { DispatchQueue.main.async { [weak self] in self?.close() } }
  func webContentDidRequestClose(_ webContent: OEWebContent) { closeAfterCallback() }
  func webContent(_ webContent: OEWebContent, didChange changes: OEWebContentChange) {
    window?.title = webContent.title ?? ""
  }
  func webContent(_ webContent: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
       event.charactersIgnoringModifiers?.lowercased() == "w" { closeAfterCallback(); return true }
    return false
  }
  static func closeAll() { for controller in Array(windows.values) { controller.close() } }
}

extension AppDelegate {
  func engine(_ engine: OEEngine, didOpenExtensionWindow browser: OEBrowser,
              content: OEWebContent, requestedFrame: NSRect, extension extensionID: String) {
    let parent = hostFactories.values.first { $0.focusedBrowser?.context === browser.context && $0.window?.isMainWindow == true }?.window
      ?? frontWindowController?.window
    _ = ExtensionWindowController(browser: browser, content: content, requestedFrame: requestedFrame,
      extensionID: extensionID, parent: parent)
  }
  func engine(_ engine: OEEngine, extensionWindow browser: OEBrowser, requestsFrame frame: NSRect, focused: Bool) {
    guard let window = ExtensionWindowController.windows[browser.identifier]?.window else { return }
    if !frame.isEmpty && window.frame != frame { window.setFrame(frame, display: true) }
    if focused { window.makeKeyAndOrderFront(nil) }
  }
}
