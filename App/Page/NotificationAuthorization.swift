import AppKit
import UserNotifications

/// macOS authorization for Open's web notifications (page-platform §4.5.3).
///
/// Chromium shows web notifications through `UNUserNotificationCenter` and
/// owns its delegate (D-4, `mac_notification_service_un.mm`). This type only
/// reads the notification settings and asks macOS for authorization. It never
/// sets `UNUserNotificationCenter.delegate`.
///
/// Created on first use (the first site the user allows, or the first read
/// from Site Control). From then on it re-reads the status each time Open
/// becomes active, because the user can change it in System Settings. No
/// timer: one settings read per app activation.
@MainActor
final class NotificationAuthorization {
  static let shared = NotificationAuthorization()

  enum Status: String, Sendable {
    /// Not read yet.
    case unknown
    case notDetermined, denied, authorized, provisional, ephemeral

    init(_ status: UNAuthorizationStatus) {
      switch status {
      case .notDetermined: self = .notDetermined
      case .denied: self = .denied
      case .authorized: self = .authorized
      case .provisional: self = .provisional
      case .ephemeral: self = .ephemeral
      @unknown default: self = .unknown
      }
    }
  }

  /// Posted on the main thread after `status` changes.
  static let didChangeNotification = Notification.Name("OpenNotificationAuthorizationDidChange")

  /// Section 12 hook: the Site Control notifications tile shows `deniedLine`
  /// and a button titled `openSettingsTitle` while `isDenied` is true. The
  /// button calls `openSystemSettings()`. Copy is Open's (§4.5.3).
  static let deniedLine = "Notifications are off for Open in System Settings."
  static let openSettingsTitle = "Open System Settings"

  private(set) var status: Status = .unknown
  var isDenied: Bool { status == .denied }

  static var systemSettingsURL: URL {
    let id = Bundle.main.bundleIdentifier ?? "io.github.sergeserb2.open"
    return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
  }

  func openSystemSettings() { NSWorkspace.shared.open(Self.systemSettingsURL) }

  private var activationObserver: (any NSObjectProtocol)?
  private var requestInFlight = false
  #if OPEN_AUTOMATION
    /// One entry per `userAllowedNotifications()` call: `requested`,
    /// `suppressed` (an e2e run that must not show the macOS prompt), or
    /// `skipped:<status>` (macOS already answered).
    private(set) var requestLog: [String] = []
    /// `OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record`: log the request
    /// instead of showing the macOS prompt (the `page` suite, unless the user
    /// runs U-N1).
    let suppressesRequests = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION"] == "record"
  #endif

  private init() {
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { NotificationAuthorization.shared.refresh() }
    }
    refresh()
  }

  /// Reads the status again.
  func refresh() {
    Task { await self.readStatus() }
  }

  /// Reads the status now and returns it.
  @discardableResult
  func readStatus() async -> Status {
    let raw = await Self.authorizationStatus()
    update(Status(raw))
    return status
  }

  /// The user picked Allow for a site's notifications: the permission prompt
  /// or Site Control. While macOS has not been asked, ask it once now (Arc
  /// does the same, PG-5.2). The site permission is stored either way.
  func userAllowedNotifications() {
    Task { await self.requestIfNotDetermined() }
  }

  private func requestIfNotDetermined() async {
    let current = await readStatus()
    guard current == .notDetermined, !requestInFlight else {
      #if OPEN_AUTOMATION
        requestLog.append(requestInFlight ? "skipped:inFlight" : "skipped:\(current.rawValue)")
      #endif
      return
    }
    #if OPEN_AUTOMATION
      if suppressesRequests {
        requestLog.append("suppressed")
        return
      }
      requestLog.append("requested")
    #endif
    requestInFlight = true
    await Self.requestAuthorization()
    requestInFlight = false
    await readStatus()
  }

  private func update(_ new: Status) {
    guard new != status else { return }
    status = new
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
  }

  nonisolated private static func requestAuthorization() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
        continuation.resume()
      }
    }
  }
}
