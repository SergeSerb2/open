#if OPEN_AUTOMATION
import AppKit
import OpenSettings
import OpenSidebar
import OpenSync

/// `sync` automation command: drives the real `SyncEngine` of this App (docs/automation.md).
/// Engine failures come back as `{ok: false, error, code, snapshot}` so suites can assert codes.
extension AutomationController {
  func handleSyncCommand(_ args: [String: Any]) async throws -> [String: Any] {
    let action = args["action"] as? String ?? "status"
    let allowed: [String: Set<String>] = [
      "status": [], "sign-up": ["serverURL", "email", "password", "displayName"],
      "sign-in": ["serverURL", "email", "password", "strategy"], "complete-initial-sync": ["strategy"],
      "sync-now": [], "set-category": ["category", "enabled"],
      "change-password": ["currentPassword", "newPassword", "revokeOtherSessions"],
      "recover": ["serverURL", "email", "recoveryKey", "newPassword", "strategy"],
      "devices": [], "revoke-device": ["deviceId"], "sign-out": [], "delete-account": ["password"],
      "wait-revision": ["minRevision", "timeoutMs"], "open-settings": [],
    ]
    guard args["action"] == nil || args["action"] is String, let extra = allowed[action],
          Set(args.keys).isSubset(of: extra.union(["action"])) else {
      throw Failure(message: "unknown sync action or argument")
    }
    if action == "open-settings" {
      app.settingsPresenter.show(section: .accountSync, row: "account")
      return ["ok": true]
    }
    guard app.directories != nil else { throw Failure(message: "the data root is not ready") }
    let sync = app.ensureSyncCoordinator()
    let engine = sync.engine

    func string(_ key: String, required: Bool = true) throws -> String? {
      guard let value = args[key] else {
        if required { throw Failure(message: "missing \(key)") }
        return nil
      }
      guard let text = value as? String, text.utf8.count <= 4096 else { throw Failure(message: "\(key) must be a string") }
      return text
    }
    func strategy(required: Bool) throws -> FirstSyncStrategy? {
      guard let raw = try string("strategy", required: required) else { return nil }
      switch raw {
      case "replaceLocal", FirstSyncStrategy.replaceLocalWithCloud.rawValue: return .replaceLocalWithCloud
      case "merge", FirstSyncStrategy.mergeLocalAndCloud.rawValue: return .mergeLocalAndCloud
      case "replaceCloud", FirstSyncStrategy.replaceCloudWithLocal.rawValue: return .replaceCloudWithLocal
      default: throw Failure(message: "strategy must be replaceLocal, merge or replaceCloud")
      }
    }
    func errorResult(_ error: any Error) -> [String: Any] {
      let code = (error as? SyncError)?.code ?? "ERROR"
      return ["ok": false, "error": error.localizedDescription, "code": code, "snapshot": syncSnapshot(sync)]
    }
    func outcome(_ value: SyncSignInOutcome) -> [String: Any] {
      switch value {
      case .synced: return ["kind": "synced"]
      case .needsInitialChoice(let summary): return ["kind": "needsInitialChoice", "summary": Self.syncSummary(summary)]
      }
    }

    do {
      switch action {
      case "status":
        return syncSnapshot(sync).merging(["ok": true]) { $1 }
      case "sign-up":
        let key = try await engine.signUp(serverURL: try string("serverURL")!, email: try string("email")!,
                                          password: try string("password")!, displayName: try string("displayName", required: false))
        return ["ok": true, "recoveryKey": key, "snapshot": syncSnapshot(sync)]
      case "sign-in":
        let result = try await engine.signIn(serverURL: try string("serverURL")!, email: try string("email")!,
                                             password: try string("password")!, initialStrategy: try strategy(required: false))
        return ["ok": true, "outcome": outcome(result), "snapshot": syncSnapshot(sync)]
      case "complete-initial-sync":
        try await engine.completeInitialSync(strategy: try strategy(required: true)!)
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "sync-now":
        try await engine.syncNow()
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "set-category":
        guard let raw = try string("category"), let category = SyncCategory(rawValue: raw) else {
          throw Failure(message: "unknown category; expected one of \(SyncCategory.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let number = args["enabled"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
          throw Failure(message: "enabled must be a boolean")
        }
        engine.setCategoryEnabled(number.boolValue, for: category)
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "change-password":
        try await engine.changePassword(currentPassword: try string("currentPassword")!, newPassword: try string("newPassword")!,
                                        revokeOtherSessions: args["revokeOtherSessions"] as? Bool ?? false)
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "recover":
        let result = try await engine.recoverAccount(serverURL: try string("serverURL")!, email: try string("email")!,
                                                     recoveryKey: try string("recoveryKey")!, newPassword: try string("newPassword")!,
                                                     initialStrategy: try strategy(required: false))
        return ["ok": true, "recoveryKey": result.recoveryKey, "outcome": outcome(result.outcome), "snapshot": syncSnapshot(sync)]
      case "devices":
        let devices = try await engine.refreshDevices()
        return ["ok": true, "devices": devices.map(Self.syncDevice), "snapshot": syncSnapshot(sync)]
      case "revoke-device":
        try await engine.revokeDevice(deviceId: try string("deviceId")!)
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "sign-out":
        await engine.signOut()
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "delete-account":
        try await engine.deleteAccount(password: try string("password")!)
        return ["ok": true, "snapshot": syncSnapshot(sync)]
      case "wait-revision":
        guard let minimum = args["minRevision"] as? Int else { throw Failure(message: "minRevision must be an integer") }
        let timeout = min(max(args["timeoutMs"] as? Int ?? 10_000, 0), 120_000)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout) / 1000
        var reached = false
        while true {
          let snapshot = engine.snapshot
          if snapshot.lastPulledRevision >= minimum && !snapshot.isBusy { reached = true; break }
          if ProcessInfo.processInfo.systemUptime >= deadline { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return ["ok": true, "reached": reached, "snapshot": syncSnapshot(sync)]
      default:
        throw Failure(message: "unknown sync action")
      }
    } catch let failure as Failure {
      throw failure
    } catch {
      return errorResult(error)
    }
  }

  private func syncSnapshot(_ sync: AppSyncCoordinator) -> [String: Any] {
    let snapshot = sync.engine.snapshot
    var categories: [String: Bool] = [:]
    for category in SyncCategory.allCases { categories[category.rawValue] = snapshot.categories.isEnabled(category) }
    let banner: Any
    switch sync.bannerState {
    case .error(let message)?: banner = ["kind": "error", "message": message]
    case .needsReauth(let message)?: banner = ["kind": "needsReauth", "message": message]
    case .awaitingInitialChoice?: banner = ["kind": "awaitingInitialChoice"]
    case nil: banner = NSNull()
    }
    let shownInWindows = app.windowControllers.filter { $0.sidebar.syncBannerState != nil }.count
    return [
      "isSignedIn": snapshot.isSignedIn, "engineSignedIn": sync.engine.isSignedIn,
      "serverURL": snapshot.serverURL, "accountId": Self.json(snapshot.accountId), "email": Self.json(snapshot.email),
      "displayName": Self.json(snapshot.displayName), "deviceId": Self.json(snapshot.deviceId),
      "deviceName": Self.json(snapshot.deviceName), "status": snapshot.status.kind, "statusLabel": snapshot.status.label,
      "categories": categories,
      "lastSyncAt": Self.json(snapshot.lastSyncAt.map { Int64($0.timeIntervalSince1970 * 1000) }),
      "lastPulledRevision": snapshot.lastPulledRevision, "serverRevision": snapshot.lastPulledRevision,
      "devices": snapshot.devices.map(Self.syncDevice),
      "pendingExtensionInstalls": snapshot.pendingExtensionInstalls.map { pending -> [String: Any] in
        ["id": pending.id, "profileID": pending.profileID.uuidString, "extensionID": pending.extensionID, "name": pending.name,
         "isEnabled": pending.isEnabled, "isPinned": pending.isPinned, "pinnedIndex": pending.pinnedIndex]
      },
      "warnings": snapshot.warnings, "usesFileCredentialStore": snapshot.usesFileCredentialStore, "isBusy": snapshot.isBusy,
      "isAwaitingInitialChoice": snapshot.isAwaitingInitialChoice,
      "pendingInitialChoice": Self.json(snapshot.pendingInitialChoice.map(Self.syncSummary)),
      "hasBanner": sync.bannerState != nil, "bannerState": banner, "bannerWindows": shownInWindows,
    ]
  }

  private static func syncSummary(_ summary: SyncCloudSummary) -> [String: Any] {
    ["serverRevision": summary.serverRevision, "resetRevision": summary.resetRevision, "hasCloudData": summary.hasCloudData,
     "collectionCounts": summary.collectionCounts, "totalRecords": summary.totalRecords]
  }

  private static func syncDevice(_ device: SyncDeviceInfo) -> [String: Any] {
    ["deviceId": device.deviceId, "deviceName": device.deviceName, "platform": device.platform, "isCurrent": device.isCurrent,
     "lastSeenAt": json(device.lastSeenAt.map { Int64($0.timeIntervalSince1970 * 1000) })]
  }

  /// JSON null for a missing value.
  private static func json(_ value: Any?) -> Any { value ?? NSNull() }
}
#endif
