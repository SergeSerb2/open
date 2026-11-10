import AppKit
import OpenDesign
import OpenFeatures
import OpenSettings
import UniformTypeIdentifiers

/// LA-10 proves a shared downloads tray exists, not its geometry or colors.
/// Guess: reuse Little Open's compact native popover, spacing and typography.
@MainActor
final class LittleOpenDownloadsTray: NSViewController, NSPopoverDelegate {
  private weak var controller: LittleOpenWindowController?
  private unowned let center: DownloadsCenter
  private(set) var items: [DownloadItemSnapshot] = []
  private(set) var rows: [LittleOpenDownloadRow] = []
  private(set) var popover: NSPopover?
  private let scroll = NSScrollView()
  private let list = DownloadTrayList()
  private let heading = NSTextField(labelWithString: "Downloads")
  private static let width: CGFloat = 360
  private static let rowHeight: CGFloat = 68
  #if OPEN_AUTOMATION
  private(set) var updateCount = 0
  private(set) var handledKeys: [[String: Any]] = []
  #endif

  init(controller: LittleOpenWindowController, center: DownloadsCenter) {
    self.controller = controller; self.center = center
    super.init(nibName: nil, bundle: nil)
    controller.titleBar.onDownloads = { [weak self] in self?.toggle() }
    controller.onCloseDownloads = { [weak self] in self?.close(restoringFocus: false) }
    controller.onDownloadsKey = { [weak self] event in
      guard let self, self.popover?.isShown == true else { return false }
      return self.center.app.handleLittleOpenKey(event)
    }
    list.onEscape = { [weak self] in self?.close() }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    let root = DownloadTrayList(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
    root.wantsLayer = true
    // Lead design F6: exactly the Space picker's opaque title-bar surface.
    root.layer?.backgroundColor = LittleOpenMetrics.titleBarFill.cgColor
    root.appearance = NSAppearance(named: .darkAqua)
    root.onEscape = { [weak self] in self?.close() }
    root.onReturn = { [weak self] in self?.activateFocusedAction() }
    view = root
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    heading.frame = CGRect(x: 12, y: 10, width: Self.width - 24, height: 18)
    root.addSubview(heading)
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    scroll.documentView = list; root.addSubview(scroll)
  }
  func update(_ items: [DownloadItemSnapshot]) {
    guard self.items != items else { return }
    self.items = items
    #if OPEN_AUTOMATION
    updateCount += 1
    #endif
    guard let button = controller?.titleBar.downloadsButton else { return }
    let running = items.filter { $0.state == .inProgress }
    let paused = items.filter { $0.state == .paused }
    let total = running.reduce(0.0) { $0 + Double($1.totalBytes ?? 0) }
    let received = running.reduce(0.0) { $0 + Double($1.receivedBytes) }
    button.isHidden = items.isEmpty
    button.running = !running.isEmpty
    button.progress = running.contains { $0.totalBytes == nil } || total == 0 ? nil : min(1, received / total)
    let count = running.isEmpty ? (paused.isEmpty ? items.count : paused.count) : running.count
    let noun = count == 1 ? "download" : "downloads"
    let qualifier = !running.isEmpty ? "active " : !paused.isEmpty ? "paused " : ""
    let status = "\(count) \(qualifier)\(noun)"
    button.setAccessibilityValue(status)
    button.toolTip = "Downloads · " + status
    controller?.titleBar.needsLayout = true
    if items.isEmpty { close(restoringFocus: false) }
    if popover?.isShown == true { render() }
  }
  private func render() {
    _ = view
    let visible = Array(items.prefix(100))
    let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.id, $0) })
    let ids = Set(visible.map(\.id))
    let oldResponder = view.window?.firstResponder as? NSView
    for row in rows where !ids.contains(row.item.id) { row.removeFromSuperview() }
    rows = visible.map { item in
      let row = existing[item.id] ?? LittleOpenDownloadRow(item: item) { [weak self] action, id in
        guard let self else { return }
        switch action {
        case "Pause": center.pause(id)
        case "Resume": center.resume(id)
        case "Cancel": center.cancel(id)
        case "Open": center.fileAction("open", key: id)
        case "Show in Finder": center.fileAction("reveal", key: id)
        case "Retry": center.retry(id)
        default: break
        }
      }
      row.update(item)
      if row.superview == nil { list.addSubview(row) }
      return row
    }
    list.setAccessibilityChildren(rows)
    for (index, row) in rows.enumerated() {
      row.frame = CGRect(x: 12, y: CGFloat(index) * Self.rowHeight, width: Self.width - 24, height: Self.rowHeight)
    }
    list.frame = CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(rows.count) * Self.rowHeight)
    let height = CGFloat(min(5, rows.count)) * Self.rowHeight
    scroll.frame = CGRect(x: 0, y: 36, width: Self.width, height: height)
    preferredContentSize = CGSize(width: Self.width, height: 44 + height)
    view.frame.size = preferredContentSize
    popover?.contentSize = preferredContentSize
    view.layoutSubtreeIfNeeded()
    if let oldResponder, !oldResponder.isDescendant(of: view) { focusPrimaryAction() }
  }
  func toggle() {
    if popover?.isShown == true { close(); return }
    guard !items.isEmpty, let button = controller?.titleBar.downloadsButton else { return }
    center.refreshFiles()
    render()
    let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
    popover.delegate = self; popover.contentViewController = self
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.contentSize = preferredContentSize; self.popover = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    view.window?.makeKeyAndOrderFront(nil)
    focusPrimaryAction()
  }
  func ownsPopoverWindow(_ window: NSWindow?) -> Bool {
    guard let window, popover?.isShown == true else { return false }
    return viewIfLoaded?.window === window
  }
  private func focusPrimaryAction() {
    let responder: NSView = rows.lazy.flatMap(\.buttons).first(where: \.isEnabled).map { $0 as NSView } ?? view
    view.window?.makeFirstResponder(responder)
  }
  var accessibilityRowOrder: [String] {
    (list.accessibilityChildren() ?? []).compactMap { ($0 as? LittleOpenDownloadRow)?.item.id }
  }
  private func activateFocusedAction() {
    let focused = view.window?.firstResponder as? NSButton
    let primary = rows.lazy.flatMap(\.buttons).first(where: \.isEnabled)
    (focused?.isEnabled == true ? focused : primary)?.performClick(nil)
  }
  /// Like permission popovers, AppKit can leave the parent as keyWindow.
  func handleKey(_ event: NSEvent) -> Bool {
    guard popover?.isShown == true, event.type == .keyDown, [53, 36, 76].contains(event.keyCode),
      event.window === controller?.window || event.window === viewIfLoaded?.window,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    #if OPEN_AUTOMATION
    if handledKeys.count == 16 { handledKeys.removeFirst() }
    handledKeys.append(["code": event.keyCode, "path": event.window === controller?.window ? "parent" : "popover"])
    #endif
    if event.keyCode == 53 { close() } else { activateFocusedAction() }
    return true
  }
  func close(restoringFocus: Bool = true) {
    let wasShown = popover?.isShown == true
    let closing = popover; popover = nil; closing?.delegate = nil; closing?.close()
    rows.forEach { $0.removeFromSuperview() }; rows = []
    list.setAccessibilityChildren([])
    if wasShown && restoringFocus, let controller, let window = controller.window, window.isVisible {
      window.makeKeyAndOrderFront(nil)
      if !window.makeFirstResponder(controller.container) { window.makeFirstResponder(controller.titleBar.downloadsButton) }
    }
  }
  // An outside click keeps its new key window; explicit dismissal restores ours.
  func popoverDidClose(_ notification: Notification) { close(restoringFocus: false) }
}

