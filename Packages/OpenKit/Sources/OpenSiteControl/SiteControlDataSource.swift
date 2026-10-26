import AppKit
import OpenModel
import OpenBoosts

@MainActor public protocol SiteControlDataSource: AnyObject {
    func snapshot(for tabID: ItemID) -> SiteControlSnapshot?
    var onChange: (@MainActor (ItemID) -> Void)? { get set }
}

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
    var onPickerEvent: (@MainActor (ItemID, BoostPickerEvent) -> Void)? { get set }
    func setDevToolsVisible(_ visible: Bool, tabID: ItemID)
    func reload(tabID: ItemID)
    func currentURL(tabID: ItemID) -> URL?
}
