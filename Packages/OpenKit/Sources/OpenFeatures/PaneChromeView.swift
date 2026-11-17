import AppKit
import OpenDesign
import OpenModel
import OpenExtensionsUI
import OpenSidebar

@MainActor
final class ActionButton: NSButton {
    var perform: (() -> Void)?
    var circleFill: NSColor? { didSet { needsDisplay = true } }
    var dimsWhenDisabled = true
    var glyphPointSize: CGFloat = 16
    var glyphOffset = CGSize.zero
    var siteControlState: SiteControlButtonState? { didSet { if siteControlState != oldValue { needsDisplay = true } } }
    init(symbol: String, title: String, action: @escaping () -> Void) {
        super.init(frame: .zero); isBordered = false; image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imageScaling = .scaleProportionallyDown; self.title = ""; toolTip = title
        setAccessibilityLabel(title); target = self; self.action = #selector(invoke); perform = action
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let circleFill {
            circleFill.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: (bounds.width - bounds.height) / 2, dy: 0)).fill()
        }
        if let state = siteControlState, state != .rest {
            SiteControlGlyphView.draw(in: bounds, pointSize: glyphPointSize, isOpen: state.isOpen, isBoosted: state.isBoosted,
                tint: contentTintColor ?? .black); return
        }
        guard let source = image, let context = NSGraphicsContext.current?.cgContext else { return }
        let symbol = source.withSymbolConfiguration(.init(pointSize: glyphPointSize, weight: .regular)) ?? source
        let size = symbol.size
        let rect = backingAlignedRect(CGRect(x: (bounds.width - size.width) / 2 + glyphOffset.width,
                                             y: (bounds.height - size.height) / 2 + glyphOffset.height,
                                             width: size.width, height: size.height), options: .alignAllEdgesNearest)
        let tint = (contentTintColor ?? .black).withAlphaComponent(isEnabled || !dimsWhenDisabled ? (contentTintColor?.alphaComponent ?? 1) : 0.24)
        context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(tint.cgColor); context.fill(rect)
        context.endTransparencyLayer(); context.restoreGState()
    }
}

