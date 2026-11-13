import AppKit
import OpenDesign
import OpenLiveData
import OpenModel

/// Native calendar card for a Pinned or Favorite Google, Outlook or Notion Calendar tab
/// (docs/re/live-data.md §3.2). Data: the App's `CalendarGlanceSource` (EventKit), read once when the
/// card opens; no timer. Strings "Upcoming", "New Event", the connect text and the event subtitles are
/// Arc facts (LD §3.2). Every size, color and the layout below are GUESS — capture pending (F2 item 6):
/// header as the Recents card (40 pt), a join strip for an event within 10 minutes, then a day timeline
/// (40 pt per hour, 5 hours visible, scrolled to one hour before now).
@MainActor
public final class CalendarPreviewView: NSView {
    public enum Phase: String, Sendable { case loading, needsAccess, denied, restricted, timeline }

    public let context: SidebarContext
    public let tab: Tab
    public let provider: CalendarProvider
    public let newButton = RecentsNewButton()
    /// Gear (Open's design, LEAD 19:30, CG1): Arc's card has a settings button (`clickedSettings`) and a menu with
    /// "Refresh" and "Disable Live Calendar" (LD §3.2, `S:110792–110804`); its place and look were never captured.
    /// Open: left of "+", the same button style; while Refresh loads, a small spinner takes its place.
    public let gearButton = RecentsNewButton()
    public let spinner = NSProgressIndicator()
    public private(set) var isRefreshing = false
    public let joinButton = CalendarPillButton()
    public let accessButton = CalendarPillButton()
    public let timeline = CalendarTimelineView()
    private let source: CalendarGlanceSource
    private let header = TextLabel()
    private let separator = NSView()
    private let joinTitle = TextLabel()
    private let joinSubtitle = TextLabel()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var loops: [ObservationLoop] = []
    private var loadTask: Task<Void, Never>?
    public private(set) var phase: Phase = .loading
    public private(set) var events: [CalendarEvent] = []
    /// The event the join strip offers, with its call link.
    public private(set) var joinable: (event: CalendarEvent, link: MeetingLink)?
    public private(set) var isLoaded = false
    /// "+" (New Event): opened as a Peek of `tab` by the App (LD §3.3 "Links").
    public var onOpen: (@MainActor (URL) -> Void)?
    /// An event block: Open shows the calendar tab itself (EventKit events have no web link).
    public var onSelectTab: (@MainActor () -> Void)?
    public var onResize: (@MainActor () -> Void)?

    public static let headerHeight: CGFloat = 40
    public static let joinHeight: CGFloat = 52
    /// Space above and below the message and its button.
    public static let messagePadding: CGFloat = 22
    /// The join strip shows an event that starts within this many seconds (W3: "within a few minutes").
    public static let joinLead: TimeInterval = 10 * 60

