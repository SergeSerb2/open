import AppKit
import OpenEngine
import OpenSuggest

/// The command bar's profile/window adapter. Chromium owns the session and rows.
@MainActor
final class EngineCommandBarSource: ExtensionCommandBarSource {
  unowned let factory: EngineWebContentHostFactory
  private var sessionBrowser: OEBrowser?
  private var sessionID: String?
  private var latestText: String?
  private var latestRows: [ExtensionOmniboxRow] = []
  private var latestRequest: UUID?
  var onRowsChanged: ((String) -> Void)?
  private var pending: (id: UUID, continuation: CheckedContinuation<[ExtensionOmniboxRow]?, Never>)?
  init(factory: EngineWebContentHostFactory) { self.factory = factory }

  var actions: [ExtensionCommandBarAction] {
    (factory.focusedBrowser?.extensionActions ?? []).filter(\.isEnabled).map {
      ExtensionCommandBarAction(id: $0.extensionIdentifier, name: $0.extensionName,
        shortcutKeys: Self.keycaps($0.shortcutKeyEquivalent, flags: $0.shortcutModifierFlags))
    }
  }
  var keywords: [ExtensionKeyword] {
    (factory.focusedBrowser?.context.extensions.installedExtensions ?? []).compactMap {
      guard $0.isEnabled, let keyword = $0.omniboxKeyword, !keyword.isEmpty else { return nil }
      return ExtensionKeyword(id: $0.identifier, name: $0.name, keyword: keyword)
    }
  }
  func startSession(extensionID: String) {
    finish(nil)
    if let sessionID { sessionBrowser?.omniboxInputCancelled(forExtension: sessionID) }
    latestText = nil; latestRows = []; latestRequest = nil; sessionID = extensionID
    sessionBrowser = factory.focusedBrowser
    sessionBrowser?.omniboxStartSession(forExtension: extensionID)
  }
  func inputChanged(_ text: String, extensionID: String) async -> [ExtensionOmniboxRow]? {
    finish(nil)
    guard let browser = sessionBrowser, !Task.isCancelled else { return nil }
    if latestText == text { return latestRows }
    latestText = text; latestRows = []
    let id = UUID()
    latestRequest = id
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: nil); return }
        pending = (id, continuation)
        let listening = browser.omniboxInputChanged(text, forExtension: extensionID) { [weak self] rows in
          guard let self, self.latestRequest == id else { return }
          self.latestRows = rows.map(Self.row)
          if self.pending?.id == id { self.finish(self.latestRows) }
          else { self.onRowsChanged?(extensionID) }
        }
        if !listening { finish([]) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.pending?.id == id else { return }
        self?.finish(nil)
      }
    }
  }
  func defaultRow(extensionID: String, text: String) -> ExtensionOmniboxRow {
    guard let value = sessionBrowser?.omniboxDefaultSuggestion(forExtension: extensionID) else {
      return ExtensionOmniboxRow(content: text, title: text)
    }
    return Self.row(value)
  }
  func cancelSession(extensionID: String) {
    finish(nil)
    latestRequest = nil; latestText = nil; latestRows = []; sessionID = nil
    sessionBrowser?.omniboxInputCancelled(forExtension: extensionID)
    sessionBrowser = nil
  }
  func deleteSuggestion(_ content: String, extensionID: String) {
    sessionBrowser?.omniboxDeleteSuggestion(content, forExtension: extensionID)
  }
  func enter(_ content: String, extensionID: String, disposition: OEOmniboxDisposition) {
    finish(nil)
    latestRequest = nil; sessionID = nil
    sessionBrowser?.omniboxInputEntered(content, forExtension: extensionID, disposition: disposition)
    sessionBrowser = nil
  }
  private func finish(_ rows: [ExtensionOmniboxRow]?) {
    let continuation = pending?.continuation
    pending = nil
    continuation?.resume(returning: rows)
  }
  private static func row(_ value: OEOmniboxSuggestion) -> ExtensionOmniboxRow {
    ExtensionOmniboxRow(content: value.content, title: value.descriptionText,
      boldRanges: value.matchRanges.map { let r = $0.rangeValue; return r.location..<(r.location + r.length) },
      deletable: value.isDeletable)
  }
  private static func keycaps(_ key: String?, flags: NSEvent.ModifierFlags) -> [String] {
    guard let key, !key.isEmpty else { return [] }
    // Cocoa encodes Shift in an uppercase letter as well as in modifierFlags.
    let shifted = flags.contains(.shift) || (key != key.lowercased() && key == key.uppercased())
    return (flags.contains(.control) ? ["⌃"] : []) + (flags.contains(.option) ? ["⌥"] : [])
      + (shifted ? ["⇧"] : []) + (flags.contains(.command) ? ["⌘"] : []) + [key.uppercased()]
  }
}

extension EngineWebContentHostFactory {
  func browser(_ browser: OEBrowser, omniboxDefaultSuggestionDidChangeForExtension identifier: String) {
    guard browser === focusedBrowser else { return }
    commandBarSession?.controller?.refreshExtensionSuggestions(extensionID: identifier)
  }
}
