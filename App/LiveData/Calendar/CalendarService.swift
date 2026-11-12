import Foundation
import OpenLiveData

/// App-wide calendar data for Join Meeting, the calendar glance card and Live Calendar (plan NS §2 CAL).
/// Created lazily by `AppDelegate.calendar` on the first calendar feature use: nothing runs at launch.
@MainActor
final class CalendarService {
  private(set) var source: any CalendarSource
  /// Bumped when the source reports a change; consumers drop cached events.
  private(set) var generation = 0

  init() {
    let eventKit = EventKitCalendarSource()
    source = eventKit
    eventKit.onChange = { [weak self] in self?.generation += 1 }
  }

  #if OPEN_AUTOMATION
  /// E2E only: replaces the system store with a fixture source (no TCC prompt on test machines).
  func replaceSource(_ replacement: any CalendarSource) { source = replacement; generation += 1 }
  #endif

  var now: Date { source.now }

  /// Today's events (local calendar day of `now`), widened to one hour past `now` near midnight.
  func todayEvents() async -> [CalendarEvent] {
    let now = source.now, calendar = Calendar.current
    let start = min(calendar.startOfDay(for: now), now.addingTimeInterval(-NextMeeting.joinableAfterStart))
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
    return await source.events(from: start, to: max(endOfDay, now.addingTimeInterval(3_600)))
  }

  func nextMeeting() async -> (event: CalendarEvent, link: MeetingLink)? {
    NextMeeting.pick(await todayEvents(), now: source.now)
  }
}
