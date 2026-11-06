import Foundation
import OpenBoosts
import OpenModel
import OpenSettings

extension AppSettingsActions {
  func setBoostEnabled(id: String, enabled: Bool, profileID: ProfileID) {
    guard let uuid = UUID(uuidString: id), app.model.profile(id: profileID) != nil else { return }
    app.stores.boosts.setBoostEnabled(BoostID(rawValue: uuid), enabled: enabled, profileID: profileID)
  }
  func renameBoost(id: String, to name: String, profileID: ProfileID) {
    guard let uuid = UUID(uuidString: id), app.model.profile(id: profileID) != nil else { return }
    let store = app.stores.boosts.store(for: profileID)
    guard var boost = store.boost(id: BoostID(rawValue: uuid)) else { return }
    boost.name = name; store.upsert(boost); app.stores.boosts.refresh(profile: profileID)
  }
  func deleteBoost(id: String, profileID: ProfileID) {
    guard let uuid = UUID(uuidString: id), app.model.profile(id: profileID) != nil else { return }
    let boostID = BoostID(rawValue: uuid)
    for factory in app.hostFactories.values where factory.controller?.boostEditor?.session?.context.profileID == profileID && factory.controller?.boostEditor?.session?.boost.id == boostID {
      factory.controller?.boostEditor?.close()
    }
    if app.stores.boosts.store(for: profileID).delete(id: boostID) { app.stores.boosts.refresh(profile: profileID) }
  }
  func editBoost(id: String, profileID: ProfileID) {
    guard let uuid = UUID(uuidString: id), app.model.profile(id: profileID) != nil else { return }
    app.stores.boosts.editFromLibrary(id: BoostID(rawValue: uuid), profileID: profileID)
  }
}
