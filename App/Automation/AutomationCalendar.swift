#if OPEN_AUTOMATION
import Foundation
import OpenLiveData

/// A calendar source with fixed events, for e2e runs on machines where nobody can answer the macOS Calendar
/// prompt. The real flow (menu, ⌘⌃J, command bar, toasts, new tab) is unchanged; only the data comes from here.
@MainActor
final class FixtureCalendarSource: CalendarSource {
  var events: [CalendarEvent]
  var state: CalendarAccess
  /// The state a `requestAccess()` call moves `.notDetermined` to (the e2e answer to the prompt).
  var answer: CalendarAccess
  private(set) var requests = 0
  private(set) var queries = 0

  init(events: [CalendarEvent], access: CalendarAccess, answer: CalendarAccess) {
    self.events = events; self.state = access; self.answer = answer
  }

  var now: Date { Date() }
  var access: CalendarAccess { state }

  func requestAccess() async -> CalendarAccess {
    requests += 1
    if state == .notDetermined { state = answer }
    return state
  }

  func events(from start: Date, to end: Date) async -> [CalendarEvent] {
    queries += 1
    guard state == .granted else { return [] }
    return events.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
  }
}

/// `calendar` (docs/automation.md): `action` = `state` (default), `fixture`, `eventkit`, `join-result`.
/// `fixture` takes `access`, `answer` and `events` = [{id, title, start, end (minutes from now), url, location,
/// notes, declined, canceled, allDay}].
extension AutomationController {
  func calendarCommand(_ a: [String: Any]) async throws -> Any {
    let action = a["action"] as? String ?? "state"
    let service = app.calendar
    switch action {
    case "fixture":
      func access(_ key: String, _ fallback: CalendarAccess) throws -> CalendarAccess {
        guard let raw = a[key] as? String else { return fallback }
        guard let value = CalendarAccess(rawValue: raw) else { throw Failure(message: "unknown \(key) \(raw)") }
        return value
      }
      let now = Date()
      let rows = a["events"] as? [[String: Any]] ?? []
      let events = rows.enumerated().map { i, r -> CalendarEvent in
        let start = now.addingTimeInterval(60 * ((r["start"] as? Double) ?? 0))
        let end = now.addingTimeInterval(60 * ((r["end"] as? Double) ?? ((r["start"] as? Double) ?? 0) + 30))
        return CalendarEvent(id: r["id"] as? String ?? "e\(i)", title: r["title"] as? String ?? "", start: start, end: end,
          isAllDay: r["allDay"] as? Bool ?? false, calendarTitle: r["calendar"] as? String ?? "Open E2E", calendarColor: nil,
          isDeclined: r["declined"] as? Bool ?? false, isCanceled: r["canceled"] as? Bool ?? false,
          url: (r["url"] as? String).flatMap(URL.init(string:)), location: r["location"] as? String, notes: r["notes"] as? String)
      }
      service.replaceSource(FixtureCalendarSource(events: events, access: try access("access", .granted), answer: try access("answer", .granted)))
      return try await calendarState(service)
    case "eventkit":
      // Reports the real store's state without asking (no prompt, no store).
      return ["access": EventKitCalendarSource().access.rawValue]
    case "join-result":
      return try window.lastJoinMeeting
    case "state":
      return try await calendarState(service)
    default:
      throw Failure(message: "unknown calendar action \(action)")
    }
  }

  private func calendarState(_ service: CalendarService) async throws -> [String: Any] {
    var out: [String: Any] = ["access": service.source.access.rawValue, "generation": service.generation]
    if let fixture = service.source as? FixtureCalendarSource {
      out["source"] = "fixture"; out["requests"] = fixture.requests; out["queries"] = fixture.queries
    } else {
      out["source"] = "eventkit"
    }
    // Reading `state` must not prompt: events are read only when access is already granted.
    guard service.source.access == .granted else { return out }
    let events = await service.todayEvents()
    out["events"] = events.map { ["id": $0.id, "title": $0.displayTitle, "join": $0.joinLink?.url.absoluteString ?? ""] }
    if let next = NextMeeting.pick(events, now: service.now) {
      out["next"] = ["id": next.event.id, "url": next.link.url.absoluteString, "service": next.link.service.rawValue]
    }
    return out
  }
}
#endif
