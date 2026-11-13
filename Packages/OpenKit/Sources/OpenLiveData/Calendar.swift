import Foundation

// Pure calendar model for the calendar card, Live Calendar and Join Meeting (docs/re/live-data.md §3–§5).
// No AppKit, no EventKit: the App's `CalendarSource` (EventKit) fills these values.

/// Calendar access as the user sees it. Lead ruling F-questions LEAD 11:05 Q1: EventKit first.
public enum CalendarAccess: String, Sendable {
    /// macOS has not asked yet. The first user action that needs events asks (never at launch or on hover).
    case notDetermined
    case granted
    /// The user said no, or only write access was given.
    case denied
    /// A management profile blocks access.
    case restricted
}

/// One event from a `CalendarSource`. Sendable value; the source copies what it needs from EventKit.
public struct CalendarEvent: Sendable, Hashable, Identifiable {
    /// Stable per occurrence: the source's event identifier plus the start time (recurring events share an identifier).
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarTitle: String
    /// sRGB components of the calendar color (0…1), when the source has one.
    public var calendarColor: [Double]?
    /// The current user declined. Arc filters declined events (LD §3.2, guess from `ResponseStatus.declined`).
    public var isDeclined: Bool
    public var isCanceled: Bool
    /// The event's own URL field, location and notes: the places a call link can be.
    public var url: URL?
    public var location: String?
    public var notes: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendarTitle: String = "",
                            calendarColor: [Double]? = nil, isDeclined: Bool = false, isCanceled: Bool = false,
                            url: URL? = nil, location: String? = nil, notes: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle; self.calendarColor = calendarColor; self.isDeclined = isDeclined
        self.isCanceled = isCanceled; self.url = url; self.location = location; self.notes = notes
    }

    /// The first call link of the event (URL field first, then location, then notes).
    public var joinLink: MeetingLink? { MeetingLink.detect(url: url, location: location, notes: notes) }

    /// Arc's "Event" placeholder for an untitled event (LD §3.2, `G:FUN_10018eb68`).
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Event" : trimmed
    }
}

/// A recognised video-call link (LD §3.6).
public struct MeetingLink: Sendable, Hashable {
    public enum Service: String, Sendable { case meet, zoom, teams, around, webex }
    public var service: Service
    public var url: URL

    public init(service: Service, url: URL) { self.service = service; self.url = url }

    /// Service name for "Join <name>" (LD §3.2 `QuickJoinButton`). Names are product names, not Arc strings.
    public var serviceName: String {
        switch service {
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .around: "Around"
        case .webex: "Webex"
        }
    }

    /// Arc's recognised paths (LD §3.6, `S:131940–131944`, `S:114490–114491`):
    /// `meet.google.com/<path>`, `<sub>.zoom.us/<path>`, `teams.live.com/meet/<path>`,
    /// `teams.microsoft.com/l/meetup-join/<path>`, `around.co/r/<path>`. Webex (`<sub>.webex.com/meet|join|wbxmjs/…`)
    /// is Open's addition from Arc's meeting-host list (`S:270109–270116`).
    public static func classify(_ url: URL) -> MeetingLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host()?.lowercased() else { return nil }
        let path = url.path
        let parts = path.split(separator: "/").map(String.init)
        switch host {
        case "meet.google.com":
            // A meeting code, not the landing page (`/`, `/landing`, `/new`).
            guard let code = parts.first, code.contains("-") || code == "lookup" else { return nil }
            return MeetingLink(service: .meet, url: url)
        case "teams.live.com":
            guard parts.first == "meet", parts.count > 1 else { return nil }
            return MeetingLink(service: .teams, url: url)
        case "teams.microsoft.com":
            guard path.hasPrefix("/l/meetup-join/") else { return nil }
            return MeetingLink(service: .teams, url: url)
        case "around.co":
            guard parts.first == "r", parts.count > 1 else { return nil }
            return MeetingLink(service: .around, url: url)
        default:
            if host == "zoom.us" || host.hasSuffix(".zoom.us") {
                guard let first = parts.first, ["j", "my", "w", "s", "wc"].contains(first), parts.count > 1 else { return nil }
                return MeetingLink(service: .zoom, url: url)
            }
            if host.hasSuffix(".webex.com") {
                guard let first = parts.first?.lowercased(), ["meet", "join", "wbxmjs", "webappng"].contains(first) else { return nil }
                return MeetingLink(service: .webex, url: url)
            }
            return nil
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Free text scanned per field. Invitations put the call link near the top; long notes (pasted agendas)
    /// are not scanned past this many UTF-16 units, so one event costs at most one bounded detector pass.
    public static let scanLimit = 16_384

    /// The first call link in free text, in reading order (first `scanLimit` UTF-16 units only).
    public static func detect(in text: String) -> MeetingLink? {
        guard !text.isEmpty, let detector else { return nil }
        var found: MeetingLink?
        let range = NSRange(location: 0, length: min((text as NSString).length, scanLimit))
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            if let url = match?.url, let link = classify(url) { found = link; stop.pointee = true }
        }
        return found
    }

