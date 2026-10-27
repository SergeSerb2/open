import AppKit
import OpenSettings

/// Event-driven tray over the same provider as Library (features-advanced DL-1).
/// Tray dimensions/colors are guesses; no Downloads capture was supplied.
@MainActor
final class DownloadsPopoverController: NSObject {
  weak var owner: EngineWebContentHostFactory?
  let button = PageChromeButton(symbol: "arrow.down.circle", title: "Downloads")
  private let popover = NSPopover()
  private let body = DownloadsBodyView()
  private(set) var rows: [DownloadItemSnapshot] = []
  init(owner: EngineWebContentHostFactory) {
    self.owner = owner
    super.init()
    let controller = NSViewController(); controller.view = body
    popover.contentViewController = controller; popover.animates = false; popover.behavior = .transient
    button.onPress = { [weak self] in self?.toggle() }
    body.onEscape = { [weak self] in self?.dismiss() }
  }
  func toggle() { if popover.isShown { popover.close() } else { show() } }
  func show() {
    guard let owner, owner.app.engineReady, !owner.isClosing, button.window != nil else { return }
    refresh(rebuild: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    body.window?.makeFirstResponder(body)
  }
  func refresh(rebuild: Bool = false) {
    guard let owner, owner.app.engineReady, !owner.isClosing else { rows = []; return }
    rows = owner.app.settingsPresenter.downloads.filter { $0.profileID == owner.focusedProfile?.id }
      .sorted { $0.startedAt > $1.startedAt }
    let active = rows.filter { $0.state == .inProgress || $0.state == .paused }.count
    button.toolTip = active == 0 ? "Downloads" : "Downloads (\(active) in progress)"
    guard popover.isShown || rebuild else { return }
    body.build(rows: Array(rows.prefix(20)), action: { [weak self] id, action in self?.perform(id: id, action: action) ?? false }, library: { [weak owner] in
      owner?.app.settingsPresenter.showLibrary(section: .downloads)
    })
    popover.contentSize = body.frame.size
  }
  @discardableResult func perform(id: String, action: String) -> Bool {
    guard let owner, owner.app.engineReady, !owner.isClosing, let row = rows.first(where: { $0.id == id }) else { return false }
    let adapter = owner.app.settingsPresenter
    switch action {
    case "pause": guard row.state == .inProgress else { return false }; adapter.pauseDownload(id: id)
    case "resume": guard row.state == .paused else { return false }; adapter.resumeDownload(id: id)
    case "cancel": guard row.state == .inProgress || row.state == .paused else { return false }; adapter.cancelDownload(id: id)
    case "reveal": guard row.state == .completed, let path = row.filePath, FileManager.default.fileExists(atPath: path) else { return false }; adapter.revealDownload(id: id)
    default: return false
    }
    refresh(); return true
  }
  func owns(_ window: NSWindow) -> Bool { popover.isShown && body.window === window }
  func dismiss() { popover.close() }
  func close() { dismiss(); rows = [] }
  var state: [String: Any] {
    refresh()
    let buttonFrame = owner?.controller.map { $0.contentView.convert(button.bounds, from: button) }
    return ["button": buttonFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [], "visible": popover.isShown, "profile": owner?.focusedProfile?.id.description ?? "", "rows": rows.map { row in
      ["id": row.id, "name": row.fileName, "host": row.sourceHost, "state": String(describing: row.state),
       "received": row.receivedBytes, "total": row.totalBytes ?? -1, "speed": row.bytesPerSecond,
       "path": row.filePath ?? ""] as [String: Any]
    }]
  }
}

@MainActor
private final class DownloadsBodyView: PageChromePopoverView {
  override var isFlipped: Bool { true }
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 140))
    appearance = NSAppearance(named: .darkAqua); wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func build(rows: [DownloadItemSnapshot], action: @escaping @MainActor (String, String) -> Bool, library: @escaping @MainActor () -> Void) {
    subviews.forEach { $0.removeFromSuperview() }
    let title = NSTextField(labelWithString: "Downloads"); title.font = .systemFont(ofSize: 14, weight: .semibold)
    title.frame = CGRect(x: 14, y: 12, width: 300, height: 22); addSubview(title)
    let height = min(320, max(54, rows.count * 66))
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 42, width: 340, height: height)); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    let document = DownloadsListView(frame: CGRect(x: 0, y: 0, width: 330, height: max(height, rows.count * 66)))
    scroll.documentView = document; addSubview(scroll)
    if rows.isEmpty {
      let empty = NSTextField(labelWithString: "No downloads"); empty.textColor = .secondaryLabelColor
      empty.frame = CGRect(x: 14, y: 12, width: 300, height: 24); document.addSubview(empty)
    }
    for (index, row) in rows.enumerated() {
      let y = CGFloat(index * 66)
      let name = NSTextField(labelWithString: row.fileName); name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
      name.toolTip = row.filePath
      name.frame = CGRect(x: 14, y: y + 4, width: 244, height: 18); document.addSubview(name)
      let bytes = ByteCountFormatter.string(fromByteCount: row.receivedBytes, countStyle: .file)
      let speed = row.bytesPerSecond > 0 ? " · \(ByteCountFormatter.string(fromByteCount: row.bytesPerSecond, countStyle: .file))/s" : ""
      let status = row.state == .completed ? "Completed" : row.state == .paused ? "Paused" : row.state == .cancelled ? "Cancelled" : row.state == .failed ? "Failed" : bytes + speed
      let subtitle = NSTextField(labelWithString: "\(row.sourceHost) · \(status)"); subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingMiddle
      subtitle.frame = CGRect(x: 14, y: y + 24, width: 244, height: 16); document.addSubview(subtitle)
      if row.state == .inProgress || row.state == .paused {
        let progress = NSProgressIndicator(frame: CGRect(x: 14, y: y + 47, width: 244, height: 4)); progress.isIndeterminate = row.totalBytes == nil
        progress.minValue = 0; progress.maxValue = Double(max(1, row.totalBytes ?? 1)); progress.doubleValue = Double(row.receivedBytes)
        document.addSubview(progress)
        if progress.isIndeterminate { progress.startAnimation(nil) }
      } else if let path = row.filePath {
        let location = NSTextField(labelWithString: path); location.font = .systemFont(ofSize: 10)
        location.textColor = .secondaryLabelColor; location.lineBreakMode = .byTruncatingMiddle; location.toolTip = path
        location.frame = CGRect(x: 14, y: y + 44, width: 244, height: 16); document.addSubview(location)
      }
      let actions: [(String, String, String)]
      switch row.state {
      case .inProgress: actions = [("pause", "pause.fill", "Pause"), ("cancel", "xmark", "Cancel")]
      case .paused: actions = [("resume", "play.fill", "Resume"), ("cancel", "xmark", "Cancel")]
      case .completed: actions = [("reveal", "magnifyingglass", "Show in Finder")]
      default: actions = []
      }
      for (i, item) in actions.enumerated() {
        let button = PageChromeButton(symbol: item.1, title: item.2)
        button.frame = CGRect(x: CGFloat(272 + i * 26), y: y + 12, width: 24, height: 28)
        button.onPress = { _ = action(row.id, item.0) }; document.addSubview(button)
      }
    }
    let all = PageChromeButton(title: "Show All Downloads")
    all.frame = CGRect(x: 14, y: CGFloat(height) + 51, width: 312, height: 28); all.onPress = library; addSubview(all)
    frame.size = NSSize(width: 340, height: CGFloat(height) + 92)
  }
}
@MainActor private final class DownloadsListView: NSView { override var isFlipped: Bool { true } }
