import AppKit
import CryptoKit
import OSLog
import Sparkle

/// App-only update core. Create after first paint; OpenKit never sees Sparkle.
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
  static let automaticKey = "open.general.automaticallyUpdate"
  static let channelKey = "open.general.updateChannel"
  #if OPEN_AUTOMATION
  static let feedOverrideKey = "open.debug.updateFeedURL"
  #endif
  static let unavailableStatus = "Updates are not set up in this build."
  private static let log = Logger(subsystem: "io.github.sergeserb2.open", category: "Updater")

  private unowned let app: AppDelegate
  private var updater: SPUUpdater?
  private var checkObservation: NSKeyValueObservation?
  private var defaultsObserver: (any NSObjectProtocol)?
  private(set) var offReason: String?
  private(set) var started = false
  private(set) var foundVersion: String?
  private(set) var completedChecks = 0
  private(set) var lastErrorCode: Int?
  /// Off builds still offer the Settings explanation. Sparkle's value is KVO forwarded.
  @objc dynamic private(set) var canCheckForUpdates = true

  var channel: String { UserDefaults.standard.string(forKey: Self.channelKey) == "beta" ? "beta" : "stable" }
  var automaticallyChecksAndDownloads: Bool {
    get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey); applyAutomaticPreference() }
  }
  private var allowsAdHoc: Bool {
    let environmentAllows = ProcessInfo.processInfo.environment["OPEN_UPDATER_ALLOW_ADHOC"] == "1"
    #if OPEN_AUTOMATION
    return environmentAllows || UserDefaults.standard.string(forKey: "OPEN_UPDATER_ALLOW_ADHOC") == "1"
    #else
    return environmentAllows
    #endif
  }

  init(app: AppDelegate) {
    self.app = app
    super.init()
    LaunchTiming.shared.mark("updaterCreated")
    // Check before constructing SPUUpdater: even its scheduler must not exist
    // in an unconfigured or unsigned build. Canonical base64 is exactly 44 bytes.
    guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      key.utf8.count == 44, let bytes = Data(base64Encoded: key), bytes.count == 32,
      bytes.base64EncodedString() == key,
      (try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)) != nil else {
      disable(reason: "invalid-public-key"); return
    }
    guard allowsAdHoc || CodeSignature.hasTeamIdentifier else {
      disable(reason: "missing-team-identifier"); return
    }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
      userDriver: Self.makeUserDriver(), delegate: self)
    self.updater = updater
    applyAutomaticPreference()
    do { try updater.start(); started = true }
    catch {
      updater.automaticallyChecksForUpdates = false
      updater.automaticallyDownloadsUpdates = false
      self.updater = nil
      disable(reason: "start-failed"); return
    }
    checkObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
      // SPUUpdater's API and KVO notifications are main-thread only.
      MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
    }
    defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyAutomaticPreference() }
    }
  }

  /// The later banner/user-driver change replaces this factory alone.
  private static func makeUserDriver() -> any SPUUserDriver {
    SPUStandardUserDriver(hostBundle: .main, delegate: nil)
  }

  private func disable(reason: String) {
    offReason = reason
    Self.log.notice("Updates are off: \(reason, privacy: .public)")
  }

  private func applyAutomaticPreference() {
    guard let updater else { return }
    let enabled = automaticallyChecksAndDownloads
    // Sparkle writes its own defaults. Avoid recursive notification writes.
    if updater.automaticallyChecksForUpdates != enabled { updater.automaticallyChecksForUpdates = enabled }
    if updater.automaticallyDownloadsUpdates != enabled { updater.automaticallyDownloadsUpdates = enabled }
  }

  func checkForUpdates() {
    guard let updater, started else { app.settingsPresenter.showUpdatesUnavailable(); return }
    guard canCheckForUpdates else { return }
    foundVersion = nil; lastErrorCode = nil
    updater.checkForUpdates()
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel == "beta" ? ["beta"] : [] }

  func feedURLString(for updater: SPUUpdater) -> String? {
    #if OPEN_AUTOMATION
    guard allowsAdHoc, let override = UserDefaults.standard.string(forKey: Self.feedOverrideKey),
      override.utf8.count <= 4096 else { return nil }
    return override
    #else
    return nil
    #endif
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    // Bound the only appcast text the shell retains, without splitting Unicode.
    foundVersion = item.versionString.utf8.count <= 128 ? item.versionString : nil
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    completedChecks += 1
    lastErrorCode = (error as NSError?)?.code
  }

  #if OPEN_AUTOMATION
  /// Read-only: observing this state never creates or starts an updater.
  var automationState: [String: Any] {
    ["created": true, "offReason": offReason ?? NSNull(), "started": started,
      "canCheck": canCheckForUpdates, "lastCheck": updater?.lastUpdateCheckDate?.timeIntervalSince1970 ?? NSNull(),
      "automaticallyChecks": updater?.automaticallyChecksForUpdates ?? false,
      "automaticallyDownloads": updater?.automaticallyDownloadsUpdates ?? false,
      "automaticPreference": automaticallyChecksAndDownloads, "channel": channel,
      "foundVersion": foundVersion ?? NSNull(), "completedChecks": completedChecks,
      "lastErrorCode": lastErrorCode ?? NSNull()]
  }
  #endif
}
