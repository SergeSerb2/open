import AppKit

/// Replaced by the OpenSettings presenters when that target lands on main.
/// This entry owns no model or SnapshotStore.
@MainActor
final class SettingsPlaceholder: NSObject, NSWindowDelegate {
  unowned let app: AppDelegate
  private(set) var settings: NSWindowController?
  private(set) var library: NSWindowController?
  private(set) var hotkeyToggle: NSButton?
  private(set) var externalToggle: NSButton?
  init(app: AppDelegate) { self.app = app }
  func show() {
    if settings == nil {
      let pane = UserDefaults.standard.string(forKey: "open.settings.lastPane") ?? "General"
      let window = makeWindow(title: pane, size: NSSize(width: 684, height: 650))
      let text = NSTextField(labelWithString: "Settings land with OpenSettings.")
      text.frame = NSRect(x: 28, y: 586, width: 620, height: 28); window.contentView?.addSubview(text)
      let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
      let status = NSTextField(labelWithString: "Default browser: \(defaultURL?.deletingPathExtension().lastPathComponent ?? "Unknown")")
      status.frame = NSRect(x: 28, y: 544, width: 620, height: 24); window.contentView?.addSubview(status)
      hotkeyToggle = NSButton(checkboxWithTitle: "Enable Little Open shortcut", target: self, action: #selector(hotkeyChanged(_:)))
      hotkeyToggle?.state = (UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true) ? .on : .off
      hotkeyToggle?.frame = NSRect(x: 28, y: 494, width: 620, height: 28)
      externalToggle = NSButton(checkboxWithTitle: "Open external links in Little Open", target: self, action: #selector(externalChanged(_:)))
      externalToggle?.state = (UserDefaults.standard.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true) ? .on : .off
      externalToggle?.frame = NSRect(x: 28, y: 454, width: 620, height: 28)
      if let hotkeyToggle { window.contentView?.addSubview(hotkeyToggle) }
      if let externalToggle { window.contentView?.addSubview(externalToggle) }
      settings = NSWindowController(window: window)
      UserDefaults.standard.set(pane, forKey: "open.settings.lastPane")
    }
    show(settings)
  }
  func showLibrary() {
    if library == nil {
      let window = makeWindow(title: "Library", size: NSSize(width: 900, height: 650))
      let text = NSTextField(labelWithString: "Library lands with OpenSettings.")
      text.frame = NSRect(x: 28, y: 580, width: 820, height: 28); window.contentView?.addSubview(text)
      library = NSWindowController(window: window)
    }
    show(library)
  }
  private func makeWindow(title: String, size: NSSize) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title; window.isReleasedWhenClosed = false; window.delegate = self; window.center(); return window
  }
  private func show(_ controller: NSWindowController?) { controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil); NSApp.activate(); app.scheduleMenuRebuild() }
  func windowDidBecomeKey(_ notification: Notification) { app.scheduleMenuRebuild() }
  @objc func hotkeyChanged(_ button: NSButton) { UserDefaults.standard.set(button.state == .on, forKey: "open.links.littleOpenHotkeyEnabled"); app.prepareCommandServices(); app.updateLittleOpenHotkey() }
  @objc func externalChanged(_ button: NSButton) { UserDefaults.standard.set(button.state == .on, forKey: "open.links.externalInLittleOpen") }
}
