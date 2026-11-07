import AppKit
import CoreText

/// Recreated from page-chrome §1; no reference assets. The dedicated field
/// editor consumes navigation keys before the embedded page can see them.
@MainActor
class FindBarView: NSView, NSTextFieldDelegate {
  let field: NSTextField = FindQueryField()
  private var editorStorage: FindFieldEditor?
  private let search = NSImageView()
  private var results: FindResultsView?
  private let close = FindButton(symbol: "xmark", title: "Close Find")
  private let separator = CALayer()
  private var appliedDark: Bool?
  private var cachedTint: NSColor?
  var onEdit: ((String) -> Void)?
  var onAction: ((Int) -> Void)?
  var onClose: (() -> Void)?
  private(set) var active = 0
  private(set) var total = 0
  private(set) var notFound = false
  private(set) var hasResult = false
  private(set) var layoutCount = 0
  var countText: String { hasResult ? results?.text ?? "" : "" }
  var navigationVisible: Bool { hasResult && results?.navigationVisible == true }
  var separatorVisible: Bool { !separator.isHidden }
  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { false }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { applyColors() }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // The background needs no drawing context. Native controls own their
    // backing layers, so image views can submit cached symbol contents.
    wantsLayer = true
    layer?.cornerRadius = 5
    layer?.masksToBounds = false
    layer?.shadowRadius = 5
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    layer?.addSublayer(separator)
    (field.cell as? FindTextCell)?.editorProvider = { [weak self] in self?.makeEditor() }
    field.isEditable = true; field.isSelectable = true
    field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
    field.focusRingType = .none; field.font = FindBarResources.queryFont
    field.placeholderString = "Find in page..."
    field.cell?.isScrollable = true; field.cell?.wraps = false
    field.usesSingleLineMode = true; field.delegate = self
    field.setAccessibilityLabel("Find in page")
    search.image = FindBarResources.search
    search.imageScaling = .scaleNone
    for view in [search, field, close] { view.wantsLayer = true; addSubview(view) }
    close.onPress = { [weak self] in self?.onClose?() }
    update(active: 0, total: 0, final: false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// Prime native control/font/image caches after first paint. The temporary
  /// 300x32 surface never joins a window or becomes first responder.
  static func prewarmNativeControls() {
    FindBarResources.prepareAll()
    let bar = FindBarView(frame: CGRect(x: 0, y: 0, width: 300, height: 32))
    bar.setQuery("Find"); bar.update(active: 1, total: 5, final: true)
    _ = bar.makeEditor()
    #if OPEN_AUTOMATION
    FindBarPrewarm.observeTemporary(bar: bar, editor: bar.makeEditor())
    #endif
    bar.layoutSubtreeIfNeeded()
    if let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
      bar.cacheDisplay(in: bar.bounds, to: bitmap)
    }
    CATransaction.flush()
  }

