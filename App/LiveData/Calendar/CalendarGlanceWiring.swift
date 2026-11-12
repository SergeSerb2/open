import AppKit
import OpenLiveData

extension AppDelegate {
  /// The calendar card's data and actions for one window (`SidebarContext.calendarGlance`).
  /// Every closure runs on hover or click; none runs at launch.
  func makeCalendarGlance(_ factory: EngineWebContentHostFactory) -> CalendarGlanceSource {
    CalendarGlanceSource(
      access: { [weak self] in self?.calendar.source.access ?? .denied },
      events: { [weak self] in await self?.calendar.todayEvents() ?? [] },
      now: { [weak self] in self?.calendar.now ?? Date() },
      requestAccess: { [weak self] in
        guard let calendar = self?.calendar else { return .denied }
        let access = calendar.source.access
        switch access {
        case .notDetermined: return await calendar.source.requestAccess()
        case .denied: CalendarPrivacySettings.open(); return access
        case .granted, .restricted: return access
        }
      },
      join: { [weak factory] link in factory?.openMeetingLink(link, from: "card") })
  }
}

enum CalendarPrivacySettings {
  static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
  @MainActor static func open() {
    #if OPEN_AUTOMATION
    openedForAutomation += 1
    if ProcessInfo.processInfo.environment["OPEN_E2E_NO_SYSTEM_SETTINGS"] == "1" { return }
    #endif
    NSWorkspace.shared.open(url)
  }
  #if OPEN_AUTOMATION
  @MainActor static var openedForAutomation = 0
  #endif
}
