import AppKit

@MainActor
final class UpdateColumnView: NSView {
  let icon = NSImageView()
  let product = NSTextField(labelWithString: "Open")
  let version = NSTextField(labelWithString: "")
  let prompt = NSTextField(wrappingLabelWithString: "")
  let progress = NSProgressIndicator()
  let primary = NSButton(title: "", target: nil, action: nil)
  let secondary = NSButton(title: "", target: nil, action: nil)
  var status = false
  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.image = NSApp.applicationIconImage; icon.imageScaling = .scaleProportionallyUpOrDown
    product.font = .boldSystemFont(ofSize: 17)
    version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
    prompt.font = .systemFont(ofSize: 12); prompt.textColor = .secondaryLabelColor
    for label in [product, version, prompt] { label.alignment = .center }
    progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
    secondary.isHidden = true
    for button in [primary, secondary] {
      button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13, weight: .medium)
      button.wantsLayer = true; button.layer?.cornerRadius = 8
    }
    for view in [icon, product, version, prompt, progress, primary, secondary] as [NSView] { addSubview(view) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    for button in [primary, secondary] { button.bezelColor = dark ? .black : .white }
    if primary.keyEquivalent == "\r" { primary.bezelColor = .controlAccentColor }
  }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 103, y: 32, width: 64, height: 64)
    product.frame = NSRect(x: 32, y: 108, width: 206, height: 23)
    version.frame = NSRect(x: 32, y: 137, width: 206, height: 18)
    prompt.frame = NSRect(x: 20, y: status ? 157 : 175, width: 230, height: status ? 38 : 65)
    progress.frame = NSRect(x: 32, y: 207, width: 206, height: 16)
    let width = min(230, max(100, primary.intrinsicContentSize.width + 16))
    primary.frame = NSRect(x: (270-width)/2, y: bounds.height - 48, width: width, height: 28)
    secondary.frame = NSRect(x: 55, y: bounds.height - 86, width: 160, height: 28)
  }
}

@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
  let column = UpdateColumnView()
  private(set) var notes: UpdateReleaseNotesView?
  var onPrimary: (() -> Void)?
  var onSecondary: (() -> Void)?
  var onClose: (() -> Void)?
  private var closing = false
  private var centered = false
  private var closeQueued = false
  var allowsClose = true

  init(title: String, status: Bool = false, closable: Bool = true) {
    var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
    if closable { style.insert(.closable) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 270, height: 334),
      styleMask: style, backing: .buffered, defer: false)
    window.title = title; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true; window.isReleasedWhenClosed = false
    if status { window.hidesOnDeactivate = true; window.level = .floating }
    super.init(window: window)
    column.status = status; window.contentView = column; window.delegate = self
    column.primary.target = self; column.primary.action = #selector(primary)
    column.secondary.target = self; column.secondary.action = #selector(secondary)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func show() {
    if !centered { window?.center(); centered = true }
    showWindow(nil); window?.makeKeyAndOrderFront(nil)
  }
  func addNotes(title: String, source: String, format: String, openLink: @escaping (URL) -> Void) {
    guard let window else { return }
    let panel = UpdateReleaseNotesView(title: title, source: source, format: format)
    panel.openLink = openLink; notes = panel
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 692, height: 418))
    column.removeFromSuperview(); root.addSubview(column); root.addSubview(panel)
    column.frame = NSRect(x: 0, y: 0, width: 270, height: 418)
    panel.frame = NSRect(x: 282, y: 12, width: 398, height: 394)
    // Assigning contentView resizes it to the old content size. Keep the target
    // dimensions separate so the notes panel is not left outside the window.
    window.contentView = root; window.setContentSize(NSSize(width: 692, height: 418))
  }
  func closeSilently() {
    closing = true; column.progress.stopAnimation(nil); close()
    onPrimary = nil; onSecondary = nil; onClose = nil
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closing else { return true }
    guard allowsClose, !closeQueued, let onClose else { return false }
    closeQueued = true
    // A delegate must not destroy its window inside AppKit's close callback.
    DispatchQueue.main.async { onClose() }
    return false
  }
  @objc private func primary() { let action = onPrimary; DispatchQueue.main.async { action?() } }
  @objc private func secondary() { let action = onSecondary; DispatchQueue.main.async { action?() } }
}