  private func makeEditor() -> FindFieldEditor {
    if let editorStorage { return editorStorage }
    let editor = FindFieldEditor(usingTextLayoutManager: false); editorStorage = editor
    editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = true
    editor.drawsBackground = false
    editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isAutomaticTextCompletionEnabled = false; editor.inlinePredictionType = .no
    editor.writingToolsBehavior = .none
    editor.onAction = { [weak self] in self?.onAction?($0) }
    editor.onClose = { [weak self] in self?.onClose?() }
    return editor
  }

  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
  private func applyColors() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if appliedDark == dark, let cachedTint { results?.applyTint(cachedTint); return }
    appliedDark = dark
    let palette = dark ? FindBarResources.dark : FindBarResources.light
    layer?.backgroundColor = palette.background.cgColor
    layer?.shadowColor = FindBarResources.shadow.cgColor
    layer?.shadowOpacity = dark ? 0.80 : 0.30
    field.textColor = palette.text
    let tint = palette.tint
    cachedTint = tint
    search.contentTintColor = tint
    close.contentTintColor = tint; results?.applyTint(tint)
    separator.backgroundColor = FindBarResources.separator.cgColor
  }
  override func layout() {
    super.layout(); layoutCount += 1
    search.frame = CGRect(x: 3, y: 3, width: 26, height: 26)
    close.frame = CGRect(x: bounds.width - 29, y: 3, width: 26, height: 26)
    separator.frame = CGRect(x: close.frame.minX - 1.5, y: 7, width: 1, height: 18)
    var trailing = close.frame.minX - 5
    if hasResult, let results {
      let width = results.preferredWidth
      results.frame = CGRect(x: trailing - width, y: 3, width: width, height: 26)
      results.needsLayout = true; trailing -= width
    }
    field.frame = CGRect(x: 32, y: 7, width: max(0, trailing - 4 - 32), height: 18)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
  }
  func update(active: Int, total: Int, final: Bool) {
    self.active = max(0, active); self.total = max(0, total)
    hasResult = final && !field.stringValue.isEmpty
    notFound = hasResult && total == 0
    if hasResult {
      if results == nil {
        let group = FindResultsView(frame: .zero); results = group
        group.onAction = { [weak self] in self?.onAction?($0) }; addSubview(group)
      }
      results?.update(text: notFound ? "Not Found" : "\(self.active)/\(self.total)", notFound: notFound)
    }
    results?.isHidden = !hasResult
    separator.isHidden = !hasResult
    applyColors(); needsLayout = true
  }
  func setQuery(_ value: String) {
    guard field.stringValue != value else { return }
    field.stringValue = value; field.currentEditor()?.string = value
    editorStorage?.undoManager?.removeAllActions()
  }
  func focusQuery() {
    window?.makeFirstResponder(field); field.selectText(nil)
    (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: field.stringValue.utf16.count))
  }
  func owns(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    return responder === field || responder === field.currentEditor()
  }
  #if OPEN_AUTOMATION
  var controlGeometry: [String: Any] {
    func frame(_ view: NSView?) -> [CGFloat] {
      guard let view, view.window != nil else { return [] }
      let rect = view.convert(view.bounds, to: nil)
      return [rect.minX, rect.minY, rect.width, rect.height]
    }
    let rect = close.convert(close.bounds, to: nil)
    let point = NSPoint(x: rect.midX, y: rect.midY)
    let hit = window?.contentView.map { root in
      root.hitTest(root.superview?.convert(point, from: nil) ?? point)
    } ?? nil
    return ["close": frame(close), "query": frame(field), "editor": frame(field.currentEditor()),
      "cellClass": field.cell.map { String(describing: type(of: $0)) } ?? "none",
      "editorClass": field.currentEditor().map { String(describing: type(of: $0)) } ?? "none",
      "closeHit": hit.map { String(describing: type(of: $0)) } ?? "none", "closeHitMatches": hit === close]
  }
  #endif
  func controlTextDidChange(_ obj: Notification) { onEdit?(field.stringValue) }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)): onClose?()
    case #selector(NSResponder.insertNewline(_:)): onAction?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 3 : 2)
    case #selector(NSResponder.moveUp(_:)): onAction?(3)
    case #selector(NSResponder.moveDown(_:)): onAction?(2)
    default: return false
    }
    return true
  }
}

