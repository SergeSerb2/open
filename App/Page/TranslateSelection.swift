import AppKit
import OpenEngine
import OpenTranslate

/// Translate Selection (PB4 row 5). Arc's engine carries Chromium's partial translate, which
/// needs Google keys (ArcCore string `GOOGLE_API_KEY_PARTIAL_TRANSLATE`, page-platform PG-7.2);
/// Open translates the selected text on device with the same backend as page translation and
/// shows the result in a small popover with Copy. Look values are GUESS (no capture of Arc's bubble).
@MainActor
final class TranslateSelectionController {
  static let maxCharacters = 5000
  unowned let adapter: TranslateAdapter
  private(set) var popover: NSPopover?
  private(set) var last: [String: Any] = [:]
  private var task: Task<Void, Never>?
  init(adapter: TranslateAdapter) { self.adapter = adapter }

  /// The user's first preferred language (the menu title names it).
  static var target: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }
  static var menuTitle: String { "Translate Selection to \(PageLanguageDetector.displayName(target))" }

  /// Where the context menu opened (the page view's coordinates): the popover's anchor.
  private var anchorPoint: NSPoint?
  private weak var anchorView: NSView?

  func translate(_ raw: String, at point: NSPoint? = nil, in view: NSView? = nil) {
    anchorPoint = point; anchorView = view
    let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCharacters))
    guard !text.isEmpty else { return }
    task?.cancel()
    let target = Self.target
    last = ["state": "translating", "text": text, "target": target.minimalIdentifier]
    task = Task { [weak self] in
      guard let self else { return }
      let backend = self.adapter.backend
      guard let detected = PageLanguageDetector.detect(PageLanguageProbe(langAttribute: "", text: text)) else {
        return self.show(original: text, result: nil, message: "Open could not tell which language this is.")
      }
      let source = detected.language
      if PageLanguageDetector.sameLanguage(source, target) {
        return self.show(original: text, result: nil, message: "This text is already in \(PageLanguageDetector.displayName(target)).")
      }
      do {
        switch await backend.status(from: source, to: target) {
        case .installed: break
        case .supported:
          // A user action: macOS's own language download prompt, as for page translation.
          guard let apple = backend as? AppleTranslationBackend, let view = self.adapter.factory.controller?.contentView,
                view.window?.isVisible == true else { throw TranslationFailure("Language not installed") }
          try await apple.prepare(from: source, to: target, in: view)
        case .unsupported: throw TranslationFailure("Unsupported language pair")
        }
        let out = try await backend.translate([text], from: source, to: target)
        guard !Task.isCancelled else { return }
        self.last["source"] = source.minimalIdentifier
        self.show(original: text, result: out.first ?? "", message: nil)
      } catch {
        guard !Task.isCancelled else { return }
        self.last["source"] = source.minimalIdentifier
        self.show(original: text, result: nil, message: "Translation error (\(TranslationFailure.reason(for: error)))")
      }
    }
  }

  private func show(original: String, result: String?, message: String?) {
    last["state"] = result != nil ? "translated" : "failed"
    last["result"] = result ?? ""
    last["message"] = message ?? ""
    popover?.close()
    guard let view = anchorView ?? adapter.factory.controller?.contentView, let window = view.window, window.isVisible else { last["shown"] = false; return }
    let content = TranslateSelectionView(result: result, message: message,
      sourceName: (last["source"] as? String).map { PageLanguageDetector.displayName(Locale.Language(identifier: $0)) },
      targetName: PageLanguageDetector.displayName(Self.target))
    let controller = NSViewController(); controller.view = content
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = controller
    popover.contentSize = content.fittingSize
    // Anchored where the context menu opened, inside the page view.
    let point = anchorPoint ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
    let anchor = NSRect(x: min(max(point.x, 1), view.bounds.width - 1), y: min(max(point.y, 1), view.bounds.height - 1), width: 1, height: 1)
    popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    last["anchorInPage"] = view !== adapter.factory.controller?.contentView
    self.popover = popover
    last["shown"] = popover.isShown
  }

  func close() { task?.cancel(); popover?.close(); popover = nil }

  var state: [String: Any] {
    var out = last
    out["shown"] = popover?.isShown == true
    out["popoverWindow"] = popover?.contentViewController?.view.window?.windowNumber ?? 0
    out["menuTitle"] = Self.menuTitle
    if let view = popover?.contentViewController?.view as? TranslateSelectionView { out["shownText"] = view.resultField.stringValue }
    return out
  }
  func pressCopy() -> Bool {
    guard let view = popover?.contentViewController?.view as? TranslateSelectionView, !view.copyButton.isHidden else { return false }
    view.copyButton.performClick(nil); return true
  }
}

/// The popover's content: "French → English", the translation (selectable), Copy.
/// GUESS look: system popover, 13 pt text, 320 pt wide.
@MainActor
final class TranslateSelectionView: NSView {
  let header = NSTextField(labelWithString: "")
  let resultField = NSTextField(wrappingLabelWithString: "")
  let copyButton = NSButton(title: "Copy", target: nil, action: nil)
  private let result: String?
  init(result: String?, message: String?, sourceName: String?, targetName: String) {
    self.result = result
    super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
    header.stringValue = sourceName.map { "\($0) → \(targetName)" } ?? "Translate Selection"
    header.font = .systemFont(ofSize: 11, weight: .medium); header.textColor = .secondaryLabelColor
    resultField.stringValue = result ?? message ?? ""
    resultField.font = .systemFont(ofSize: 13); resultField.isSelectable = true
    resultField.textColor = result == nil ? .secondaryLabelColor : .labelColor
    resultField.preferredMaxLayoutWidth = 292
    copyButton.bezelStyle = .rounded; copyButton.controlSize = .small
    copyButton.target = self; copyButton.action = #selector(copy(_:)); copyButton.isHidden = result == nil
    copyButton.setAccessibilityIdentifier("translate-selection-copy")
    let stack = NSStackView(views: [header, resultField, copyButton])
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                 stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                 widthAnchor.constraint(equalToConstant: 320)])
    setAccessibilityIdentifier("translate-selection")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func copy(_ sender: Any?) {
    guard let result else { return }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
  }
}
