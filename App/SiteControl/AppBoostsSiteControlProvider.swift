import OpenBoosts
import OpenModel
import OpenSiteControl

/// Site Control forwards to the App's sole per-Profile Boost owner.
extension AppBoosts: SiteControlBoostProvider {
  func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) {
    openEditor(boostID: boostID, tabID: tabID, mode: mode, committedURL: nil)
  }
}
