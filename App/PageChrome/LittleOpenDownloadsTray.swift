import AppKit
import OpenDesign
import OpenFeatures
import OpenSettings

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

  init(controller: LittleOpenWindowController, center: DownloadsCenter) {
    self.controller = controller; self.center = center
    super.init(nibName: nil, bundle: nil)
    controller.titleBar.onDownloads = { [weak self] in self?.toggle() }
    list.onEscape = { [weak self] in self?.close() }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    let root = DownloadTrayList(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
    root.wantsLayer = true
    root.onEscape = { [weak self] in self?.close() }
    view = root
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    heading.frame = CGRect(x: 12, y: 10, width: Self.width - 24, height: 18)
    root.addSubview(heading)
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    scroll.documentView = list; root.addSubview(scroll)
  }
  func update(_ items: [DownloadItemSnapshot]) {
    self.items = items
    guard let button = controller?.titleBar.downloadsButton else { return }
    let running = items.filter { $0.state == .inProgress || $0.state == .paused }
    let total = running.reduce(0.0) { $0 + Double($1.totalBytes ?? 0) }
    let received = running.reduce(0.0) { $0 + Double($1.receivedBytes) }
    button.isHidden = items.isEmpty
    button.running = !running.isEmpty
    button.progress = running.contains { $0.totalBytes == nil } || total == 0 ? nil : min(1, received / total)
    let count = running.isEmpty ? items.count : running.count
    let noun = count == 1 ? "download" : "downloads"
    let status = running.isEmpty ? "\(count) \(noun)" : "\(count) active \(noun)"
    button.setAccessibilityValue(status)
    button.toolTip = "Downloads · " + status
    controller?.titleBar.needsLayout = true
    if items.isEmpty { close() }
    if popover?.isShown == true { render() }
  }
  private func render() {
    _ = view
    let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.id, $0) })
    let ids = Set(items.map(\.id))
    for row in rows where !ids.contains(row.item.id) { row.removeFromSuperview() }
    rows = items.map { item in
      let row = existing[item.id] ?? LittleOpenDownloadRow(item: item) { [weak self] action, id in
        guard let self else { return }
        switch action {
        case "Pause": center.pause(id)
        case "Resume": center.resume(id)
        case "Cancel": center.cancel(id)
        case "Open": center.fileAction("open", key: id)
        case "Show in Finder": center.fileAction("reveal", key: id)
        default: break
        }
      }
      row.update(item)
      if row.superview == nil { list.addSubview(row) }
      return row
    }
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
  }
  func toggle() {
    if popover?.isShown == true { close(); return }
    guard !items.isEmpty, let button = controller?.titleBar.downloadsButton, let window = controller?.window else { return }
    center.refreshFiles()
    render()
    let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
    popover.delegate = self; popover.contentViewController = self
    // Native semantic colors follow the owning window. The title bar itself
    // retains its established solid dark design, as the Space picker does.
    popover.appearance = window.appearance
    popover.contentSize = preferredContentSize; self.popover = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    view.window?.makeKeyAndOrderFront(nil)
    view.window?.makeFirstResponder(view)
  }
  /// Like permission popovers, AppKit can leave the parent as keyWindow.
  func handleKey(_ event: NSEvent) -> Bool {
    guard popover?.isShown == true, event.type == .keyDown, event.keyCode == 53,
      event.window === controller?.window || event.window === viewIfLoaded?.window,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    close(); return true
  }
  func close() {
    let closing = popover; popover = nil; closing?.delegate = nil; closing?.close()
    rows.forEach { $0.removeFromSuperview() }; rows = []
  }
  func popoverDidClose(_ notification: Notification) { close() }
}

@MainActor private final class DownloadTrayList: PageChromePopoverView {
  override var isFlipped: Bool { true }
  override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor final class LittleOpenDownloadRow: NSView {
  private(set) var item: DownloadItemSnapshot
  private let name = NSTextField(labelWithString: "")
  private let source = NSTextField(labelWithString: "")
  let status = NSTextField(labelWithString: "")
  private let track = CALayer(), fill = CALayer()
  private(set) var buttons: [NSButton] = []
  private var previousState: DownloadState?
  private let action: (String, String) -> Void
  init(item: DownloadItemSnapshot, action: @escaping (String, String) -> Void) {
    self.item = item; self.action = action
    super.init(frame: .zero); wantsLayer = true
    setAccessibilityElement(true); setAccessibilityRole(.group)
    for field in [name, source, status] {
      field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; addSubview(field)
    }
    name.font = .systemFont(ofSize: 13, weight: .medium)
    for field in [source, status] { field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor }
    for layer in [track, fill] { layer.cornerRadius = 1.5; self.layer?.addSublayer(layer) }
    update(item)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  func update(_ item: DownloadItemSnapshot) {
    self.item = item; name.stringValue = item.fileName; name.toolTip = item.fileName
    source.stringValue = item.sourceHost
    switch item.state {
    case .inProgress:
      let bytes = ByteCountFormatter(); bytes.countStyle = .file
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
      case .failed, .cancelled: break
      }
    }
    for button in buttons { button.isEnabled = item.state != .completed || item.fileExists == true }
    needsLayout = true
  }
  private func add(_ title: String, _ symbol: String) {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: #selector(press(_:)))
    button.identifier = .init(title); button.toolTip = title; button.setAccessibilityLabel(title + " " + item.fileName)
    button.isBordered = false; button.imageScaling = .scaleProportionallyDown
    buttons.append(button); addSubview(button)
  }
  @objc private func press(_ button: NSButton) { action(button.identifier?.rawValue ?? "", item.id) }
  override func layout() {
    super.layout()
    let width = max(0, bounds.width - CGFloat(buttons.count) * 28 - 8)
    name.frame = CGRect(x: 0, y: 5, width: width, height: 17)
    source.frame = CGRect(x: 0, y: 24, width: width, height: 14)
    status.frame = CGRect(x: 0, y: 40, width: width, height: 14)
    for (index, button) in buttons.enumerated() { button.frame = CGRect(x: bounds.width - CGFloat(buttons.count - index) * 28, y: 20, width: 24, height: 24) }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    track.isHidden = item.state != .inProgress && item.state != .paused; fill.isHidden = track.isHidden
    track.backgroundColor = NSColor.quaternaryLabelColor.cgColor; fill.backgroundColor = NSColor.controlAccentColor.cgColor
    track.frame = CGRect(x: 0, y: 59, width: width, height: 3)
    fill.frame = CGRect(x: 0, y: 59, width: width * (item.progress ?? 0.05), height: 3)
    CATransaction.commit()
  }
}