/// Results are absent from the empty state, so their controls and small-caps
/// font are created on the first result, outside the first Cmd+F commit.
@MainActor
private final class FindResultsView: NSView {
  private let count = NSTextField(labelWithString: "")
  private let previous = FindButton(symbol: "chevron.up", title: "Previous Match")
  private let next = FindButton(symbol: "chevron.down", title: "Next Match")
  private var notFound = false
  var onAction: ((Int) -> Void)?
  var text: String { count.stringValue }
  var navigationVisible: Bool { !next.isHidden }
  var preferredWidth: CGFloat { min(100, ceil(count.intrinsicContentSize.width)) + (navigationVisible ? 52 : 0) }
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    count.font = FindBarResources.countFont
    count.setAccessibilityLabel("Find matches")
    for view in [count, previous, next] { view.wantsLayer = true; addSubview(view) }
    previous.onPress = { [weak self] in self?.onAction?(3) }
    next.onPress = { [weak self] in self?.onAction?(2) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func update(text: String, notFound: Bool) {
    self.notFound = notFound; count.stringValue = text; count.setAccessibilityValue(text)
    previous.isHidden = notFound; next.isHidden = notFound; needsLayout = true
  }
  func applyTint(_ tint: NSColor) {
    previous.contentTintColor = tint; next.contentTintColor = tint
    count.textColor = notFound ? FindBarResources.error : tint
  }
  override func layout() {
    super.layout()
    let width = min(100, ceil(count.intrinsicContentSize.width))
    count.frame = CGRect(x: 0, y: 5, width: width, height: 17)
    previous.frame = CGRect(x: width, y: 0, width: 26, height: 26)
    next.frame = CGRect(x: width + 26, y: 0, width: 26, height: 26)
  }
}

@MainActor
private final class FindButton: NSButton {
  var onPress: (() -> Void)?
  init(symbol: String, title: String) {
    super.init(frame: .zero)
    image = FindBarResources.image(symbol)
    imagePosition = .imageOnly; imageScaling = .scaleNone; isBordered = false
    toolTip = title; setAccessibilityLabel(title); target = self; action = #selector(pressed)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func pressed() { onPress?() }
}

@MainActor
private final class FindQueryField: NSTextField {
  // Construct the right cell once; replacing a stock cell on first Cmd+F
  // would perform the native cell's initialization twice.
  override class var cellClass: AnyClass? { get { FindTextCell.self } set {} }
}

@MainActor
private final class FindTextCell: NSTextFieldCell {
  var editorProvider: (() -> NSTextView?)?
  override func fieldEditor(for controlView: NSView) -> NSTextView? { editorProvider?() }
}

@MainActor
private final class FindFieldEditor: NSTextView {
  var onAction: ((Int) -> Void)?
  var onClose: (() -> Void)?
  private let editingUndoManager = UndoManager()
  override var undoManager: UndoManager? { editingUndoManager }
  override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      switch event.keyCode {
      case 36, 76: onAction?(event.modifierFlags.contains(.shift) ? 3 : 2); return
      case 125: onAction?(2); return
      case 126: onAction?(3); return
      case 53: onClose?(); return
      default: break
      }
    }
    super.keyDown(with: event)
  }
  override func performFindPanelAction(_ sender: Any?) { onAction?((sender as? NSMenuItem)?.tag ?? 1) }
  override func performTextFinderAction(_ sender: Any?) { onAction?(1) }
  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(performFindPanelAction(_:)) || item.action == #selector(performTextFinderAction(_:)) { return true }
    return super.validateUserInterfaceItem(item)
  }
}

/// A bar-sized overlay anchored inside the actual page viewport. Frame/bounds
/// notifications follow pane chrome, toolbar and live resize without idle work.
@MainActor
final class FindPaneOverlay: FindBarView {
  var bar: FindBarView { self }
  private var geometryObservers: [any NSObjectProtocol] = []
  private(set) weak var viewport: NSView?
  override var isHidden: Bool {
    didSet { if isHidden { stopObserving() } else { observeGeometry(); updatePlacement() } }
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    // Resolve manual control frames before joining the window's layout tree.
    layoutSubtreeIfNeeded()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) } }
  func setViewport(_ view: NSView) {
    guard viewport !== view else { return }
    stopObserving(); viewport = view; observeGeometry(); updatePlacement()
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview(); stopObserving(); observeGeometry(); updatePlacement()
  }
  private func stopObserving() {
    for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
    geometryObservers.removeAll()
  }
  private func observeGeometry() {
    guard geometryObservers.isEmpty, !isHidden, let parent = superview, let viewport else { return }
    parent.postsFrameChangedNotifications = true
    viewport.postsFrameChangedNotifications = true; viewport.postsBoundsChangedNotifications = true
    for (name, view) in [(NSView.frameDidChangeNotification, parent), (NSView.frameDidChangeNotification, viewport),
                         (NSView.boundsDidChangeNotification, viewport)] {
      geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updatePlacement() }
      })
    }
  }
  func updatePlacement() {
    guard let parent = superview, let viewport else { return }
    let target = Self.placement(in: parent, viewport: viewport)
    if frame != target { frame = target; needsLayout = true }
  }
  static func placement(in parent: NSView, viewport: NSView) -> CGRect {
    let area = parent.convert(viewport.bounds, from: viewport)
    let width = min(300, max(0, area.width - 20))
    let y = parent.isFlipped ? area.minY + 10 : area.maxY - 10 - 32
    return CGRect(x: area.maxX - 10 - width, y: y, width: width, height: 32)
  }
}