    public static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = classify(url) { return link }
        if let location, let link = detect(in: location) { return link }
        if let notes, let link = detect(in: notes) { return link }
        return nil
    }
}

/// Picks the meeting that Join Meeting (⌘⌃J, "Join next meeting") opens.
public enum NextMeeting {
    /// Arc keeps an event joinable this long after it starts:
    /// `calendar-live-preview-max-minutes-visible-after-start`, built-in default 10 (LD §4, constant `0x103664f00`).
    public static let joinableAfterStart: TimeInterval = 10 * 60

    /// Eligible: has a call link, not declined, not canceled, not all-day, not ended, started at most
    /// `joinableAfterStart` ago. Choice: the eligible event whose start is nearest to `now`; on a tie the earlier one.
    /// GUESS — capture pending (F2 capture item 8): Arc's tie rule between a running and a coming event.
    public static func pick(_ events: [CalendarEvent], now: Date) -> (event: CalendarEvent, link: MeetingLink)? {
        var best: (event: CalendarEvent, link: MeetingLink, distance: TimeInterval)?
        for event in events where !event.isAllDay && !event.isDeclined && !event.isCanceled && event.end > now
            && event.start >= now.addingTimeInterval(-joinableAfterStart) {
            guard let link = event.joinLink else { continue }
            let distance = abs(event.start.timeIntervalSince(now))
            if let b = best, b.distance < distance || (b.distance == distance && b.event.start <= event.start) { continue }
            best = (event, link, distance)
        }
        return best.map { ($0.event, $0.link) }
    }
}


/// The calendar web apps whose Pinned or Favorite tab shows the calendar card (LD §3.1, §3.5).
/// All three read the same system calendar (EventKit), so only the "New Event" target differs.
public enum CalendarProvider: String, CaseIterable, Hashable, Sendable {
    case google, outlook, notion

    /// Open's one switch for the calendar card (Arc has three: `calendarPreviewEnabled`,
    /// `outlookCalendarPreviewEnabled`, `cronPreviewEnabled`; LD §3.1).
    public static let preferenceKey = "open.general.previewsCalendar"

    /// Card header (LD §3.2).
    public static let header = "Upcoming"
    /// "+" label and tooltip (LD §3.2).
    public static let newLabel = "New Event"
    /// Arc's signed-out text (LD §3.2, `S:110647`), kept for the not-yet-allowed state.
    public static let connectText = "See upcoming meetings and join video calls instantly with the Calendar Preview."

    public static func match(url: URL) -> CalendarProvider? {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased() else { return nil }
        switch host {
        case "calendar.google.com": return .google
        case "calendar.notion.so", "calendar.notion.com": return .notion
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com":
            return url.path.lowercased().hasPrefix("/calendar") ? .outlook : nil
        default: return nil
        }
    }

    /// The "+" target (LD §3.2, `G:FUN_100098754`). Outlook keeps the tab's own host (personal or work).
    public func newEventURL(for tabURL: URL) -> URL {
        switch self {
        case .google: return URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit")!
        case .notion: return URL(string: "https://calendar.notion.so/event/create")!
        case .outlook:
            let host = tabURL.host?.lowercased() == "outlook.live.com" ? "outlook.live.com" : (tabURL.host?.lowercased() ?? "outlook.live.com")
            let prefix = host == "outlook.live.com" ? "/calendar/0" : "/calendar"
            return URL(string: "https://\(host)\(prefix)/deeplink/compose")!
        }
    }
}

/// What the calendar card needs from the App (an EventKit source in normal windows, fixed data in
/// render scenes and automation). Every member runs on first hover or on a click, never at launch.
@MainActor
public struct CalendarGlanceSource {
    /// Current permission state; cheap, never prompts.
    public var access: @MainActor () -> CalendarAccess
    /// Today's events (only called when access is granted).
    public var events: @MainActor () async -> [CalendarEvent]
    public var now: @MainActor () -> Date
    /// The card's access button: asks macOS (not determined) or opens Privacy settings (denied).
    public var requestAccess: @MainActor () async -> CalendarAccess
    /// Opens a call link (Join): the same route as Join Meeting.
    public var join: @MainActor (MeetingLink) -> Void
    /// The card's gear ▸ Refresh: asks the source to sync now and drops cached events (Open's design, CG1).
    public var refresh: @MainActor () -> Void

    public init(access: @escaping @MainActor () -> CalendarAccess, events: @escaping @MainActor () async -> [CalendarEvent],
                now: @escaping @MainActor () -> Date, requestAccess: @escaping @MainActor () async -> CalendarAccess,
                join: @escaping @MainActor (MeetingLink) -> Void, refresh: @escaping @MainActor () -> Void = {}) {
        self.access = access; self.events = events; self.now = now; self.requestAccess = requestAccess; self.join = join
        self.refresh = refresh
    }
}
