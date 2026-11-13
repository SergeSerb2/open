import EventKit
import Foundation
import OpenLiveData

@MainActor
protocol CalendarSource: AnyObject {
  /// Cheap: never creates a store.
  var access: CalendarAccess { get }
  /// Shows the macOS prompt when access is `.notDetermined`; returns the new state.
  func requestAccess() async -> CalendarAccess
  /// Events that overlap `start..<end`, from every calendar the user has, sorted by start.
  func events(from start: Date, to end: Date) async -> [CalendarEvent]
  /// The clock the source's consumers use (a debug override in automation builds).
  var now: Date { get }
  /// Asks the source to sync with its accounts now (the calendar card's gear ▸ Refresh).
  func refresh()
}

/// The system Calendar store (Google, Exchange / Microsoft 365 and iCloud accounts in macOS Internet Accounts).
/// Performance: the `EKEventStore` is created on first use only, and queries run off the main thread.
@MainActor
final class EventKitCalendarSource: CalendarSource {
  private final class StoreBox: @unchecked Sendable {
    // EKEventStore reads are thread-safe; the box only carries it across the detached query task.
    let store = EKEventStore()
  }
  private var box: StoreBox?
  private var changeObserver: (any NSObjectProtocol)?
  /// Called on the main actor when the store reports a change (new, edited or deleted events, account sync).
  var onChange: (() -> Void)?

  var now: Date { Date() }
  /// Events copied per query (one day): the first ones by start time.
  nonisolated static let maxEvents = 500

  var access: CalendarAccess {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied, .writeOnly: .denied
    @unknown default: .denied
    }
  }

  private func storeBox() -> StoreBox {
    if let box { return box }
    let made = StoreBox()
    box = made
    changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: made.store, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onChange?() }
    }
    return made
  }

  /// EventKit syncs remote accounts on its own schedule; Refresh asks it to sync now. A change arrives as
  /// `EKEventStoreChanged` (→ `onChange`). Without a store yet there is nothing to sync.
  func refresh() {
    guard access == .granted else { return }
    box?.store.refreshSourcesIfNecessary()
  }

  func requestAccess() async -> CalendarAccess {
    guard access == .notDetermined else { return access }
    let box = storeBox()
    _ = try? await box.store.requestFullAccessToEvents()
    return access
  }

  func events(from start: Date, to end: Date) async -> [CalendarEvent] {
    guard access == .granted else { return [] }
    let box = storeBox()
    return await Task.detached(priority: .userInitiated) {
      let store = box.store
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
      // A day rarely has more than a few dozen events; cap what one query copies (shared calendars can be huge).
      let found = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
      return found.prefix(Self.maxEvents).map(Self.event(from:))
    }.value
  }

  nonisolated private static func event(from e: EKEvent) -> CalendarEvent {
    let me = e.attendees?.first(where: \.isCurrentUser)
    let color = e.calendar?.cgColor.flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) }
    return CalendarEvent(
      id: "\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))",
      title: e.title ?? "",
      start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
      calendarTitle: e.calendar?.title ?? "",
      calendarColor: color?.components.map { $0.prefix(3).map(Double.init) },
      isDeclined: me?.participantStatus == .declined,
      isCanceled: e.status == .canceled,
      url: e.url, location: e.location, notes: e.notes)
  }
}