@MainActor
public final class PaneChromeView: NSView {
    weak var host: (any WebContentHost)?
    var onClose: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onURL: (() -> Void)?
    var onSiteControls: (() -> Void)?
    public var siteControlState = SiteControlButtonState.rest {
        didSet { buttons[4].siteControlState = siteControlState }
    }
    public var siteControlsAnchor: NSView { buttons[4] }
    /// F6: set by the window from the same rule as the sidebar button
    /// (`BrowserWindowController.siteControlsAvailable(tabID:)`), never decided here.
    public var siteControlsAvailable = false {
        didSet { if siteControlsAvailable != oldValue { buttons[4].isEnabled = onSiteControls != nil && siteControlsAvailable } }
    }
    @discardableResult public func pressSiteControls() -> Bool {
        guard buttons[4].isEnabled, !buttons[4].isHidden else { return false }
        buttons[4].performClick(nil); return true
    }
    /// After the copy button copied the URL; true when trackers were removed (Arc CC-31a).
    var onCopy: ((Bool) -> Void)?
    /// Right-click menu of the content toolbar (§4.6.2); pane bars have none.
    var toolbarMenu: (() -> NSMenu?)?
    /// A split pane's bar, or the optional content toolbar on a single pane (commandbar-completion
    /// §4.6.2, D8): the same bar without the split menu and close button, Site Control Center in the
    /// close button's place while the extensions slot is empty.
    public enum Role: Sendable { case pane, toolbar }
    public internal(set) var role = Role.pane
    /// Toolbar only: the full URL instead of the host (`open.advanced.showFullURLWithToolbar`, CC-37).
    public internal(set) var showsFullURL = false
    /// Bar color when the page reports none: the Space's light background, else white.
    var fallbackColor: NSColor = .white
    let label = NSTextField(labelWithString: "")
    private var buttons: [ActionButton] = []
    public var extensionsUI: ExtensionsUIContext? { didSet { if extensionsUI !== oldValue { extensionStrip?.removeFromSuperview(); extensionStrip = nil; needsLayout = true } } }
    public private(set) var extensionStrip: ExtensionStripView?
    private var reloadShowsStop: Bool?
    /// App permission popovers anchor to the toolbar URL area (S11).
    public var urlAreaFrame: CGRect { label.frame }
    public var isFocused = false { didSet { update() } }
    /// F0081: the focused pane shows every control; an unfocused pane shows back,
    /// forward, the copy button, the host, and Close (AX and pixels).
    private static let unfocusedControls: Set<Int> = [0, 1, 3, 6]
    public init() {
        super.init(frame: .zero); wantsLayer = true
        let specs = [("arrow.left", "Go back"), ("arrow.right", "Go forward"), ("arrow.clockwise", "Reload"),
                     ("link", "Copy Current URL"), ("slider.horizontal.2.square", "Site Control Center"),
                     ("square.split.2x1", "Split View Menu"), ("xmark", "Close This Pane")]
        for (i, spec) in specs.enumerated() {
            let button = ActionButton(symbol: spec.0, title: spec.1) { [weak self] in self?.press(i) }
            button.contentTintColor = NSColor.black.withAlphaComponent(0.55)
            if i == 0 || i == 1 { button.glyphPointSize = 14; button.glyphOffset = CGSize(width: 1, height: 1) }
            if i == 3 { button.glyphPointSize = 12; button.glyphOffset = CGSize(width: 1, height: 1); button.contentTintColor = .black.withAlphaComponent(0.60) }
            if i == 4 { button.glyphPointSize = 16; button.dimsWhenDisabled = false }
            if i == 2 { button.glyphPointSize = 14; button.glyphOffset = CGSize(width: 0, height: 1) }
            if i == 5 { button.glyphOffset = CGSize(width: 0, height: 1) }
            if i >= 5 { button.contentTintColor = .black.withAlphaComponent(0.59) }
            addSubview(button); buttons.append(button)
        }
        label.font = .systemFont(ofSize: 13); label.alignment = .center; label.textColor = .black.withAlphaComponent(0.6)
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    func update() {
        let background = (host?.pageBackgroundColor ?? fallbackColor).cgColor
        if layer?.backgroundColor != background { layer?.backgroundColor = background }
        let text = host?.currentURL?.absoluteString == "open://welcome" ? "Welcome to Open"
            : role == .toolbar && showsFullURL ? host?.currentURL?.absoluteString ?? ""
            : host?.currentURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        var layoutChanged = false
        if label.stringValue != text { label.stringValue = text; layoutChanged = true }
        for (i, b) in buttons.enumerated() {
            let hidden = role == .toolbar ? i >= 5 : !isFocused && !Self.unfocusedControls.contains(i)
            if b.isHidden != hidden { b.isHidden = hidden; layoutChanged = true }
        }
        let back = host?.canGoBack ?? false, forward = host?.canGoForward ?? false
        if buttons[0].isEnabled != back { buttons[0].isEnabled = back }
        if buttons[1].isEnabled != forward { buttons[1].isEnabled = forward }
        let siteAvailable = onSiteControls != nil && siteControlsAvailable
        if buttons[4].isEnabled != siteAvailable { buttons[4].isEnabled = siteAvailable }
        buttons[4].siteControlState = siteControlState
        let loading = host?.isLoading == true
        if reloadShowsStop != loading {
            buttons[2].image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: "Reload or Stop")
            reloadShowsStop = loading
        }
        // Metadata and warm selections often repeat identical inputs. Keep the
        // same pixels without rebuilding symbols or invalidating layout again.
        if layoutChanged { needsLayout = true }
    }
    public override func layout() {
        super.layout(); let w = bounds.width
        let stripStyle: ExtensionStripStyle = role == .toolbar ? .toolbar : .paneBar
        if extensionStrip?.style != stripStyle { extensionStrip?.removeFromSuperview(); extensionStrip = nil }
        if extensionStrip == nil, let extensionsUI {
            let strip = ExtensionStripView(style: stripStyle, context: extensionsUI)
            strip.onVisibilityChange = { [weak self] in self?.needsLayout = true }
            addSubview(strip); extensionStrip = strip
        }
        if let strip = extensionStrip {
            strip.frame = bounds; strip.isFocused = isFocused || role == .toolbar; strip.hasPage = host != nil
            strip.hostTextWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 13)]).width)
            strip.layoutSubtreeIfNeeded()
        }
        buttons[0].frame = SplitMetrics.back; buttons[1].frame = SplitMetrics.forward; buttons[2].frame = SplitMetrics.reload
        let toolbar = role == .toolbar, focused = isFocused || toolbar
        buttons[4].frame = toolbar ? ToolbarMetrics.siteControls(width: w, stripWidth: extensionStrip?.geometry.stripWidth ?? 0) : CGRect(x: w - 105, y: 2, width: 32, height: 28)
        buttons[5].frame = CGRect(x: w - 69, y: 4, width: 32, height: 24)
        buttons[6].frame = CGRect(x: w - 37, y: 4, width: 32, height: 24)
        // Centered group (F0081 AX): copy 24 · 3 · host · 3 · an empty 24 pt slot, so the
        // host sits on the bar's center line. Narrow panes truncate the host; with no room
        // for a few characters, the host and copy button hide. guess: no narrow capture.
        let left = (focused ? buttons[2].frame.maxX : buttons[1].frame.maxX) + SplitMetrics.barControlGap
        let stripLeft = extensionStrip?.showsActions == true ? extensionStrip?.geometry.frames.map(\.minX).min() : nil
        let right = min((focused ? buttons[4].frame.minX : buttons[6].frame.minX), stripLeft ?? .greatestFiniteMagnitude) - SplitMetrics.barControlGap
        let slot = SplitMetrics.hostSlot
        let text = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 13)]).width) + 4
        let box = min(text, right - left - 2 * slot)
        let fits = !label.stringValue.isEmpty && box >= SplitMetrics.hostMinimumWidth
        // Whole points keep the copy glyph sharp (AX frames are integral).
        let x = max(left + slot, min((w - box) / 2 - 2, right - slot - box)).rounded()
        // Tail truncation only when the host does not fit: the text field also truncates a
        // string that only just fits its box.
        label.lineBreakMode = box < text ? .byTruncatingTail : .byClipping
        label.frame = CGRect(x: x, y: 8, width: max(0, box), height: 16)
        buttons[3].frame = CGRect(x: x - 25, y: 4, width: 24, height: 24)
        // Both focus states show the host group, so room alone decides.
        label.isHidden = !fits; buttons[3].isHidden = !fits
    }
    private func press(_ i: Int) {
        switch i {
        case 0: host?.goBack()
        case 1: host?.goForward()
        case 2: if host?.isLoading == true { host?.stop() } else { host?.reload() }
        case 3:
            if let url = host?.currentURL {
                let (clean, removed) = URLCleaner.clean(url)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(clean.absoluteString, forType: .string); onCopy?(!removed.isEmpty)
            }
        case 4:
            if NSApp.currentEvent?.modifierFlags.contains(.option) != true { onSiteControls?() }
        case 5: onMenu?(buttons[5])
        case 6: onClose?()
        default: onURL?()
        }
        update()
    }
    public override func mouseDown(with event: NSEvent) { onURL?() }
    public override func menu(for event: NSEvent) -> NSMenu? { role == .toolbar ? toolbarMenu?() : super.menu(for: event) }
    /// Visible controls by tooltip, left to right (harness and automation).
    public var visibleControls: [String] { buttons.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }.compactMap(\.toolTip) }
    public func controlFrame(_ title: String) -> CGRect? { buttons.first { $0.toolTip == title }?.frame }
    public var displayedText: String { label.isHidden ? "" : label.stringValue }
}
