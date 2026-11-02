import AppKit
import OpenDesign

/// One target language in "Choose Another Language".
public struct TranslateLanguageOption: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// What the translate popover shows (page-platform §4.7.3). Plain values: OpenFeatures does not
/// import OpenTranslate; the App maps the session state to this.
public struct TranslatePopoverContent: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case offer, translating, translated }
    public var mode: Mode
    /// "Translate this page to English?" or "Translated from French." (PG-7.3).
    public var title: String
    /// The inline error line (12 pt, secondary color) under the title.
    public var error: String?
    public var languages: [TranslateLanguageOption]
    public var currentTarget: String
    public init(mode: Mode, title: String, error: String? = nil, languages: [TranslateLanguageOption] = [], currentTarget: String = "") {
        self.mode = mode; self.title = title; self.error = error; self.languages = languages; self.currentTarget = currentTarget
    }
}

public enum TranslatePopoverAction: Equatable, Sendable {
    case translate, showOriginal
    case chooseLanguage(String)
    case neverTranslate
    case languageSettings
}

/// The popover body: Site Control panel chrome (`PopoverShape` with the arrow up, popover
/// material, 1 px rim), width 300, padding 16, the title, an optional error line, and one row of
/// buttons: the primary ("Translate" / "Show Original", `Core.brandBlue`, 28 tall, radius 7) and
/// "Options" (a plain pull-down). Labels "Translate", "Show Original", "Options" are guesses
/// (inline strings, PG-7.3); the rest are Arc's strings.
@MainActor
public final class TranslatePopoverView: NSView {
    public private(set) var content: TranslatePopoverContent
    public var onAction: ((TranslatePopoverAction) -> Void)?
    /// Where the arrow tip points, in this view's coordinates (x only; the tip is at the top).
    public var arrowX: CGFloat = TranslateMetrics.width / 2 + TranslateMetrics.shadowMargin { didSet { needsLayout = true } }
    /// Offscreen renders cannot sample a material: draw `fallbackFill` instead.
    public var usesMaterial = true { didSet { effect.isHidden = !usesMaterial; needsDisplay = true } }

    private let effect = NSVisualEffectView()
    /// The shape in this (flipped) view's coordinates. The chrome is drawn in `draw(_:)` and the
    /// material is masked with a flipped mask image, so the arrow points up in a window and in an
    /// offscreen render alike (layer paths do not follow the view's flip in every host).
    private var shape: CGPath?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    let primary = TranslatePopoverButton(primary: true)
    let options = TranslatePopoverButton(primary: false)
    private let spinner = NSProgressIndicator()

