import AppKit
import OpenModel
import OpenBoosts

@MainActor public protocol SiteControlDataSource: AnyObject {
    func snapshot(for tabID: ItemID) -> SiteControlSnapshot?
    /// Each registration is independent. Remove its token when the window closes.
    func observeChanges(_ observer: @escaping @MainActor (ItemID) -> Void) -> SiteControlObservationToken
    func removeChangeObserver(_ token: SiteControlObservationToken)
}

/// Synchronous callbacks may close or replace their caller. The controller keeps
/// itself alive during each call, binds the tab, and rechecks its presentation
/// generation before applying any callback-dependent UI changes.
@MainActor public protocol SiteControlActions: AnyObject {
    func toggle(_ tile: SiteSettingTile, tabID: ItemID)
    func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID)
    func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode)
    func perform(command: String, tabID: ItemID, anchor: NSRect?)
    func runExtension(_ id: String, tabID: ItemID, anchor: NSRect)
    func setExtensionPinned(_ id: String, pinned: Bool)
    func showSecurityDetails(tabID: ItemID)
    func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID)
    func openURLInNewTab(_ url: URL, tabID: ItemID)
    func reload(tabID: ItemID)
    func openAdBlockSettings(tabID: ItemID)
}

@MainActor public protocol BoostEditorHost: AnyObject {
    func store(for profile: ProfileID) -> BoostStore
    func preview(_ boost: Boost, tabID: ItemID)
    func refresh(profile: ProfileID)
    func pageSnapshot(tabID: ItemID) async -> Data?
    func enterZap(boostID: BoostID, tabID: ItemID) -> Bool
    func exitZap(tabID: ItemID)
    func removeZapFromSession(_ selector: String, tabID: ItemID)
    func requestZapCounts(tabID: ItemID)
    /// Fan out validated picker events to every registered editor session.
    func observePickerEvents(_ observer: @escaping @MainActor (ItemID, BoostPickerEvent) -> Void) -> SiteControlObservationToken
    func removePickerObserver(_ token: SiteControlObservationToken)
    func setDevToolsVisible(_ visible: Bool, tabID: ItemID)
    func reload(tabID: ItemID)
    func currentURL(tabID: ItemID) -> URL?
}
