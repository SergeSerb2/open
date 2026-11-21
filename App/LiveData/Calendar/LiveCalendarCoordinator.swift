import AppKit
import OpenFeatures
import OpenLiveData
import OpenModel
import OpenSidebar

/// Live Calendar (docs/re/live-data.md §4): calendar Favorites count down to the next meeting and remind
/// before it starts. Starts when a calendar Favorite tile appears and Calendar access is already granted
/// (it never prompts). One timer, scheduled for the next visible change (`LiveCalendar.nextChange`) with
/// tolerance; events are refetched at most every 6 minutes (Arc's 360 s) or when the store changes.
@MainActor
final class LiveCalendarCoordinator {
  unowned let app: AppDelegate
  private(set) var isActive = false
  private(set) var events: [CalendarEvent] = []
  private var lastFetch: Date?
  private var fetchedGeneration = -1
  private(set) var fetching = false
  private var timer: Timer?
  /// Events dismissed from the tile ("Show Meeting Link" ▸ Dismiss). Memory only (F2 Q3: no events on disk).
  private(set) var dismissed: Set<String> = []
  /// Events that already showed their reminder.
  private(set) var reminded: Set<String> = []
  private(set) var nextFire: Date?
  #if OPEN_AUTOMATION
  private(set) var fetches = 0
  private(set) var reminders: [[String: Any]] = []
  #endif

  private var settingsObserver: (any NSObjectProtocol)?

