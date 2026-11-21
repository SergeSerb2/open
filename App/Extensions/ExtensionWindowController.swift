import AppKit
import OpenEngine
import OpenModel

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
  /// The popups of one context. Incognito end and Profile deletion close them first: a popup's
  /// Browser keeps its context open (the private session, or the deleted Profile's engine data).
  static func closeAll(in context: OEBrowserContext) {
    for controller in Array(windows.values) where controller.browser.context === context { controller.close() }
  }
  /// window.open from the popup's page: the URL opens as a tab in a window of the same Profile.
  /// The engine's own popup would be an unshown tab of this window's hidden Chrome strip.
  func webContent(_ webContent: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    switch request.disposition {
    case .currentTab, .saveToDisk, .newPictureInPicture: return nil
    default: break
    }
    guard let url = request.url, url.absoluteString != "about:blank", let app = NSApp.delegate as? AppDelegate else { return nil }
    let context = request.context
    DispatchQueue.main.async { _ = app.openExtensionTab(url: url, context: context) }
    return nil
  }
}

extension AppDelegate {
  func engine(_ engine: OEEngine, didOpenExtensionWindow browser: OEBrowser,
              content: OEWebContent, requestedFrame: NSRect, extension extensionID: String) {
    // A popup that arrives after its regular Profile was deleted (or its context closed) is not shown:
    // it would keep that context open again. An Incognito popup keeps the context checks of the engine.
    let context = browser.context
    if context.state != .live || (!context.isEphemeral && regularProfile(for: context) == nil) {
      content.close(); browser.close(); return
    }
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
  /// The model Profile of a regular (disk) context, nil for a private or unknown one.
  func regularProfile(for context: OEBrowserContext) -> Profile? {
    guard !context.isEphemeral else { return nil }
    return context === OEEngine.shared.defaultContext ? model.defaultProfile
      : model.profiles.first { $0.dataDirectoryName == context.identifier }
  }
  /// Opens a URL from an extension page that its own surface cannot show, in a window of the page's
  /// context: an Incognito context's own session window, else the most recent window of its Profile
  /// (a new window when none shows that Profile). Returns nil on success, else why it was dropped.
  @discardableResult
  func openExtensionTab(url: URL, context: OEBrowserContext) -> String? {
    if context.isEphemeral {
      // Never move a private page into a regular window: its session's window, or nothing.
      guard let controller = windowControllers.first(where: { hostFactories[$0.windowID]?.incognitoSession?.context === context }),
        let factory = hostFactories[controller.windowID], factory.openNewTab(url: url, background: false) != nil else {
        return "no-private-window"
      }
      focusWindow(controller.windowID, activate: true)
      return nil
    }
    return openExtensionTab(url: url, profileID: regularProfile(for: context)?.id)
  }
  @discardableResult
  func openExtensionTab(url: URL, profileID: ProfileID?) -> String? {
    guard let profileID, let space = model.mostRecentlyFocusedSpace(profileID: profileID) else { return "no-profile-space" }
    var controller = linkExecutor.orderedControllers.first { $0.context.focusedSpace?.profileID == profileID }
    if controller == nil {
      // makeWindow can reuse the retained final main window. Set its Space
      // before composition, so no page is created in a different Profile.
      if windowControllers.isEmpty, let retained = model.windows.first(where: { $0.style == .standard }) {
        model.focusSpace(windowID: retained.id, spaceID: space.id)
      }
      controller = makeWindow(focusedSpaceID: space.id)
    }
    guard let controller, controller.context.focusedSpace?.profileID == profileID,
      let target = hostFactories[controller.windowID], target.openNewTab(url: url, background: false) != nil else {
      return "target-unavailable"
    }
    focusWindow(controller.windowID, activate: true)
    return nil
  }
}
