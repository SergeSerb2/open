import AppKit
import OpenEngine
import OpenTranslate
import OpenWeb

/// Translate Selection (PB4 row 5). Arc's engine carries Chromium's partial translate, which
/// needs Google keys (ArcCore string `GOOGLE_API_KEY_PARTIAL_TRANSLATE`, page-platform PG-7.2);
/// Open translates the selected text on device with the same backend as page translation and
/// shows the result in a small popover with Copy. Look values are GUESS (no capture of Arc's bubble).
@MainActor
final class TranslateSelectionController {
  static let maxCharacters = 5000
  unowned let adapter: TranslateAdapter
  private(set) var popover: TranslateSelectionPanel?
  private var monitor: Any?
  private(set) var last: [String: Any] = [:]
  private var task: Task<Void, Never>?
  init(adapter: TranslateAdapter) { self.adapter = adapter }

  /// The user's first preferred language (the menu title names it).
  static var target: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }
  static var menuTitle: String { "Translate Selection to \(PageLanguageDetector.displayName(target))" }

  /// Where the context menu opened (the page view's coordinates): the popover's anchor.
  private var anchorPoint: NSPoint?
  private weak var anchorView: NSView?

  /// The selection's box in the page view (from the page, in Open's world): the arrow's target.
  private var selectionRect: NSRect?
  private weak var page: OEWebContent?

  func translate(_ raw: String, at point: NSPoint? = nil, in page: OEWebContent? = nil) {
    anchorPoint = point; anchorView = page?.view; self.page = page; selectionRect = nil
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
        await self.readSelectionRect()
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
    closePanel()
    guard let view = anchorView ?? adapter.factory.controller?.contentView, let window = view.window, window.isVisible else { last["shown"] = false; return }
    let content = TranslateSelectionView(result: result, message: message,
      sourceName: (last["source"] as? String).map { PageLanguageDetector.displayName(Locale.Language(identifier: $0)) },
      targetName: PageLanguageDetector.displayName(Self.target))
    // The whole panel stays inside the web content area (8 pt inset, LEAD 10:45); the arrow
    // points at the middle of the selection (or at the menu point when the page gives no box).
    let area = window.convertToScreen(view.convert(view.bounds, to: nil))
    let target: NSRect
    if let selectionRect { target = selectionRect.intersection(view.bounds).isEmpty ? selectionRect : selectionRect.intersection(view.bounds) }
    else { let p = anchorPoint ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY); target = NSRect(x: p.x, y: p.y, width: 0, height: 0) }
    let onScreen = window.convertToScreen(view.convert(target, to: nil))
    let panel = TranslateSelectionPanel(content: content, pointingAt: onScreen, inside: area.insetBy(dx: Self.inset, dy: Self.inset))
    window.addChildWindow(panel, ordered: .above)
    popover = panel
    last["anchorInPage"] = view !== adapter.factory.controller?.contentView
    last["shown"] = panel.isVisible
    // Transient like a popover: a click elsewhere, Esc or a scroll closes it.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
      guard let self, let panel = self.popover else { return event }
      if event.type == .keyDown { if event.keyCode == 53 { self.closePanel(); return nil }; return event }
      if event.window !== panel { self.closePanel() }
      return event
    }
  }
  static let inset: CGFloat = 8

  /// The selection's bounding box, read in Open's isolated world and mapped to the page view.
  private func readSelectionRect() async {
    guard let page, let view = anchorView else { return }
    let script = "(() => { const s = getSelection(); if (!s || !s.rangeCount) return null; const b = s.getRangeAt(0).getBoundingClientRect(); return (b.width || b.height) ? [b.left, b.top, b.width, b.height, innerWidth, innerHeight] : null; })()"
    guard let raw = try? await (page as any WebContent).evaluateJavaScript(script, in: .open), let values = raw as? [NSNumber], values.count == 6,
      values.allSatisfy({ $0.doubleValue.isFinite }), values[4].doubleValue > 0, values[5].doubleValue > 0 else { return }
    let sx = view.bounds.width / values[4].doubleValue, sy = view.bounds.height / values[5].doubleValue
    let x = values[0].doubleValue * sx, top = values[1].doubleValue * sy, w = values[2].doubleValue * sx, h = values[3].doubleValue * sy
    selectionRect = NSRect(x: x, y: view.isFlipped ? top : view.bounds.height - top - h, width: w, height: h)
  }

  private func closePanel() {
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    if let panel = popover { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    popover = nil
  }
  func close() { task?.cancel(); closePanel() }

  var state: [String: Any] {
    var out = last
    out["shown"] = popover?.isVisible == true
    out["popoverWindow"] = popover?.windowNumber ?? 0
    if let panel = popover, let view = anchorView, let window = view.window {
      func box(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
      out["panelFrame"] = box(panel.bodyFrameOnScreen)
      out["contentArea"] = box(window.convertToScreen(view.convert(view.bounds, to: nil)))
      out["arrowTipX"] = Double(panel.arrowTipOnScreen.x)
      out["selectionMidX"] = selectionRect.map { Double(window.convertToScreen(view.convert($0, to: nil)).midX) } ?? -1
      out["arrowUp"] = panel.arrowUp
    }
    out["menuTitle"] = Self.menuTitle
    if let view = popover?.content { out["shownText"] = view.resultField.stringValue }
    return out
  }
  func pressCopy() -> Bool {
    guard let view = popover?.content, !view.copyButton.isHidden else { return false }
    view.copyButton.performClick(nil); return true
  }
}

/// Open's own bubble (not NSPopover, which cannot be kept inside a view): a rounded body with
/// an arrow whose tip is at the middle of the selection, below it (above when there is no room).
@MainActor
final class TranslateSelectionPanel: NSPanel {
  static let arrowHeight: CGFloat = 8, arrowWidth: CGFloat = 16, corner: CGFloat = 10
  let content: TranslateSelectionView
  private(set) var arrowUp = true
  private(set) var arrowTipOnScreen = NSPoint.zero
  private(set) var bodyFrameOnScreen = NSRect.zero

  init(content: TranslateSelectionView, pointingAt target: NSRect, inside area: NSRect) {
    self.content = content
    let width = min(320, max(120, area.width))
    content.setWidth(width)
    let size = NSSize(width: width, height: content.fittingSize.height)
    // Below the selection when it fits (screen y grows up), else above.
    let below = target.minY - Self.arrowHeight - size.height >= area.minY
    arrowUp = below || target.maxY + Self.arrowHeight + size.height > area.maxY
    let tipX = min(max(target.midX, area.minX + Self.corner + Self.arrowWidth / 2), area.maxX - Self.corner - Self.arrowWidth / 2)
    var tipY = arrowUp ? target.minY : target.maxY
    tipY = arrowUp ? min(max(tipY, area.minY + Self.arrowHeight + size.height), area.maxY) : max(min(tipY, area.maxY - Self.arrowHeight - size.height), area.minY)
    let x = min(max(tipX - width / 2, area.minX), area.maxX - width)
    let bodyY = arrowUp ? tipY - Self.arrowHeight - size.height : tipY + Self.arrowHeight
    let frame = NSRect(x: x, y: arrowUp ? bodyY : bodyY - Self.arrowHeight, width: width, height: size.height + Self.arrowHeight)
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false; backgroundColor = .clear; hasShadow = true; isReleasedWhenClosed = false
    arrowTipOnScreen = NSPoint(x: tipX, y: tipY)
    bodyFrameOnScreen = NSRect(x: x, y: bodyY, width: width, height: size.height)
    let bubble = TranslateSelectionBubble(frame: NSRect(origin: .zero, size: frame.size))
    bubble.arrowUp = arrowUp; bubble.arrowX = tipX - x
    content.frame = NSRect(x: 0, y: arrowUp ? 0 : Self.arrowHeight, width: width, height: size.height)
    bubble.addSubview(content)
    contentView = bubble
  }
  override var canBecomeKey: Bool { false }
}

/// The bubble's shape: body plus arrow, in the window background colour with a hairline.
@MainActor
final class TranslateSelectionBubble: NSView {
  var arrowUp = true, arrowX: CGFloat = 0
  override func draw(_ dirtyRect: NSRect) {
    let a = TranslateSelectionPanel.arrowHeight, half = TranslateSelectionPanel.arrowWidth / 2
    let body = NSRect(x: 0.5, y: (arrowUp ? 0 : a) + 0.5, width: bounds.width - 1, height: bounds.height - a - 1)
    let path = NSBezierPath(roundedRect: body, xRadius: TranslateSelectionPanel.corner, yRadius: TranslateSelectionPanel.corner)
    let arrow = NSBezierPath()
    if arrowUp { arrow.move(to: NSPoint(x: arrowX - half, y: body.maxY)); arrow.line(to: NSPoint(x: arrowX, y: bounds.maxY - 0.5)); arrow.line(to: NSPoint(x: arrowX + half, y: body.maxY)) }
    else { arrow.move(to: NSPoint(x: arrowX - half, y: body.minY)); arrow.line(to: NSPoint(x: arrowX, y: 0.5)); arrow.line(to: NSPoint(x: arrowX + half, y: body.minY)) }
    arrow.close(); path.append(arrow)
    NSColor.windowBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
  }
}

/// The bubble's content: "French → English", the translation (selectable), Copy.
/// GUESS look: 13 pt text, 320 pt wide.
@MainActor
final class TranslateSelectionView: NSView {
  let header = NSTextField(labelWithString: "")
  let resultField = NSTextField(wrappingLabelWithString: "")
  let copyButton = NSButton(title: "Copy", target: nil, action: nil)
  private let result: String?
  private lazy var width = widthAnchor.constraint(equalToConstant: 320)
  func setWidth(_ value: CGFloat) { width.constant = value; resultField.preferredMaxLayoutWidth = value - 28; layoutSubtreeIfNeeded() }
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
                                 width])
    setAccessibilityIdentifier("translate-selection")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func copy(_ sender: Any?) {
    guard let result else { return }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
  }
}