    public init(context: SidebarContext, tab: Tab, provider: CalendarProvider, source: CalendarGlanceSource) {
        self.context = context; self.tab = tab; self.provider = provider; self.source = source
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = HoverPreviewMetrics.radius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        header.font = .systemFont(ofSize: 13, weight: .semibold); header.baseline = 25
        header.color = { Core.foregroundPrimary.nsColor }; header.text = { CalendarProvider.header }
        header.setAccessibilityElement(true); header.setAccessibilityRole(.staticText); header.setAccessibilityLabel(CalendarProvider.header)
        newButton.toolTip = CalendarProvider.newLabel
        newButton.setAccessibilityLabel(CalendarProvider.newLabel)
        newButton.onPress = { [weak self] in self?.openNew() }
        gearButton.symbolName = "gearshape"
        gearButton.toolTip = "Calendar Settings"
        gearButton.setAccessibilityLabel("Calendar Settings")
        gearButton.onPress = { [weak self] in self?.showGearMenu() }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Refreshing")
        separator.wantsLayer = true
        joinTitle.font = .systemFont(ofSize: 12, weight: .semibold); joinTitle.baseline = 20
        joinTitle.color = { Core.foregroundPrimary.nsColor }
        joinSubtitle.font = .systemFont(ofSize: 11); joinSubtitle.baseline = 36
        joinSubtitle.color = { Core.foregroundSecondary.nsColor }
        joinButton.onPress = { [weak self] in self?.join() }
        accessButton.onPress = { [weak self] in self?.askAccess() }
        message.font = .systemFont(ofSize: 12); message.alignment = .center
        message.textColor = Core.foregroundSecondary.nsColor
        timeline.onSelect = { [weak self] _ in
            self?.context.existingHoverPreviews?.dismiss()
            self?.onSelectTab?()
        }
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = timeline
        for view in [header, gearButton, spinner, newButton, separator, joinTitle, joinSubtitle, joinButton, message, accessButton, scroll] as [NSView] { addSubview(view) }
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }; _ = self.context.systemAppearance; _ = self.context.increaseContrast; _ = self.context.focusedSpace?.theme
        }) { [weak self] in self?.applyAppearance() })
        applyAppearance()
        start()
        frame.size = fittingSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loops.forEach { $0.cancel() }; loadTask?.cancel() }
    public override var isFlipped: Bool { true }

    public override var fittingSize: NSSize {
        let body: CGFloat
        switch phase {
        case .timeline, .loading: body = (joinable == nil ? 0 : Self.joinHeight) + CalendarTimelineView.visibleHeight
        case .needsAccess, .denied, .restricted: body = messageBlockHeight(width: HoverPreviewMetrics.folderWidth) + 2 * Self.messagePadding
        }
        return CGSize(width: HoverPreviewMetrics.folderWidth, height: Self.headerHeight + body)
    }

    /// Hover never prompts: without access the card shows the access state and waits for a click.
    private func start() {
        switch source.access() {
        case .granted: load()
        case .notDetermined: show(.needsAccess)
        case .denied: show(.denied)
        case .restricted: show(.restricted)
        }
    }

    private func load() {
        phase = .loading
        let source = source
        loadTask = Task { [weak self] in
            let events = await source.events()
            guard !Task.isCancelled, let self else { return }
            self.setRefreshing(false)
            let now = source.now()
            self.events = events
            self.joinable = NextMeeting.pick(events, now: now).flatMap { $0.event.start.timeIntervalSince(now) <= Self.joinLead ? $0 : nil }
            self.timeline.update(events: events.filter { !$0.isAllDay && !$0.isCanceled }, now: now)
            self.show(.timeline)
        }
    }

    private func show(_ next: Phase) {
        phase = next; isLoaded = next != .loading
        let strip = next == .timeline && joinable != nil
        for view in [joinTitle, joinSubtitle, joinButton] as [NSView] { view.isHidden = !strip }
        scroll.isHidden = next != .timeline
        message.isHidden = next == .timeline || next == .loading
        accessButton.isHidden = next != .needsAccess && next != .denied
        switch next {
        case .needsAccess:
            message.stringValue = CalendarProvider.connectText
            accessButton.title = "Allow Calendar Access"
        case .denied:
            // Open's own text (EventKit replaces Arc's sign-in; F2 report §7).
            message.stringValue = "Allow Open to use your calendars in System Settings to see upcoming meetings here."
            accessButton.title = "Open Privacy Settings"
        case .restricted:
            message.stringValue = "Calendar access is restricted on this Mac."
        case .timeline, .loading: break
        }
        message.setAccessibilityLabel(message.stringValue)
        if let (event, link) = joinable, strip {
            joinTitle.text = { event.displayTitle }
            let subtitle = Self.subtitle(for: event, now: source.now())
            joinSubtitle.text = { subtitle }
            joinButton.title = "Join"
            joinButton.toolTip = "Join " + link.serviceName
            joinButton.setAccessibilityLabel("Join " + link.serviceName)
        }
        needsLayout = true
        onResize?()
        if next == .timeline { scrollToNow() }
    }

    /// Arc's event subtitles (LD §3.2, `S:131934–131939`): "Event right now", "Event began N m ago", "Event in N m".
    public static func subtitle(for event: CalendarEvent, now: Date) -> String {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded())
        if minutes == 0 { return "Event right now" }
        if minutes < 0 { return "Event began \(-minutes)m ago" }
        return "Event in \(minutes)m"
    }

    private func scrollToNow() {
        layoutSubtreeIfNeeded()
        // Start one whole hour before now, with the hour label fully visible.
        let calendar = Calendar.current, earlier = source.now().addingTimeInterval(-3600)
        let hour = calendar.dateInterval(of: .hour, for: earlier)?.start ?? earlier
        let y = max(0, min(timeline.y(for: hour) - CalendarTimelineView.top, timeline.frame.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func applyAppearance() {
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        self.appearance = appearance.nsAppearance
        layer?.backgroundColor = PreviewColors.background.cgColor(appearance)
        layer?.borderWidth = appearance == .dark ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        separator.layer?.backgroundColor = (appearance == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.10).cgColor
        var ink = NSColor.secondaryLabelColor
        appearance.nsAppearance.performAsCurrentDrawingAppearance { ink = Core.foregroundSecondary.nsColor.usingColorSpace(.sRGB) ?? ink }
        newButton.ink = ink; gearButton.ink = ink
        message.textColor = Core.foregroundSecondary.nsColor
        for view in [header, joinTitle, joinSubtitle, timeline, joinButton, accessButton] as [NSView] { view.needsDisplay = true }
    }

    public override func layout() {
        super.layout()
        let h = Self.headerHeight, w = bounds.width
        header.frame = CGRect(x: 14, y: 0, width: max(0, w - 88), height: h)
        newButton.frame = CGRect(x: w - 10 - 24, y: (h - 24) / 2, width: 24, height: 24)
        gearButton.frame = newButton.frame.offsetBy(dx: -28, dy: 0)
        let spin = spinner.fittingSize
        spinner.frame = CGRect(x: gearButton.frame.midX - spin.width / 2, y: gearButton.frame.midY - spin.height / 2, width: spin.width, height: spin.height)
        separator.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
        var y = h
        if !joinButton.isHidden {
            joinTitle.frame = CGRect(x: 14, y: y, width: max(0, w - 100), height: Self.joinHeight)
            joinSubtitle.frame = CGRect(x: 14, y: y, width: max(0, w - 100), height: Self.joinHeight)
            joinButton.frame = CGRect(x: w - 14 - 64, y: y + (Self.joinHeight - 26) / 2, width: 64, height: 26)
            y += Self.joinHeight
        }
        scroll.frame = CGRect(x: 0, y: y, width: w, height: max(0, bounds.height - y))
        timeline.frame = CGRect(x: 0, y: 0, width: w, height: CalendarTimelineView.dayHeight)
        let text = messageTextHeight(width: w)
        let top = h + Self.messagePadding
        message.frame = CGRect(x: 20, y: top, width: w - 40, height: text)
        let buttonWidth = min(w - 40, accessButton.intrinsicWidth)
        accessButton.frame = CGRect(x: (w - buttonWidth) / 2, y: top + text + 14, width: buttonWidth, height: 26)
    }

    private func messageTextHeight(width: CGFloat) -> CGFloat {
        ceil(message.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width - 40, height: 400)).height ?? 32)
    }
    private func messageBlockHeight(width: CGFloat) -> CGFloat {
        messageTextHeight(width: width) + (accessButton.isHidden ? 0 : 14 + 26)
    }

    /// The gear menu: "Refresh", then, for a calendar Favorite, a separator and "Disable Live Calendar".
    /// A Pinned calendar tab has no Live Calendar, so its menu has "Refresh" only.
    public func gearMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refresh = ClosureMenuItem("Refresh") { [weak self] in self?.refresh() }
        refresh.isEnabled = source.access() == .granted && !isRefreshing
        menu.addItem(refresh)
        if isLiveCalendarFavorite {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Disable Live Calendar") { [weak self] in self?.disableLiveCalendar() })
        }
        return menu
    }

    /// This card belongs to a calendar Favorite that Live Calendar runs on.
    public var isLiveCalendarFavorite: Bool {
        context.liveCalendar != nil && context.favoritesProfile?.favorites.contains(where: { $0.id == tab.id }) == true
    }

    private func showGearMenu() {
        // Keep the card while the menu tracks: the pointer leaves the card for the menu.
        context.hoverPreviews.setPointerInsidePreview(true)
        gearMenu().popUp(positioning: nil, at: CGPoint(x: gearButton.frame.minX, y: gearButton.frame.maxY + 4), in: self)
        // The menu has closed (synchronous tracking): report where the pointer really is now.
        guard superview != nil, let window else { return }
        context.hoverPreviews.setPointerInsidePreview(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// Gear ▸ Refresh: the source syncs, then the card reloads its events; the spinner shows meanwhile.
    public func refresh() {
        guard source.access() == .granted, !isRefreshing else { return }
        loadTask?.cancel()
        setRefreshing(true)
        source.refresh()
        load()
    }

    private func setRefreshing(_ on: Bool) {
        guard isRefreshing != on else { return }
        isRefreshing = on
        gearButton.isHidden = on
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Gear ▸ Disable Live Calendar: the card closes and this Favorite becomes a plain Favorite (stored per Favorite).
    public func disableLiveCalendar() {
        context.existingHoverPreviews?.dismiss()
        context.setLiveCalendarEnabled(false, for: tab)
    }

    @objc public func openNew() {
        context.existingHoverPreviews?.dismiss()
        onOpen?(provider.newEventURL(for: tab.url))
    }

    /// Join strip button: the same route as Join Meeting (new tab in the focused Space).
    public func join() {
        guard let link = joinable?.link else { return }
        context.existingHoverPreviews?.dismiss()
        source.join(link)
    }

    /// The access button: the macOS prompt (not determined) or Privacy settings (denied).
    public func askAccess() {
        let source = source
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let access = await source.requestAccess()
            guard !Task.isCancelled, let self else { return }
            switch access {
            case .granted: self.load()
            case .notDetermined: self.show(.needsAccess)
            case .denied: self.show(.denied)
            case .restricted: self.show(.restricted)
            }
        }
    }
}

/// Today's events on an hour grid. One view, drawn in `draw(_:)`; overlapping events share the width.
@MainActor
public final class CalendarTimelineView: NSView {
    public static let hourHeight: CGFloat = 40
    public static let dayHeight: CGFloat = hourHeight * 24 + 8
    public static let visibleHeight: CGFloat = hourHeight * 5
    static let labelWidth: CGFloat = 46
    static let top: CGFloat = 8

    public private(set) var events: [CalendarEvent] = []
    private var now = Date()
    private var dayStart = Date()
    /// Event frames in this view's coordinates, for clicks and automation.
    public private(set) var blocks: [(event: CalendarEvent, frame: CGRect)] = []
    var onSelect: (@MainActor (CalendarEvent) -> Void)?

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(events: [CalendarEvent], now: Date) {
        self.events = events; self.now = now; dayStart = Calendar.current.startOfDay(for: now)
        needsLayout = true; needsDisplay = true
    }

    func y(for date: Date) -> CGFloat {
        Self.top + CGFloat(date.timeIntervalSince(dayStart) / 3600) * Self.hourHeight
    }

    public override func layout() {
        super.layout()
        // Greedy columns: each event takes the first column whose last event ended; a cluster of
        // overlapping events splits the width evenly.
        let left = Self.labelWidth + 4, width = bounds.width - left - 10
        var result: [(CalendarEvent, CGRect)] = []
        var cluster: [(CalendarEvent, Int)] = [], columnsEnd: [Date] = [], clusterEnd = Date.distantPast
        func flush() {
            let n = max(1, columnsEnd.count)
            for (event, column) in cluster {
                let top = y(for: max(event.start, dayStart)), bottom = y(for: min(event.end, dayStart.addingTimeInterval(86_400)))
                let w = width / CGFloat(n)
                result.append((event, CGRect(x: left + w * CGFloat(column), y: top + 1, width: w - 2, height: max(18, bottom - top - 2))))
            }
            cluster = []; columnsEnd = []
        }
        for event in events.sorted(by: { $0.start < $1.start }) {
            if event.start >= clusterEnd { flush() }
            let column = columnsEnd.firstIndex { $0 <= event.start } ?? columnsEnd.count
            if column == columnsEnd.count { columnsEnd.append(event.end) } else { columnsEnd[column] = event.end }
            cluster.append((event, column)); clusterEnd = max(clusterEnd, event.end)
        }
        flush()
        blocks = result.map { (event: $0.0, frame: $0.1) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let primary = Core.foregroundPrimary.nsColor, secondary = Core.foregroundSecondary.nsColor
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let line = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.08)
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("j")
        for hour in 0...24 {
            let y = Self.top + CGFloat(hour) * Self.hourHeight
            guard y >= dirtyRect.minY - Self.hourHeight, y <= dirtyRect.maxY + Self.hourHeight else { continue }
            line.setFill(); NSRect(x: Self.labelWidth, y: y, width: bounds.width - Self.labelWidth - 10, height: 1).fill()
            guard hour < 24, hour > 0 else { continue }
            let label = formatter.string(from: dayStart.addingTimeInterval(Double(hour) * 3600)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: secondary]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: Self.labelWidth - 6 - size.width, y: y - size.height / 2), withAttributes: attrs)
        }
        let timeFormatter = DateFormatter(); timeFormatter.timeStyle = .short; timeFormatter.dateStyle = .none
        for (event, frame) in blocks where frame.intersects(dirtyRect) {
            let tint = event.calendarColor.flatMap { $0.count == 3 ? NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1) : nil }
                ?? Core.focusRing.nsColor
            let past = event.end <= now
            let shape = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            tint.withAlphaComponent((dark ? 0.30 : 0.18) * (past ? 0.5 : 1)).setFill(); shape.fill()
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            tint.withAlphaComponent(past ? 0.5 : 1).setFill(); NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            let text = NSRect(x: frame.minX + 7, y: frame.minY + 2, width: frame.width - 10, height: frame.height - 4)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let ink = past ? secondary : primary
            (event.displayTitle as NSString).draw(with: CGRect(x: text.minX, y: text.minY, width: text.width, height: 14),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style])
            if frame.height >= 30 {
                let range = timeFormatter.string(from: event.start) + " – " + timeFormatter.string(from: event.end)
                (range as NSString).draw(with: CGRect(x: text.minX, y: text.minY + 14, width: text.width, height: 13),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: secondary, .paragraphStyle: style])
            }
        }
        // Now line.
        let y = y(for: now)
        NSColor.systemRed.setFill()
        NSRect(x: Self.labelWidth, y: y - 0.5, width: bounds.width - Self.labelWidth - 10, height: 1).fill()
        NSBezierPath(ovalIn: CGRect(x: Self.labelWidth - 3, y: y - 3, width: 6, height: 6)).fill()
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = blocks.first(where: { $0.frame.contains(point) }) { select(hit.event) }
    }
    /// The click path of one event block (automation uses it too).
    public func select(_ event: CalendarEvent) { onSelect?(event) }
}

/// A filled pill button (Join, access). Blue with white text (GUESS — capture pending).
@MainActor
public final class CalendarPillButton: NSView {
    var onPress: (@MainActor () -> Void)?
    public var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    var intrinsicWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 24 }
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        let fill = Core.focusRing.nsColor
        (hovered ? fill.blended(withFraction: 0.12, of: .black) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
