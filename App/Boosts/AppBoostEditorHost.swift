import AppKit
import OpenBoosts
import OpenModel
import OpenSiteControl

@MainActor
final class AppBoostEditorHost: BoostEditorHost {
  unowned let boosts: AppBoosts
  private var pickerObservers: [SiteControlObservationToken: @MainActor (ItemID, BoostPickerEvent) -> Void] = [:]
  init(boosts: AppBoosts) { self.boosts = boosts }
  func store(for profile: ProfileID) -> BoostStore { boosts.store(for: profile) }
  func preview(_ boost: Boost, tabID: ItemID) {
    guard let host = boosts.factory(for: tabID)?.hosts[tabID] else { return }
    // BoostEditorSession coalesces pointer updates to <= 60 Hz, bound page only.
    boosts.adapter.preview(boost, host: host)
  }
  func refresh(profile: ProfileID) { boosts.refresh(profile: profile) }
  func pageSnapshot(tabID: ItemID) async -> Data? {
    guard let host = boosts.factory(for: tabID)?.hosts[tabID], !host.closed else { return nil }
    return try? await host.content.takeSnapshot()
  }
  // Blocked on P7: isolated world and a native page-message channel.
  func enterZap(boostID: BoostID, tabID: ItemID) -> Bool { false }
  func exitZap(tabID: ItemID) {}
  func removeZapFromSession(_ selector: String, tabID: ItemID) {}
  func requestZapCounts(tabID: ItemID) {}
  func observePickerEvents(_ observer: @escaping @MainActor (ItemID, BoostPickerEvent) -> Void) -> SiteControlObservationToken {
    let token = SiteControlObservationToken(); pickerObservers[token] = observer; return token
  }
  func removePickerObserver(_ token: SiteControlObservationToken) { pickerObservers[token] = nil }
  func setDevToolsVisible(_ visible: Bool, tabID: ItemID) {
    guard let page = boosts.factory(for: tabID)?.hosts[tabID]?.content else { return }
    if visible { page.showDevTools() } else { page.closeDevTools() }
  }
  func reload(tabID: ItemID) { boosts.factory(for: tabID)?.hosts[tabID]?.reload() }
  func currentURL(tabID: ItemID) -> URL? { boosts.factory(for: tabID)?.hosts[tabID]?.content.url }
  func showBoostsLibrary(profileID: ProfileID) {
    boosts.app.settingsPresenter.showLibrary(section: .boosts)
    boosts.app.settingsPresenter.library?.historyProfileID = profileID
  }
  func browserWindowFrame(tabID: ItemID) -> NSRect? { boosts.factory(for: tabID)?.window?.frame }
}
