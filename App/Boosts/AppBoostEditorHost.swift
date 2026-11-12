import AppKit
import OpenBoosts
import OpenEngine
import OpenModel
import OpenSiteControl

@MainActor
final class AppBoostEditorHost: BoostEditorHost {
  unowned let boosts: AppBoosts
  private var pickerObservers: [SiteControlObservationToken: @MainActor (ItemID, BoostPickerEvent) -> Void] = [:]
  private var pickerStorage: AppBoostPicker?
  private var picker: AppBoostPicker {
    if let pickerStorage { return pickerStorage }
    let picker = AppBoostPicker(host: self); pickerStorage = picker; return picker
  }
  init(boosts: AppBoosts) { self.boosts = boosts }
  func store(for profile: ProfileID) -> BoostStore { boosts.store(for: profile) }
  func preview(_ boost: Boost, tabID: ItemID) {
    guard let host = boosts.factory(for: tabID)?.hosts[tabID] else { return }
    // BoostEditorSession coalesces pointer updates to <= 60 Hz, bound page only.
    boosts.adapter.preview(boost, host: host)
  }
  func refresh(profile: ProfileID) { boosts.refresh(profile: profile) }
  func updateScripts(profile: ProfileID) { boosts.updateScripts(profile: profile) }
  func pageSnapshot(tabID: ItemID) async -> Data? {
    guard let host = boosts.factory(for: tabID)?.hosts[tabID], !host.closed else { return nil }
    return try? await host.content.takeSnapshot()
  }
  func zapAvailability(tabID: ItemID) -> Bool {
    picker.isAvailable(tabID: tabID)
  }
  func enterZap(boostID: BoostID, tabID: ItemID) -> Bool {
    picker.enter(boostID: boostID, tabID: tabID, mode: .zap)
  }
  func enterSelectorPicker(boostID: BoostID, tabID: ItemID) -> Bool {
    picker.enter(boostID: boostID, tabID: tabID, mode: .select)
  }
  func exitZap(tabID: ItemID) { pickerStorage?.exit(tabID: tabID) }
  func selectionChanged(in factory: EngineWebContentHostFactory) {
    guard let session = factory.controller?.boostEditor?.session,
      session.context.tabID != factory.selectedTab?.id else { return }
    session.endPickerSession()
  }
  func pickerAvailabilityChanged(tabID: ItemID) {
    guard let editor = boosts.factory(for: tabID)?.controller?.boostEditor,
      editor.session?.context.tabID == tabID else { return }
    // Commit can refresh while the page is still loading. Recheck the controls
    // when loading ends, including a same-URL reload with no later URL event.
    editor.view?.refresh()
  }
  func removeZapFromSession(_ selector: String, tabID: ItemID) { pickerStorage?.remove(selector, tabID: tabID) }
  func requestZapCounts(tabID: ItemID) { pickerStorage?.requestCounts(tabID: tabID) }
  @discardableResult
  func receivePickerMessage(_ page: OEWebContent, type: String, payloadJSON: String, documentID: String) -> Bool {
    pickerStorage?.receive(page, type: type, payloadJSON: payloadJSON, documentID: documentID) ?? false
  }
  func stopPicker() { pickerStorage?.stop() }
  func publishPickerEvent(_ event: BoostPickerEvent, tabID: ItemID) {
    // Pick Selector's buttons say "Copy selector for this/related" (Arc BO-20): a validated pick
    // goes to the general pasteboard; the editor session also inserts it at the CSS caret.
    if case let .selected(selector, _) = event,
      boosts.factory(for: tabID)?.controller?.boostEditor?.session?.isSelecting == true {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(selector, forType: .string)
    }
    for observer in Array(pickerObservers.values) { observer(tabID, event) }
  }
  func observePickerEvents(_ observer: @escaping @MainActor (ItemID, BoostPickerEvent) -> Void) -> SiteControlObservationToken {
    let token = SiteControlObservationToken(); pickerObservers[token] = observer; return token
  }
  func removePickerObserver(_ token: SiteControlObservationToken) { pickerObservers[token] = nil }
  func loadedJS(boostID: BoostID, tabID: ItemID) -> String? {
    guard let host = boosts.factory(for: tabID)?.hosts[tabID] else { return nil }
    return boosts.adapter.loadedJS(boostID: boostID, host: host)
  }
  func setDevToolsVisible(_ visible: Bool, tabID: ItemID) {
    guard let page = boosts.factory(for: tabID)?.hosts[tabID]?.content else { return }
    if visible { page.showDevTools() } else { page.closeDevTools() }
  }
  func reload(tabID: ItemID) { boosts.factory(for: tabID)?.hosts[tabID]?.reload() }
  func currentURL(tabID: ItemID) -> URL? { boosts.factory(for: tabID)?.hosts[tabID]?.content.url }
  func showBoostsLibrary(profileID: ProfileID) {
    boosts.app.settingsPresenter.showLibrary(section: .boosts, boostsProfileID: profileID)
  }
  func browserWindowFrame(tabID: ItemID) -> NSRect? { boosts.factory(for: tabID)?.window?.frame }
}
