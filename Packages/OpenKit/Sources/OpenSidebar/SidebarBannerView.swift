import AppKit
import OpenDesign
import OpenModel

/// Education card; the App sets SidebarContext.autoArchiveBannerRequested after
/// a real sweep. Dismissal/persistence and opening Settings are App intents.
@MainActor
public final class SidebarBannerView: NSView, NSTextViewDelegate {
    public let context: SidebarContext
    private let title = TextLabel()
    public let messageView = BannerMessageView()
    public let dismissButton = NSButton(title: "Got it", target: nil, action: nil)
    public var onHeightChange: (@MainActor () -> Void)?
    private var loop: ObservationLoop?
    private var cachedWidth: CGFloat = -1
    private var cachedHeight: CGFloat = 0
    private var cachedMessage = ""

    public init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = BannerMetrics.radius; layer?.cornerCurve = .continuous
        title.text = { "We cleaned up!" }; title.font = .systemFont(ofSize: BannerMetrics.titleSize, weight: .semibold); title.baseline = 14
        messageView.isEditable = false; messageView.isSelectable = true; messageView.drawsBackground = false
        messageView.textContainerInset = .zero; messageView.textContainer?.lineFragmentPadding = 0
        messageView.isVerticallyResizable = false; messageView.isHorizontallyResizable = false
        messageView.delegate = self
        dismissButton.isBordered = false; dismissButton.bezelStyle = .rounded; dismissButton.font = .systemFont(ofSize: BannerMetrics.messageSize, weight: .medium)
        dismissButton.wantsLayer = true; dismissButton.layer?.cornerRadius = 12
        dismissButton.target = self; dismissButton.action = #selector(dismissBanner)
        for view in [title, messageView, dismissButton] { addSubview(view) }
        loop = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.focusedSpace?.profileID; _ = self.context.focusedSpace?.theme; _ = self.context.systemAppearance
            _ = self.profile?.settings.autoArchiveAfter
        }) { [weak self] in self?.refresh() }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loop?.cancel() }
    public override var isFlipped: Bool { true }
    private var profile: Profile? { context.focusedSpace.flatMap { context.model.profile(id: $0.profileID) } }
    public var thresholdText: String? {
        guard let threshold = profile?.settings.autoArchiveAfter else { return nil }
        switch threshold {
        case .never: return nil
        case .oneHour: return "1 hour"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }
    public var message: String { "Open archives tabs that you haven't used in the past \(thresholdText ?? ""). You can adjust this in Settings." }
    private func refresh() {
        guard let space = context.focusedSpace else { return }
        let style = context.style(for: space), appearance = context.appearance(for: space)
        self.appearance = appearance.nsAppearance
        layer?.backgroundColor = style.selectedFill(appearance).cgColor
        SelectionShadow.apply(to: layer!, appearance: appearance)
        title.color = { style.titleColor(appearance).nsColor }
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = BannerMetrics.lineHeight; paragraph.maximumLineHeight = BannerMetrics.lineHeight
        let string = NSMutableAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: BannerMetrics.messageSize), .foregroundColor: SidebarRole.secondaryText.resolved(appearance).nsColor, .paragraphStyle: paragraph])
        let range = (string.string as NSString).range(of: "Settings")
        string.addAttribute(.link, value: "open-profile-settings", range: range)
        messageView.textStorage?.setAttributedString(string)
        messageView.linkTextAttributes = [.foregroundColor: style.accentColor(appearance).nsColor, .underlineStyle: 0]
        dismissButton.layer?.backgroundColor = GrayScale.a(4).cgColor(appearance)
        dismissButton.attributedTitle = NSAttributedString(string: "Got it", attributes: [.font: NSFont.systemFont(ofSize: BannerMetrics.messageSize, weight: .medium), .foregroundColor: style.titleColor(appearance).nsColor])
        cachedWidth = -1; cachedMessage = ""; needsLayout = true
        onHeightChange?()
    }
    public func height(for width: CGFloat) -> CGFloat {
        if cachedWidth == width, cachedMessage == message { return cachedHeight }
        let textWidth = max(1, width - 24)
        let rect = messageView.textStorage?.boundingRect(with: CGSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]) ?? .zero
        let lines = max(1, ceil(rect.height / 15))
        cachedWidth = width; cachedMessage = message; cachedHeight = 78 + lines * 15
        return cachedHeight
    }
    public override func layout() {
        super.layout()
        title.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: 18)
        let messageHeight = max(15, height(for: bounds.width) - 78)
        messageView.frame = CGRect(x: 12, y: 34, width: max(0, bounds.width - 24), height: messageHeight)
        messageView.textContainer?.containerSize = messageView.bounds.size
        dismissButton.frame = CGRect(x: bounds.width - 68, y: bounds.height - 36, width: 56, height: 24)
    }
    @objc private func dismissBanner() { context.send(.dismissAutoArchiveBanner) }
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let profile { context.send(.openProfileSettings(profile.id)) }
        return true
    }
}

@MainActor
public final class BannerMessageView: NSTextView {
    private var tracking: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseMoved(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let onLink = index < (textStorage?.length ?? 0) && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        var attributes = linkTextAttributes ?? [:]; attributes[.underlineStyle] = onLink ? NSUnderlineStyle.single.rawValue : 0
        linkTextAttributes = attributes
        super.mouseMoved(with: event)
    }
    public override func mouseExited(with event: NSEvent) {
        var attributes = linkTextAttributes ?? [:]; attributes[.underlineStyle] = 0; linkTextAttributes = attributes
        super.mouseExited(with: event)
    }
}
