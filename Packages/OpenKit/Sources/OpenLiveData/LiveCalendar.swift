import Foundation

/// Live Calendar: a calendar Favorite counts down to the next meeting and reminds before it starts
/// (docs/re/live-data.md §4). Pure decisions; the App supplies events, the clock and the timer.
public enum LiveCalendar {
    /// Arc's minimum time between two fetches: `calendar-live-preview-min-fetch-interval-in-seconds`,
    /// built-in default 360 (LD §4, constant `0x1037343d0`). EventKit is local, so Open also refetches on
    /// `EKEventStoreChanged`.
    public static let minFetchInterval: TimeInterval = 360
    /// The tile shows the countdown from this long before the start. GUESS — capture pending (F2 item 7).
    public static let countdownLead: TimeInterval = 60 * 60

    /// What a calendar Favorite tile shows now.
    public struct TileState: Equatable, Sendable {
        public enum Phase: String, Sendable { case before, now, after }
        public var event: CalendarEvent
        public var link: MeetingLink
        public var phase: Phase
        /// Arc's tile subtitle: "in 5m", "Now", "3m ago" (LD §4, `G:FUN_101ceb9f0`).
        public var subtitle: String
        /// The reminder is due (and not dismissed for this event).
        public var remind: Bool

        public init(event: CalendarEvent, link: MeetingLink, phase: Phase, subtitle: String, remind: Bool) {
            self.event = event; self.link = link; self.phase = phase; self.subtitle = subtitle; self.remind = remind
        }
    }

    /// The tile state at `now`, or nil when no eligible meeting is close (the tile is a plain Favorite).
    public static func tile(events: [CalendarEvent], now: Date, interval: ReminderInterval,
                            dismissed: Set<String>) -> TileState? {
        guard let (event, link) = NextMeeting.pick(events, now: now) else { return nil }
        let until = event.start.timeIntervalSince(now)
        guard until <= countdownLead else { return nil }
        let minutes = Int((abs(until) / 60).rounded(.down))
        let phase: TileState.Phase
        let subtitle: String
        // Before the start: "in N m", N rounded up (so the last minute reads "in 1m"); the first minute after
        // the start: "Now"; later: "N m ago". GUESS on the exact minute edges — capture pending (F2 item 7).
        if until > 0 { phase = .before; subtitle = "in \(Int((until / 60).rounded(.up)))m" }
        else if until > -60 { phase = .now; subtitle = "Now" }
        else { phase = .after; subtitle = "\(minutes)m ago" }
        let remind = !dismissed.contains(event.id) && interval.lead.map { until <= $0 } == true
        return TileState(event: event, link: link, phase: phase, subtitle: subtitle, remind: remind)
    }

    /// The next moment the tile can change: the next whole minute relative to the event start, or the
    /// reminder time, whichever is first. The App's timer fires then (with tolerance), never more often.
    public static func nextChange(events: [CalendarEvent], now: Date, interval: ReminderInterval) -> Date? {
        guard let (event, _) = NextMeeting.pick(events, now: now) else {
            // Nothing eligible now: the next event that will become eligible (its countdown start).
            let starts = events.filter { !$0.isAllDay && !$0.isDeclined && !$0.isCanceled && $0.joinLink != nil && $0.start > now }
                .map { $0.start.addingTimeInterval(-countdownLead) }
            return starts.min().map { max($0, now.addingTimeInterval(1)) }
        }
        let until = event.start.timeIntervalSince(now)
        if until > countdownLead { return event.start.addingTimeInterval(-countdownLead) }
        // Minute boundaries counted from the start, so "in 5m" turns to "in 4m" on time.
        let offset = until.truncatingRemainder(dividingBy: 60)
        var next = now.addingTimeInterval(offset > 0 ? offset : 60 + offset)
        if let lead = interval.lead, until > lead { next = min(next, event.start.addingTimeInterval(-lead)) }
        // The event drops out when it ends or after the joinable window, whichever is first.
        let dropsOut = min(event.end, event.start.addingTimeInterval(NextMeeting.joinableAfterStart + 1))
        return min(next, max(dropsOut, now.addingTimeInterval(1)))
    }

    /// Reminder time before the start (Arc `LiveCalendarInterval`, LD §4: `S:116292–116299`).
    public enum ReminderInterval: String, CaseIterable, Sendable {
        case never, onStart, twoMinutes, fiveMinutes, tenMinutes

        /// Open's default. GUESS — capture pending (F2 item 7).
        public static let `default` = ReminderInterval.twoMinutes
        /// Per-Profile key prefix (Arc stores it per Profile: `didSetNotificationInterval(interval, profile)`).
        public static func preferenceKey(profile: String) -> String { "open.calendar.reminder.\(profile)" }

        public var title: String {
            switch self {
            case .never: "Never"
            case .onStart: "On Start"
            case .twoMinutes: "Two Minutes Before"
            case .fiveMinutes: "Five Minutes Before"
            case .tenMinutes: "Ten Minutes Before"
            }
        }

        /// Seconds before the start; nil for Never.
        public var lead: TimeInterval? {
            switch self {
            case .never: nil
            case .onStart: 0
            case .twoMinutes: 120
            case .fiveMinutes: 300
            case .tenMinutes: 600
            }
        }
    }
}

/// The App's Live Calendar actions, reached from a calendar Favorite tile.
@MainActor
public struct LiveCalendarActions {
    /// A calendar Favorite tile is on screen: start the countdown (only with Calendar access; never prompts).
    public var tileAppeared: @MainActor (_ tabURL: URL) -> Void
    public var join: @MainActor (LiveCalendar.TileState) -> Void
    public var copyLink: @MainActor (LiveCalendar.TileState) -> Void
    public var dismiss: @MainActor (LiveCalendar.TileState) -> Void
    public var interval: @MainActor () -> LiveCalendar.ReminderInterval
    public var setInterval: @MainActor (LiveCalendar.ReminderInterval) -> Void

    public init(tileAppeared: @escaping @MainActor (URL) -> Void, join: @escaping @MainActor (LiveCalendar.TileState) -> Void,
                copyLink: @escaping @MainActor (LiveCalendar.TileState) -> Void, dismiss: @escaping @MainActor (LiveCalendar.TileState) -> Void,
                interval: @escaping @MainActor () -> LiveCalendar.ReminderInterval,
                setInterval: @escaping @MainActor (LiveCalendar.ReminderInterval) -> Void) {
        self.tileAppeared = tileAppeared; self.join = join; self.copyLink = copyLink; self.dismiss = dismiss
        self.interval = interval; self.setInterval = setInterval
    }
}
