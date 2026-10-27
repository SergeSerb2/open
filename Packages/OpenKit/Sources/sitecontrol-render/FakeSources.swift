import AppKit
import OpenModel
import OpenBoosts
import OpenSiteControl
import OpenWeb

@MainActor
final class FakeSource: SiteControlDataSource, SiteControlActions {
    let tabID = ItemID()
    let profileID = ProfileID()
    var value: SiteControlSnapshot?
    var calls: [String] = []
    var observers: [SiteControlObservationToken: @MainActor (ItemID) -> Void] = [:]
    func observeChanges(_ observer: @escaping @MainActor (ItemID) -> Void) -> SiteControlObservationToken {
        let token = SiteControlObservationToken(); observers[token] = observer; return token
    }
    func removeChangeObserver(_ token: SiteControlObservationToken) { observers.removeValue(forKey: token) }
    func changed() { for observer in Array(observers.values) { observer(tabID) } }
    init() {
        value = SiteControlSnapshot(context: SiteControlContext(tabID: tabID, profileID: profileID,
            url: URL(string: "https://news.example.com/")!, displayHost: "news.example.com", security: .secure),
            commandsEnabled: ["capture-page": true, "capture-full-page": true, "share-page": true])
        configure("scc-no-boosts")
    }
    func configure(_ state: String) {
        let blocking = SiteSettingTile(id: "contentBlocking",kind: .contentBlocking,title: "Block Ads & Trackers",subtitle: "On",state: .on,symbol: "hand.raised.fill",help: "The built-in ad blocker is on for this site.")
        let pip = SiteSettingTile(id: "content.automaticPictureInPicture",kind: .content("automaticPictureInPicture"),title: "Automatic Picture-In-Picture",subtitle: "Allowed",state: .on,symbol: "gearshape.fill")
        value?.tiles = [blocking,pip]
        value?.boosts = []
        if ["scc-boost","scc-boosts-off","scc-incognito","scc-hover-boost","scc-focus-boost","scc-tooltip-private"].contains(state) {
            value?.boosts = [Boost(id: BoostID(uuidString: "00000000-0000-0000-0000-000000000001"),name: "My Boost",siteMatch: SiteMatch(domain: "example.com"))]
        }
        switch state {
        case "scc-reload": break
        case "scc-insecure": value?.context.url = URL(string: "http://news.example.com/")!; value?.context.security = .insecure
        case "scc-adblock-excluded","scc-tooltip-off": value?.tiles[0].state = .off; value?.tiles[0].subtitle = "Off"; value?.tiles[0].help = "The built-in ad blocker is off for this site."
        case "scc-adblock-unavailable","scc-tooltip-unavailable": value?.tiles[0].state = .unavailable; value?.tiles[0].subtitle = "Off"; value?.tiles[0].help = "The built-in ad blocker is off. You can turn it on in Settings."
        case "scc-no-boosts": value?.boosts = []
        case "scc-boosts-off": value?.boostsGloballyEnabled = false
        case "scc-incognito","scc-tooltip-private": value?.context.isIncognito = true
        case "scc-internal-page": value?.context.url = URL(string: "open://settings")!; value?.context.displayHost = "Settings"; value?.context.security = .insecure
        case "scc-many":
            let names = ["Camera", "Microphone", "Location", "Notifications", "Clipboard", "MIDI Devices", "Screen Sharing", "Automatic Downloads", "Storage Access", "Window Management", "Fonts", "Idle Detection"]
                value?.tiles = [blocking] + SitePermission.allCases.prefix(11).enumerated().map { i, kind in
                SiteSettingTile(id: "permission.\(kind)", kind: .permission(kind), title: names[i], subtitle: "Allowed", state: .on, symbol: ["video.fill","mic.fill","location.fill","bell.fill","doc.on.clipboard.fill","pianokeys","rectangle.on.rectangle","arrow.down.circle.fill","externaldrive.fill","macwindow.on.rectangle","textformat","moon.zzz.fill"][i]) }
            value?.boosts = (0..<20).map { Boost(id: BoostID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1)), name: "Boost \($0 + 1)", siteMatch: SiteMatch(domain: "example.com")) }
        default: break
        }
    }
    func snapshot(for tabID: ItemID) -> SiteControlSnapshot? { tabID == self.tabID ? value : nil }
    func toggle(_ tile: SiteSettingTile, tabID: ItemID) {
        calls.append("toggle:" + tile.id)
        if let index = value?.tiles.firstIndex(where: { $0.id == tile.id }) {
            let on = tile.state != .on
            value?.tiles[index].state = on ? .on : .off
            value?.tiles[index].subtitle = tile.kind == .contentBlocking ? (on ? "On" : "Off") : (on ? "Allowed" : "Blocked")
        }
        changed()
    }
    func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID) {
        calls.append("boost:\(id):\(enabled)")
        if let index = value?.boosts.firstIndex(where: { $0.id == id }) { value?.boosts[index].isEnabled = enabled }
        changed()
    }
    func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) { calls.append("editor:\(boostID?.description ?? "new")") }
    func perform(command: String, tabID: ItemID, anchor: NSRect?) { calls.append(command) }
    func runExtension(_ id: String, tabID: ItemID, anchor: NSRect) { calls.append("extension:" + id) }
    func setExtensionPinned(_ id: String, pinned: Bool) { calls.append("pin:" + id) }
    func showSecurityDetails(tabID: ItemID) { calls.append("security") }
    func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID) { calls.append("clear:\(kinds.rawValue)") }
    func openURLInNewTab(_ url: URL, tabID: ItemID) { calls.append("url:" + url.absoluteString) }
    func reload(tabID: ItemID) { calls.append("reload") }
    func openAdBlockSettings(tabID: ItemID) { calls.append("settings:advanced:adblock") }
}