    public init(content: TranslatePopoverContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = PopoverMaterial.material; effect.blendingMode = .behindWindow; effect.state = .active
        addSubview(effect)
        for label in [titleLabel, errorLabel] { label.isSelectable = false; label.drawsBackground = false; label.isBordered = false; addSubview(label) }
        titleLabel.font = Typography.translateTitle.font
        titleLabel.textColor = .labelColor
        errorLabel.font = Typography.translateError.font
        errorLabel.textColor = Core.foregroundSecondary.nsColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        addSubview(primary); addSubview(options); addSubview(spinner)
        primary.onPress = { [weak self] in
            guard let self else { return }
            self.onAction?(self.content.mode == .translated ? .showOriginal : .translate)
        }
        options.onPress = { [weak self] in self?.showOptions() }
        options.title = "Options"
        options.showsChevron = true
        setAccessibilityElement(true); setAccessibilityRole(.popover)
        apply(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let shape, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let appearance = ContentAppearance(effectiveAppearance)
        // Shadow outside the shape only (the material inside stays clear of it).
        ctx.saveGState()
        ctx.addRect(bounds); ctx.addPath(shape); ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -PopoverMaterial.shadowOffsetY), blur: PopoverMaterial.shadowRadius * 2,
                      color: NSColor.black.withAlphaComponent(CGFloat(PopoverMaterial.shadowOpacity)).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        if !usesMaterial {
            ctx.addPath(shape)
            ctx.setFillColor((appearance == .dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor)
            ctx.fillPath()
        }
    }

    /// The 1 px rim draws above the material (the effect view is a subview).
    private lazy var rimView: RimView = { let v = RimView(); addSubview(v, positioned: .above, relativeTo: effect); return v }()

    public func apply(_ content: TranslatePopoverContent) {
        self.content = content
        titleLabel.stringValue = content.title
        errorLabel.stringValue = content.error ?? ""
        errorLabel.isHidden = content.error == nil
        primary.title = content.mode == .translated ? "Show Original" : "Translate"
        primary.isEnabled = content.mode != .translating
        if content.mode == .translating { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityLabel(content.title)
        needsLayout = true
    }

    /// Body height for the current content (the panel adds the arrow and the shadow margin).
    public var bodyHeight: CGFloat {
        let m = TranslateMetrics.self, w = m.width - 2 * m.padding
        var h = m.padding + titleLabel.sizeThatFits(CGSize(width: w, height: 1000)).height
        if content.error != nil { h += m.errorTopGap + errorLabel.sizeThatFits(CGSize(width: w, height: 1000)).height }
        return h + m.titleToButtons + m.buttonHeight + m.padding
    }
    /// The whole view: body, arrow, and the shadow margin on every side.
    public var preferredSize: CGSize {
        let m = TranslateMetrics.self
        return CGSize(width: m.width + 2 * m.shadowMargin, height: bodyHeight + m.arrowHeight + 2 * m.shadowMargin)
    }
    public var bodyFrame: CGRect {
        let m = TranslateMetrics.self
        return CGRect(x: m.shadowMargin, y: m.shadowMargin + m.arrowHeight, width: m.width, height: bodyHeight)
    }

    public override func layout() {
        super.layout()
        let m = TranslateMetrics.self, body = bodyFrame
        let tip = CGPoint(x: min(max(arrowX, body.minX + m.cornerRadius + 16), body.maxX - m.cornerRadius - 16), y: m.shadowMargin)
        // In flipped coordinates the tip (small y) sits above the body: the arrow points up.
        let path = PopoverShape.path(body: body, arrowTip: tip, radius: m.cornerRadius)
        if shape != path {
            shape = path
            effect.frame = bounds
            effect.maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                NSColor.black.setFill(); NSBezierPath(cgPath: path).fill(); return true
            }
            needsDisplay = true
        }
        rimView.frame = bounds; rimView.shape = path
        rimView.color = SiteControlColors.rim.resolved(ContentAppearance(effectiveAppearance)).nsColor
        let w = m.width - 2 * m.padding
        var y = body.minY + m.padding
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: w, height: 1000)).height
        titleLabel.frame = CGRect(x: body.minX + m.padding, y: y, width: w, height: titleHeight)
        y += titleHeight
        if content.error != nil {
            y += m.errorTopGap
            let h = errorLabel.sizeThatFits(CGSize(width: w, height: 1000)).height
            errorLabel.frame = CGRect(x: body.minX + m.padding, y: y, width: w, height: h); y += h
        }
        y += m.titleToButtons
        let pw = primary.preferredWidth, ow = options.preferredWidth
        primary.frame = CGRect(x: body.minX + m.padding, y: y, width: pw, height: m.buttonHeight)
        options.frame = CGRect(x: primary.frame.maxX + m.buttonGap, y: y, width: ow, height: m.buttonHeight)
        spinner.frame = CGRect(x: body.maxX - m.padding - 16, y: y + (m.buttonHeight - 16) / 2, width: 16, height: 16)
    }

    // MARK: Options (§4.7.3)

    /// "Choose Another Language" ▸ (each supported target, the current one checked) · "Never
    /// Translate This Site" · separator · "Language Settings…".
    public func optionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let choose = NSMenuItem(title: "Choose Another Language", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.autoenablesItems = false
        for option in content.languages {
            let item = FeatureMenuItem(option.name) { [weak self] in self?.onAction?(.chooseLanguage(option.id)) }
            item.state = option.id == content.currentTarget ? .on : .off
            item.representedObject = option.id
            sub.addItem(item)
        }
        choose.submenu = sub; choose.isEnabled = !content.languages.isEmpty
        menu.addItem(choose)
        menu.addItem(FeatureMenuItem("Never Translate This Site") { [weak self] in self?.onAction?(.neverTranslate) })
        menu.addItem(.separator())
        menu.addItem(FeatureMenuItem("Language Settings…") { [weak self] in self?.onAction?(.languageSettings) })
        return menu
    }
    public private(set) var openOptionsMenu: NSMenu?
    private func showOptions() {
        let menu = optionsMenu(); openOptionsMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: options.frame.minX, y: options.frame.maxY + 4), in: self)
        openOptionsMenu = nil
    }

    /// Presses a button the way a click does (automation and checks).
    @discardableResult public func press(_ action: TranslatePopoverAction) -> Bool {
        switch action {
        case .translate, .showOriginal:
            let expected: TranslatePopoverAction = content.mode == .translated ? .showOriginal : .translate
            guard expected == action, primary.isEnabled else { return false }
            primary.onPress?(); return true
        default:
            guard let item = Self.find(action, in: optionsMenu()) else { return false }
            (item as? FeatureMenuItem)?.perform?(); return true
        }
    }
    private static func find(_ action: TranslatePopoverAction, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            switch action {
            case .neverTranslate where item.title == "Never Translate This Site": return item
            case .languageSettings where item.title == "Language Settings…": return item
            case .chooseLanguage(let id): if let found = item.submenu?.items.first(where: { $0.representedObject as? String == id }) { return found }
            default: break
            }
        }
        return nil
    }
    public var buttonTitles: [String] { [primary.title, options.title] }
    public var primaryFrame: CGRect { primary.frame }
    public var titleText: String { titleLabel.stringValue }
    public var errorText: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
}

@MainActor
private final class RimView: NSView {
    var shape: CGPath? { didSet { needsDisplay = true } }
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let shape, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(shape); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }
}

