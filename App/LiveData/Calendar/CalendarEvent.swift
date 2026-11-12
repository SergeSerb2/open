import Foundation

// Pure calendar model for Calendar preview, Live Calendar and Join Meeting (docs/re/live-data.md §3–§5).
// No AppKit, no EventKit: this file moves into the `OpenLiveData` package target when it lands (plan NS, LF L1).

/// One event from a `CalendarSource`. Sendable value; the source copies what it needs from EventKit.
struct CalendarEvent: Sendable, Hashable, Identifiable {
  /// Stable per occurrence: the source's event identifier plus the start time (recurring events share an identifier).
  var id: String
  var title: String
  var start: Date
  var end: Date
  var isAllDay: Bool
  var calendarTitle: String
  /// sRGB components of the calendar color (0…1), when the source has one.
  var calendarColor: [Double]?
  /// The current user declined. Arc filters declined events (LD §3.2, guess from `ResponseStatus.declined`).
  var isDeclined: Bool
  var isCanceled: Bool
  /// The event's own URL field, location and notes: the places a call link can be.
  var url: URL?
  var location: String?
  var notes: String?

  /// The first call link of the event (URL field first, then location, then notes).
  var joinLink: MeetingLink? { MeetingLink.detect(url: url, location: location, notes: notes) }

  /// Arc's "Event" placeholder for an untitled event (LD §3.2, `G:FUN_10018eb68`).
  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Event" : trimmed
  }
}

/// A recognised video-call link (LD §3.6).
struct MeetingLink: Sendable, Hashable {
  enum Service: String, Sendable { case meet, zoom, teams, around, webex }
  var service: Service
  var url: URL

  /// Service name for "Join <name>" (LD §3.2 `QuickJoinButton`). Names are product names, not Arc strings.
  var serviceName: String {
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
  static func classify(_ url: URL) -> MeetingLink? {
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

  /// The first call link in free text, in reading order.
  static func detect(in text: String) -> MeetingLink? {
    guard !text.isEmpty, let detector else { return nil }
    var found: MeetingLink?
    detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
      if let url = match?.url, let link = classify(url) { found = link; stop.pointee = true }
    }
    return found
  }

  static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
    if let url, let link = classify(url) { return link }
    if let location, let link = detect(in: location) { return link }
    if let notes, let link = detect(in: notes) { return link }
    return nil
  }
}

/// Picks the meeting that Join Meeting (⌘⌃J, "Join next meeting") opens.
enum NextMeeting {
  /// Arc keeps an event joinable this long after it starts:
  /// `calendar-live-preview-max-minutes-visible-after-start`, built-in default 10 (LD §4, constant `0x103664f00`).
  static let joinableAfterStart: TimeInterval = 10 * 60

  /// Eligible: has a call link, not declined, not canceled, not all-day, not ended, started at most
  /// `joinableAfterStart` ago. Choice: the eligible event whose start is nearest to `now`; on a tie the earlier one.
  /// GUESS — capture pending (F2 capture item 8): Arc's tie rule between a running and a coming event.
  static func pick(_ events: [CalendarEvent], now: Date) -> (event: CalendarEvent, link: MeetingLink)? {
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