  init(app: AppDelegate) {
    self.app = app
    // "Disable / Enable Live Calendar" on a Favorite (Open's design, CG1): recompute at once; turning one back on
    // starts Live Calendar again if it had stopped.
    settingsObserver = NotificationCenter.default.addObserver(forName: FavoriteTileSettings.didChange, object: nil, queue: .main) { [weak self] _ in
      // Every window reloads its settings from this notification. Wait until all those callbacks have run
      // before reading their settings, so another window cannot keep the disabled Favorite live.
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.isActive { self.update() } else if self.hasLiveFavorite() { self.tileAppeared() }
      }
    }
  }

  /// A calendar Favorite with Live Calendar on exists in some window.
  private func hasLiveFavorite() -> Bool {
    app.windowControllers.contains { controller in
      controller.context.liveCalendar != nil && (controller.context.favoritesProfile?.favorites ?? []).contains {
        CalendarProvider.match(url: $0.url) != nil && controller.context.liveCalendarEnabled(for: $0)
      }
    }
  }

  /// The calendar card's gear ▸ Refresh: drop the fetch cache and fetch again now.
  func refetch() {
    lastFetch = nil
    if isActive { update() } else if hasLiveFavorite() { tileAppeared() }
  }

  /// One window's actions. `profile` reads that window's Favorites Profile at call time: the reminder
  /// interval is per Profile (Arc `didSetNotificationInterval(interval, profile)`), so a menu in one
  /// window never reads or writes the front window's Profile.
  func actions(window: @escaping @MainActor () -> BrowserWindowController?) -> LiveCalendarActions {
    let profile = { window()?.context.favoritesProfile?.id }
    return LiveCalendarActions(
      tileAppeared: { [weak self] _ in self?.tileAppeared() },
      join: { [weak self] state in self?.join(state, in: window()) },
      copyLink: { state in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.link.url.absoluteString, forType: .string)
      },
      dismiss: { [weak self] state in self?.dismissed.insert(state.event.id); self?.update() },
      interval: { [weak self] in self?.interval(profile: profile()) ?? .default },
      setInterval: { [weak self] value in
        UserDefaults.standard.set(value.rawValue, forKey: LiveCalendar.ReminderInterval.preferenceKey(profile: Self.profileKey(profile())))
        self?.update()
      })
  }

  /// Per Profile, as in Arc.
  private static func profileKey(_ profile: ProfileID?) -> String { profile?.description ?? "default" }

  func interval(profile: ProfileID?) -> LiveCalendar.ReminderInterval {
    UserDefaults.standard.string(forKey: LiveCalendar.ReminderInterval.preferenceKey(profile: Self.profileKey(profile)))
      .flatMap(LiveCalendar.ReminderInterval.init(rawValue:)) ?? .default
  }

  func tileAppeared() {
    guard !isActive, app.calendar.source.access == .granted else { return }
    isActive = true
    app.calendar.onChange = { [weak self] in if self?.isActive == true { self?.update() } }
    update()
  }

  /// Recomputes every window's calendar tiles; refetches when the cache is stale.
  func update() {
    timer?.invalidate(); timer = nil; nextFire = nil
    guard isActive else { return }
    let calendar = app.calendar, now = calendar.now
    guard calendar.source.access == .granted else { stop(); return }
    let stale = lastFetch.map { now.timeIntervalSince($0) >= LiveCalendar.minFetchInterval || $0 > now } ?? true
    if (stale || fetchedGeneration != calendar.generation), !fetching {
      fetching = true
      let generation = calendar.generation
      Task { [weak self] in
        let events = await calendar.todayEvents()
        guard let self else { return }
        self.fetching = false
        self.events = events; self.lastFetch = calendar.now; self.fetchedGeneration = generation
        #if OPEN_AUTOMATION
        self.fetches += 1
        #endif
        self.update()
      }
      return
    }
    let visible = events.filter { !dismissed.contains($0.id) }
    var anyTile = false
    // Each window uses its own Profile's interval. Of the windows whose interval makes the reminder due,
    // the frontmost visible one shows it.
    var due: [(state: LiveCalendar.TileState, controller: BrowserWindowController)] = []
    var intervals: [LiveCalendar.ReminderInterval] = []
    for controller in app.windowControllers where controller.context.liveCalendar != nil {
      let favorites = controller.context.favoritesProfile?.favorites ?? []
      let interval = interval(profile: controller.context.favoritesProfile?.id)
      var tiles: [ItemID: LiveCalendar.TileState] = [:]
      for tab in favorites where CalendarProvider.match(url: tab.url) != nil && controller.context.liveCalendarEnabled(for: tab) {
        anyTile = true; intervals.append(interval)
        guard let state = LiveCalendar.tile(events: visible, now: now, interval: interval, dismissed: reminded) else { continue }
        tiles[tab.id] = state
        if state.remind { due.append((state, controller)) }
      }
      if controller.context.liveCalendarTiles != tiles { controller.context.liveCalendarTiles = tiles }
    }
    guard anyTile else { stop(); return }
    if let due = frontmost(due) {
      reminded.insert(due.state.event.id)
      remind(due.state, in: due.controller)
    }
    // Next wake: the next visible change or the next fetch, whichever is first.
    var next = lastFetch.map { $0.addingTimeInterval(LiveCalendar.minFetchInterval) } ?? now.addingTimeInterval(LiveCalendar.minFetchInterval)
    for interval in Set(intervals) {
      if let change = LiveCalendar.nextChange(events: visible, now: now, interval: interval) { next = min(next, change) }
    }
    let delay = max(1, next.timeIntervalSince(now))
    nextFire = now.addingTimeInterval(delay)
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
    timer.tolerance = min(5, delay / 10)
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// No calendar Favorite is left, or access went away: tiles go plain and the timer stops.
  func stop() {
    isActive = false; timer?.invalidate(); timer = nil; nextFire = nil
    for controller in app.windowControllers where !controller.context.liveCalendarTiles.isEmpty { controller.context.liveCalendarTiles = [:] }
  }

  /// The candidate whose window is frontmost on screen (visible and not minimized first), else the first one.
  private func frontmost<T>(_ candidates: [(state: T, controller: BrowserWindowController)]) -> (state: T, controller: BrowserWindowController)? {
    for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized {
      if let match = candidates.first(where: { $0.controller.window === window }) { return match }
    }
    return candidates.first
  }

  private func join(_ state: LiveCalendar.TileState, in window: BrowserWindowController?) {
    // The tile's or reminder's own window; else the main model's front window, never an Incognito or
    // Blank Window (the calendar Favorites live in the main model).
    guard let controller = window.flatMap({ app.hostFactories[$0.windowID] == nil ? nil : $0 }) ?? app.frontMainModelWindowController,
          let factory = app.hostFactories[controller.windowID] else { return }
    factory.openMeetingLink(state.link, from: "liveCalendar", event: state.event)
  }

  /// The reminder: a toast in the front window with Join. GUESS — capture pending (F2 item 7): Arc shows a
  /// reminder card at the Favorite tile with Join, Dismiss and the interval picker.
  private func remind(_ state: LiveCalendar.TileState, in controller: BrowserWindowController) {
    #if OPEN_AUTOMATION
    reminders.append(["event": state.event.id, "subtitle": state.subtitle, "at": app.calendar.now.timeIntervalSince1970,
                      "window": controller.windowID.description])
    #endif
    let start = state.event.start.timeIntervalSince(app.calendar.now)
    let when = start >= 60 ? "Starts in \(Int((start / 60).rounded(.up)))m" : (start > -60 ? "Starting now" : "Started \(Int(-start / 60))m ago")
    let content = ToastContent(title: state.event.displayTitle, subtitle: "\(when) · \(state.link.serviceName)", symbol: "video",
      accessory: .button(symbol: "video.fill", accessibilityLabel: "Join"), lifetime: 60, coalescingKey: "live-calendar")
    controller.toasts.show(content) { [weak self, weak controller] handle in
      handle.dismiss()
      self?.join(state, in: controller)
    }
  }
}