@MainActor private final class DownloadTrayList: PageChromePopoverView {
  override var isFlipped: Bool { true }
  override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor final class LittleOpenDownloadRow: NSView {
  private(set) var item: DownloadItemSnapshot
  private let name = NSTextField(labelWithString: "")
  let icon = NSImageView()
  private let source = NSTextField(labelWithString: "")
  let status = NSTextField(labelWithString: "")
  private let track = CALayer(), fill = CALayer()
  private(set) var buttons: [NSButton] = []
  private var previousState: DownloadState?
  private var previousExtension: String?
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter
  }()
  private let action: (String, String) -> Void
  init(item: DownloadItemSnapshot, action: @escaping (String, String) -> Void) {
    self.item = item; self.action = action
    super.init(frame: .zero); wantsLayer = true
    setAccessibilityElement(true); setAccessibilityRole(.group)
    for field in [name, source, status] {
      field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; addSubview(field)
    }
    name.font = .systemFont(ofSize: 13, weight: .medium)
    icon.setAccessibilityElement(false); addSubview(icon)
    for field in [source, status] { field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor }
    for layer in [track, fill] { layer.cornerRadius = 1.5; self.layer?.addSublayer(layer) }
    update(item)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  func update(_ item: DownloadItemSnapshot) {
    guard previousState == nil || self.item != item else { return }
    self.item = item; name.stringValue = item.fileName; name.toolTip = item.fileName
    source.stringValue = item.sourceHost
    let ext = URL(fileURLWithPath: item.fileName).pathExtension
    if ext != previousExtension {
      previousExtension = ext
      icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
    switch item.state {
    case .inProgress:
      let bytes = Self.byteFormatter
      status.stringValue = bytes.string(fromByteCount: item.receivedBytes) + (item.totalBytes.map { " of " + bytes.string(fromByteCount: $0) } ?? "")
    case .paused: status.stringValue = "Paused"
    case .completed: status.stringValue = item.fileExists == false ? "File moved or deleted." : "Completed"
    case .cancelled: status.stringValue = "Cancelled"
    case .failed: status.stringValue = "Failed to Download"
    }
    setAccessibilityLabel([item.fileName, item.sourceHost, status.stringValue].joined(separator: ", "))
    if previousState != item.state {
      previousState = item.state; buttons.forEach { $0.removeFromSuperview() }; buttons = []
      switch item.state {
      case .inProgress: add("Pause", "pause.fill"); add("Cancel", "xmark")
      case .paused: add("Resume", "play.fill"); add("Cancel", "xmark")
      case .completed: add("Open", "arrow.up.forward.square"); add("Show in Finder", "magnifyingglass")
      case .failed: add("Retry", "arrow.clockwise")
      case .cancelled: break
      }
      setAccessibilityChildren(buttons)
    }
    for button in buttons { button.isEnabled = item.state != .completed || item.fileExists == true }
    needsLayout = true
  }
  private func add(_ title: String, _ symbol: String) {
    let button = NSButton(title: "", target: self, action: #selector(press(_:)))
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { button.image = image }
    else { button.title = title }
    button.identifier = .init(title); button.toolTip = title; button.setAccessibilityLabel(title + " " + item.fileName)
    button.setAccessibilityElement(true); button.setAccessibilityRole(.button)
    button.isBordered = false; button.imageScaling = .scaleProportionallyDown
    buttons.append(button); addSubview(button)
  }
  @objc private func press(_ button: NSButton) { action(button.identifier?.rawValue ?? "", item.id) }
  override func layout() {
    super.layout()
    let textX: CGFloat = 42
    let width = max(0, bounds.width - textX - CGFloat(buttons.count) * 28 - 8)
    icon.frame = CGRect(x: 0, y: 16, width: 32, height: 32)
    name.frame = CGRect(x: textX, y: 5, width: width, height: 17)
    source.frame = CGRect(x: textX, y: 24, width: width, height: 14)
    status.frame = CGRect(x: textX, y: 40, width: width, height: 14)
    for (index, button) in buttons.enumerated() { button.frame = CGRect(x: bounds.width - CGFloat(buttons.count - index) * 28, y: 20, width: 24, height: 24) }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    track.isHidden = item.state != .inProgress && item.state != .paused; fill.isHidden = track.isHidden
    track.backgroundColor = NSColor.quaternaryLabelColor.cgColor; fill.backgroundColor = NSColor.controlAccentColor.cgColor
    track.frame = CGRect(x: textX, y: 59, width: width, height: 3)
    fill.frame = CGRect(x: textX, y: 59, width: width * (item.progress ?? 0.05), height: 3)
    CATransaction.commit()
  }
}
