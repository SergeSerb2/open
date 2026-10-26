import AppKit
import OpenModel
import OpenBoosts
import OpenSiteControl

@MainActor
final class FakeSource: SiteControlDataSource, SiteControlActions {
    let tabID = ItemID()
    let profileID = ProfileID()
    var value: SiteControlSnapshot?
    var calls: [String] = []
    var onChange: (@MainActor (ItemID) -> Void)?
    init() {
        value = SiteControlSnapshot(context: SiteControlContext(tabID: tabID, profileID: profileID,
            url: URL(string: "https://news.example.com/")!, displayHost: "news.example.com", security: .secure))
    }
    func snapshot(for tabID: ItemID) -> SiteControlSnapshot? { tabID == self.tabID ? value : nil }
    func toggle(_ tile: SiteSettingTile, tabID: ItemID) { calls.append("toggle:" + tile.id) }
    func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID) { calls.append("boost:\(id):\(enabled)") }
    func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) { calls.append("editor:\(boostID?.description ?? "new")") }
    func perform(command: String, tabID: ItemID, anchor: NSRect?) { calls.append(command) }
    func runExtension(_ id: String, tabID: ItemID, anchor: NSRect) { calls.append("extension:" + id) }
    func setExtensionPinned(_ id: String, pinned: Bool) { calls.append("pin:" + id) }
    func showSecurityDetails(tabID: ItemID) { calls.append("security") }
    func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID) { calls.append("clear:\(kinds.rawValue)") }
    func openURLInNewTab(_ url: URL, tabID: ItemID) { calls.append("url:" + url.absoluteString) }
    func reload(tabID: ItemID) { calls.append("reload") }
}