/// A popover button: the primary fills `Core.brandBlue` with white 13 pt Medium text; the plain
/// one draws only its title (and a chevron for the pull-down).
@MainActor
final class TranslatePopoverButton: NSView {
    let isPrimary: Bool
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var showsChevron = false
    var isEnabled = true { didSet { needsDisplay = true; setAccessibilityEnabled(isEnabled) } }
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(primary: Bool) {
        isPrimary = primary
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Typography.translateButton.font,
         .foregroundColor: isPrimary ? NSColor.white : NSColor.labelColor.withAlphaComponent(isEnabled ? 0.85 : 0.4)]
    }
    var preferredWidth: CGFloat {
        let text = ceil((title as NSString).size(withAttributes: attributes).width)
        return text + 2 * TranslateMetrics.buttonPaddingX + (showsChevron ? 12 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPrimary {
            let path = NSBezierPath(roundedRect: bounds, xRadius: TranslateMetrics.buttonRadius, yRadius: TranslateMetrics.buttonRadius)
            Core.brandBlue.resolved(.light).nsColor.withAlphaComponent(isEnabled ? (pressed ? 0.8 : 1) : 0.5).setFill()
            path.fill()
        } else if pressed {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: TranslateMetrics.buttonRadius, yRadius: TranslateMetrics.buttonRadius).fill()
        }
        let size = (title as NSString).size(withAttributes: attributes)
        let x = showsChevron ? TranslateMetrics.buttonPaddingX : (bounds.width - size.width) / 2
        (title as NSString).draw(at: CGPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if showsChevron {
            let c = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            c?.isTemplate = true
            if let c {
                let r = CGRect(x: x + size.width + 5, y: (bounds.height - c.size.height) / 2, width: c.size.width, height: c.size.height)
                NSColor.labelColor.withAlphaComponent(0.6).set()
                c.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let was = pressed; pressed = false
        if was, inside, isEnabled { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; onPress?(); return true }
}

/// Presents `TranslatePopoverView` in a borderless child panel of the browser window, so it shows
/// above Chrome-style pages (they are child windows too). The panel never becomes key: keys keep
/// their window paths, and the App routes Esc and Return here through
/// `BrowserWindowController.keyInterceptor`. A click outside the panel and its anchor closes it.
@MainActor
public final class TranslatePopoverController {
    public let view: TranslatePopoverView
    public private(set) var isPresented = false
    public var onDismiss: (() -> Void)?
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var anchor: CGRect = .zero
    private var monitor: Any?

    public init(content: TranslatePopoverContent) { view = TranslatePopoverView(content: content) }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// `anchor` is in the parent's window coordinates; the arrow points at its bottom center.
    public func present(in parent: NSWindow, anchor: CGRect) {
        self.parent = parent; self.anchor = anchor
        let panel = self.panel ?? {
            let p = PopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.becomesKeyOnlyIfNeeded = true; p.hidesOnDeactivate = false
            p.contentView = view
            self.panel = p; return p
        }()
        layout()
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        isPresented = true
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented, let parent = self.parent else { return }
                    if event.window === self.panel { return }
                    let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
                    let anchorOnScreen = parent.convertToScreen(self.anchor)
                    if !anchorOnScreen.contains(screen) { self.dismiss() }
                }
                return event
            }
        }
    }

    public func update(_ content: TranslatePopoverContent) {
        view.apply(content)
        if isPresented { layout() }
    }

    private func layout() {
        guard let parent, let panel else { return }
        let size = view.preferredSize, m = TranslateMetrics.self
        let a = parent.convertToScreen(anchor)
        // Inside the browser window (8 pt margin, like the Site Control panel), and on its screen.
        let screen = parent.screen?.visibleFrame ?? parent.frame
        let visible = parent.frame.intersection(screen).isNull ? parent.frame : parent.frame.intersection(screen)
        var x = a.midX - size.width / 2
        x = min(max(x, visible.minX + 8 - m.shadowMargin), visible.maxX - size.width - 8 + m.shadowMargin)
        let top = a.minY - m.anchorGap + m.shadowMargin
        panel.setFrame(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.arrowX = a.midX - x
        view.layoutSubtreeIfNeeded()
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        onDismiss?()
    }

    /// Esc closes; Return presses the primary button (§4.7.3 "Close: Esc, click outside, or any action").
    public func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented, event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        if event.keyCode == 53 { dismiss(); return true }
        if event.keyCode == 36 || event.keyCode == 76 {
            _ = view.press(view.content.mode == .translated ? .showOriginal : .translate); return true
        }
        return false
    }
    public var panelFrame: CGRect? { isPresented ? panel?.frame : nil }
    public var panelWindowNumber: Int? { isPresented ? panel?.windowNumber : nil }
    /// The panel is on screen in front of its browser window (the window server's order, front to back).
    public var isAboveParent: Bool { stacking.panel.map { p in stacking.parent.map { p < $0 } ?? false } ?? false }
    /// Positions in the window server's on-screen list, front to back (nil when not on screen).
    public var stacking: (panel: Int?, parent: Int?) {
        guard isPresented, let panel, let parent, panel.isVisible else { return (nil, nil) }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        return (order.firstIndex(of: panel.windowNumber), order.firstIndex(of: parent.windowNumber))
    }
}

private final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
