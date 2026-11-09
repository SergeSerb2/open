#if OPEN_AUTOMATION && DEBUG
import Foundation
import OpenAdBlock
import OpenModel

/// Observe the production notification in the real App. This seam also builds
/// on the pre-fix main baseline, which has no didChange declaration.
@MainActor
private final class AdBlockLifecycleObservation {
  private var token: (any NSObjectProtocol)?
  private(set) var notifications: [[String: Bool]] = []

  init(store: AdBlockStore, profile: ProfileID) {
    token = NotificationCenter.default.addObserver(forName: Notification.Name("OpenAdBlockStoreDidChange"), object: nil, queue: .main) { [weak self, weak store] note in
      let changedStore = note.object as? AdBlockStore
      MainActor.assumeIsolated {
        guard let self, let store, changedStore === store else { return }
        if self.notifications.count < 16 {
          self.notifications.append(["open": store.isProfileOpen(profile),
            "snapshotEnabled": store.siteSnapshot(for: profile).isEnabled])
        }
      }
    }
  }

  isolated deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

extension AutomationController {
  func settingsAdBlockLifecycle(_ args: [String: Any]) async throws -> [String: Any] {
    guard Set(args.keys).isSubset(of: ["profile", "action"]),
      let raw = args["profile"] as? String,
      let profile = app.model.profiles.first(where: { $0.id.description == raw }),
      let store = app.stores.existingAdBlock else { throw Failure(message: "expected an existing Profile and store") }
    let observation = AdBlockLifecycleObservation(store: store, profile: profile.id)
    switch args["action"] as? String ?? "state" {
    case "state": break
    case "close": try store.closeProfile(profile.id)
    case "open": try await store.openProfile(profile.id,
      directory: app.directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName), scheduleUpdates: false)
    case "retire": await store.retireProfile(profile.id)
    default: throw Failure(message: "unknown ad-block lifecycle action")
    }
    return ["open": store.isProfileOpen(profile.id), "retired": store.isRetired(profile.id),
      "snapshotEnabled": store.siteSnapshot(for: profile.id).isEnabled,
      "didChangeCount": observation.notifications.count, "notifications": observation.notifications]
  }
}
#endif
