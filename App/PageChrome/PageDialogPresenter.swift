import AppKit
import OpenEngine

/// Native non-blocking sheets, per app-shell §4.9. Exact Arc dialog metrics
/// are absent from the RE captures; native macOS sheet styling is a guess.
@MainActor
final class PageDialogPresenter {
  @MainActor
  final class Entry: NSResponder, NSTextFieldDelegate {
    let page: OEWebContent
    let dialog: OEJavaScriptDialog
    let held: Bool
    var alert: NSAlert?
    var field: NSTextField?
    var completed = false
    init(page: OEWebContent, dialog: OEJavaScriptDialog, held: Bool) {
      self.page = page; self.dialog = dialog; self.held = held; super.init()
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
      // A one-button NSAlert has no Cancel key equivalent. Keep Escape on
      // this sheet's responder chain and invoke its real default button.
      if dialog.kind == .alert, !completed,
         event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
         [36, 76, 53].contains(event.keyCode) { alert?.buttons.first?.performClick(nil); return }
      super.keyDown(with: event)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard !completed, !textView.hasMarkedText(), let alert else { return false }
      switch NSStringFromSelector(selector) {
      case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
        control.validateEditing()
        alert.buttons.first?.performClick(nil) // the sheet's real OK/default button
        return true
      case "cancelOperation:":
        alert.buttons.last?.performClick(nil)
        return true
      default: return false
      }
    }
  }
  weak var window: NSWindow?
  var onDecision: ((OEWebContent, OEJavaScriptDialogKind, Bool) -> Void)?
  private(set) var entries: [Entry] = []
  private var sheetObserver: (any NSObjectProtocol)?
  private var closed = false

  func enqueue(_ dialog: OEJavaScriptDialog, page: OEWebContent, held: Bool) {
    guard !closed else { dialog.complete(accepted: false, text: nil); return }
    entries.append(Entry(page: page, dialog: dialog, held: held)); presentNext()
  }
  var pendingDialogs: [OEJavaScriptDialog] { entries.map(\.dialog) }
  @discardableResult
  func answer(accepted: Bool, text: String?) -> Bool {
    guard let entry = entries.first else { return false }
    finish(entry, accepted: accepted, text: text); return true
  }
  @discardableResult
  func press(accepted: Bool, text: String?) -> Bool {
    guard let entry = entries.first, let alert = entry.alert else { return false }
    if let text { entry.field?.stringValue = text }
    let index = accepted ? 0 : 1
    guard alert.buttons.indices.contains(index) else { return false }
    alert.buttons[index].performClick(nil); return true
  }
  func cancel(page: OEWebContent) {
    for entry in entries.filter({ $0.page === page }) { finish(entry, accepted: false, text: nil) }
  }
  func close() {
    closed = true
    for entry in entries { finish(entry, accepted: false, text: nil) }
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }; sheetObserver = nil
  }
  private func finish(_ entry: Entry, accepted: Bool, text: String?) {
    guard !entry.completed else { return }; entry.completed = true
    entries.removeAll { $0 === entry }
    entry.nextResponder = nil
    if let sheet = entry.alert?.window, sheet.sheetParent != nil { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
    entry.dialog.complete(accepted: accepted, text: entry.dialog.kind == .prompt ? text : nil)
    onDecision?(entry.page, entry.dialog.kind, accepted)
    presentNext()
  }
  private func presentNext() {
    guard !closed, let entry = entries.first, !entry.held, entry.alert == nil,
          let window else { return }
    if window.attachedSheet != nil {
      if sheetObserver == nil {
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentNext() }
        }
      }
      return
    }
    let alert = NSAlert(); entry.alert = alert
    alert.messageText = entry.dialog.kind == .beforeUnload ? "Leave this page?" : entry.dialog.originURL?.host() ?? "This page says"
    alert.informativeText = entry.dialog.kind == .beforeUnload ? "Changes you made may not be saved." : entry.dialog.message
    alert.addButton(withTitle: entry.dialog.kind == .beforeUnload ? "Leave" : "OK")
    if entry.dialog.kind != .alert {
      let cancel = alert.addButton(withTitle: entry.dialog.kind == .beforeUnload ? "Stay" : "Cancel")
      cancel.keyEquivalent = "\u{1b}"
    }
    if entry.dialog.kind == .prompt {
      let field = NSTextField(string: entry.dialog.defaultPromptText)
      field.frame.size = NSSize(width: 280, height: 24); entry.field = field
      field.delegate = entry
      field.setAccessibilityLabel("Response"); alert.accessoryView = field
    }
    alert.beginSheetModal(for: window) { [weak self, weak entry] response in
      guard let self, let entry else { return }
      self.finish(entry, accepted: response == .alertFirstButtonReturn, text: entry.field?.stringValue)
    }
    if let field = entry.field { alert.window.makeFirstResponder(field); field.selectText(nil) }
    else if entry.dialog.kind == .alert { entry.nextResponder = alert.window; alert.window.makeFirstResponder(entry) }
  }
  var state: [String: Any] {
    guard let entry = entries.first else { return ["pending": 0, "visible": false] }
    return ["pending": entries.count, "kind": entry.dialog.kind.rawValue,
      "visible": entry.alert?.window.isVisible == true, "held": entry.held,
      "message": entry.dialog.message, "text": entry.field?.stringValue ?? "",
      "buttons": entry.alert?.buttons.map(\.title) ?? [], "window": entry.alert?.window.windowNumber ?? 0]
  }
  isolated deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) } }
}
