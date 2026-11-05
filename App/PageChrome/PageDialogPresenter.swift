import AppKit
import OpenEngine

/// Native sheets: docs/re/page-chrome.md §2 and the S11 dialog design.
/// Entries leave the queue before their engine completion can reenter App code.
@MainActor
final class PageDialogPresenter {
  @MainActor
  final class Entry: NSResponder, NSTextFieldDelegate {
    let page: OEWebContent
    let dialog: OEJavaScriptDialog
    let held: Bool
    weak var parentWindow: NSWindow?
    var alert: NSAlert?
    var field: NSTextField?
    var suppression: NSButton?
    let suppressible: Bool
    var completed = false
    init(page: OEWebContent, dialog: OEJavaScriptDialog, held: Bool, suppressible: Bool) {
      self.page = page; self.dialog = dialog; self.held = held; self.suppressible = suppressible; super.init()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
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
  var isVisible: ((OEWebContent) -> Bool) = { _ in false }
  var record: ((String, OEWebContent, [String: Any]) -> Void)?
  private var documentCounts: [ObjectIdentifier: Int] = [:]
  private var suppressed: Set<ObjectIdentifier> = []
  private(set) var entries: [Entry] = []
  private var sheetObserver: (any NSObjectProtocol)?
  private var closed = false

  static func title(_ dialog: OEJavaScriptDialog) -> String {
    if dialog.kind == .beforeUnload { return dialog.isReload ? "Reload site?" : "Leave site?" }
    guard let origin = dialog.originURL, !["data", "file", "about"].contains(origin.scheme ?? ""),
          let host = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.host, !host.isEmpty else { return "This page says" }
    return "\(host) says"
  }
  static func buttons(_ dialog: OEJavaScriptDialog) -> [String] { dialog.kind == .alert ? ["OK"] : ["OK", "Cancel"] }

  func enqueue(_ dialog: OEJavaScriptDialog, page: OEWebContent, held: Bool) {
    guard !closed else { dialog.complete(accepted: false, text: nil); return }
    let key = ObjectIdentifier(page), ordinary = dialog.kind != .beforeUnload
    let count = documentCounts[key, default: 0]
    if ordinary { documentCounts[key] = min(2, count + 1) }
    let suppressible = ordinary && count >= 1
    var info: [String: Any] = ["kind": dialog.kind.rawValue, "message": dialog.message,
      "default": dialog.defaultPromptText, "title": Self.title(dialog), "buttons": Self.buttons(dialog),
      "suppressible": suppressible, "queued": !isVisible(page) || entries.contains { $0.alert != nil }]
    if ordinary && suppressed.contains(key) {
      info["suppressed"] = true; record?("dialog", page, info)
      dialog.complete(accepted: dialog.kind == .alert, text: nil); return
    }
    record?("dialog", page, info)
    if let reason = PageChromeLimits.dialogFailure(dialog) {
      record?("pageChromeRefused", page, ["reason": reason]); dialog.complete(accepted: false, text: nil); return
    }
    guard entries.filter({ $0.page === page }).count < PageChromeLimits.pendingRequests else {
      record?("pageChromeRefused", page, ["reason": "Page dialog queue exceeds 8 requests."])
      dialog.complete(accepted: false, text: nil); return
    }
    let entry = Entry(page: page, dialog: dialog, held: held, suppressible: suppressible)
    entry.parentWindow = page.view.window ?? window
    entries.append(entry); presentNext()
  }
  func navigated(_ page: OEWebContent) {
    let key = ObjectIdentifier(page)
    cancel(page: page); documentCounts[key] = nil; suppressed.remove(key)
  }
  func hasPending(_ page: OEWebContent) -> Bool { entries.contains { $0.page === page } }
  var pendingDialogs: [OEJavaScriptDialog] { entries.map(\.dialog) }
  @discardableResult
  func answer(accepted: Bool, text: String?) -> Bool {
    guard let entry = entries.first else { return false }
    if entry.alert != nil, accepted || entry.dialog.kind != .alert { return press(accepted: accepted, text: text, suppress: false) }
    finish(entry, accepted: accepted, text: text); return true
  }
  @discardableResult
  func press(accepted: Bool, text: String?, suppress: Bool) -> Bool {
    guard let entry = entries.first(where: { $0.alert != nil }), let alert = entry.alert else { return false }
    entry.suppression?.state = suppress ? .on : .off
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
    if entry.suppression?.state == .on { suppressed.insert(ObjectIdentifier(entry.page)) }
    record?("dialogAnswer", entry.page, ["kind": entry.dialog.kind.rawValue, "accepted": accepted])
    entry.nextResponder = nil
    if let sheet = entry.alert?.window, sheet.sheetParent != nil { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
    entry.dialog.complete(accepted: accepted, text: entry.dialog.kind == .prompt ? text : nil)
    onDecision?(entry.page, entry.dialog.kind, accepted)
    presentNext()
  }
  func presentNext() {
    guard !closed, !entries.contains(where: { $0.alert != nil }),
          let entry = entries.first(where: { !$0.held && isVisible($0.page) }), let window = entry.parentWindow ?? window else { return }
    if window.attachedSheet != nil {
      if sheetObserver == nil {
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { DispatchQueue.main.async { self?.presentNext() } }
        }
      }
      return
    }
    let alert = NSAlert(); entry.alert = alert
    alert.messageText = Self.title(entry.dialog)
    alert.informativeText = entry.dialog.kind == .beforeUnload ? "Changes you made may not be saved." : entry.dialog.message
    for title in Self.buttons(entry.dialog) { alert.addButton(withTitle: title) }
    if alert.buttons.count > 1 { alert.buttons[1].keyEquivalent = "\u{1b}" }
    var accessories: [NSView] = []
    if entry.dialog.kind == .prompt {
      let field = NSTextField(string: entry.dialog.defaultPromptText)
      field.frame.size = NSSize(width: 260, height: 24); entry.field = field
      field.delegate = entry; field.setAccessibilityLabel("Response"); accessories.append(field)
    }
    if entry.suppressible {
      let checkbox = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
      entry.suppression = checkbox; accessories.append(checkbox)
    }
    if !accessories.isEmpty {
      let stack = NSStackView(views: accessories); stack.orientation = .vertical
      stack.alignment = .leading; stack.spacing = 8
      stack.frame.size = NSSize(width: 260, height: CGFloat(accessories.count) * 24 + CGFloat(accessories.count - 1) * 8)
      if let field = entry.field { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
      alert.accessoryView = stack
    }
    alert.beginSheetModal(for: window) { [weak self, weak entry] response in
      guard let self, let entry else { return }
      self.finish(entry, accepted: response == .alertFirstButtonReturn, text: entry.field?.stringValue)
    }
    if let field = entry.field { alert.window.makeFirstResponder(field); field.selectText(nil) }
    else if entry.dialog.kind == .alert { entry.nextResponder = alert.window; alert.window.makeFirstResponder(entry) }
  }
  var state: [String: Any] {
    guard let entry = entries.first(where: { $0.alert != nil }) ?? entries.first else { return ["pending": 0, "visible": false] }
    return ["pending": entries.count, "kind": entry.dialog.kind.rawValue,
      "visible": entry.alert?.window.isVisible == true, "held": entry.held,
      "title": entry.alert?.messageText ?? Self.title(entry.dialog),
      "informativeText": entry.alert?.informativeText ?? "",
      "suppressible": entry.alert == nil ? entry.suppressible : entry.suppression != nil, "queued": entry.alert == nil,
      "message": entry.dialog.message, "text": entry.field?.stringValue ?? "",
      "suppressionTitle": entry.suppression?.title ?? "", "promptWidth": entry.field?.frame.width ?? 0,
      "sourceMessageBytes": entry.dialog.message.utf8.count, "sourcePromptBytes": entry.dialog.defaultPromptText.utf8.count,
      "buttons": entry.alert?.buttons.map(\.title) ?? [], "window": entry.alert?.window.windowNumber ?? 0]
  }
  isolated deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) } }
}
