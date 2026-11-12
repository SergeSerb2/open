import AppKit
import OpenFeatures
import OpenLiveData

/// Tabs ▸ Join Meeting (⌘⌃J, `joinLiveMeeting:`) and the command-bar actions "Join next meeting" /
/// "Join next video conference" (docs/re/live-data.md §5). Opens the next eligible event's call link
/// (`NextMeeting.pick`) in a new tab of the focused Space: Arc's default Meet route is the current Space (LD §5).
extension EngineWebContentHostFactory {
  /// Starts the join. Returns false only when no window can take the link; calendar outcomes show a toast.
  func joinMeeting() -> Bool {
    guard controller != nil, !isIncognito else { return false }
    let calendar = app.calendar
    Task { @MainActor [weak self] in
      var access = calendar.source.access
      if access == .notDetermined { access = await calendar.source.requestAccess() }
      guard let self else { return }
      guard access == .granted else { self.finishJoin(.noAccess(access)); return }
      guard let next = await calendar.nextMeeting() else { self.finishJoin(.noMeeting); return }
      self.finishJoin(.join(next.event, next.link))
    }
    return true
  }

  enum JoinMeetingOutcome {
    case join(CalendarEvent, MeetingLink)
    case noMeeting
    case noAccess(CalendarAccess)
  }

  private func finishJoin(_ outcome: JoinMeetingOutcome) {
    guard !isClosing else { return }
    var record: [String: Any] = [:]
    defer {
      #if OPEN_AUTOMATION
      record["seq"] = (lastJoinMeeting["seq"] as? Int ?? 0) + 1
      lastJoinMeeting = record
      #endif
    }
    switch outcome {
    case .join(let event, let link):
      let tab = openNewTab(url: link.url, background: false)
      record = ["outcome": "join", "event": event.id, "title": event.displayTitle, "url": link.url.absoluteString,
        "service": link.service.rawValue, "tab": tab?.id.description ?? ""]
    case .noMeeting:
      // GUESS — capture pending (F2 capture 8): Arc's no-meeting feedback. Open shows a toast.
      controller?.toasts.show(ToastContent(title: "No upcoming meetings", subtitle: "Meetings with a call link today appear here.",
        symbol: "calendar", coalescingKey: "join-meeting"))
      record = ["outcome": "noMeeting"]
    case .noAccess(let access):
      // Open's own copy (EventKit replaces Arc's "Connect Calendar" sign-in; F2 report §7 risk note).
      let content = ToastContent(title: "Allow Calendar access to join meetings",
        subtitle: access == .restricted ? "Calendar access is restricted on this Mac." : "Open reads your meetings from the Calendar app.",
        symbol: "calendar.badge.exclamationmark",
        accessory: access == .restricted ? .none : .button(symbol: "gearshape", accessibilityLabel: "Open Privacy Settings"),
        coalescingKey: "join-meeting")
      controller?.toasts.show(content) { handle in
        handle.dismiss()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
          NSWorkspace.shared.open(url)
        }
      }
      record = ["outcome": "noAccess", "access": access.rawValue]
    }
  }
}
