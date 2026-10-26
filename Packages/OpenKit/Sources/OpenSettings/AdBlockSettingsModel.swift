import Foundation
import Observation
import OpenModel
import OpenAdBlock

@MainActor @Observable public final class AdBlockSettingsModel {
    unowned let root: SettingsViewModel
    public let store: AdBlockStore
    public var query = ""
    public var hostDraft = ""
    public var errorText = ""
    public var busy = false
    public var revision = 0
    public var hasOtherBlocker = false
    public init(root: SettingsViewModel, store: AdBlockStore) { self.root = root; self.store = store }
    public var profileID: ProfileID { root.selectedProfileID }
    public var enabled: Bool { _ = revision; return store.isEnabled }
    public var enabledIDs: [String] { _ = revision; return store.enabledListIDs(for: profileID) }
    public var domains: [String] { _ = revision; return store.excludedDomains(for: profileID) }
    public var lists: [BlockList] { store.catalog.lists.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) } }
    public var lastError: String? { _ = revision; return store.lastError(for: profileID) }
    public func setEnabled(_ on: Bool) {
        do { try store.setEnabled(on); revision &+= 1; root.actions.setAdBlockEnabled(on, profileID: profileID); errorText = "" }
        catch { errorText = "Could not save ad blocking. \(error)" }
    }
    public func setList(_ id: String, enabled: Bool) async {
        guard !busy else { return }; busy = true; let profile = profileID; defer { busy = false; revision &+= 1 }
        do { try await store.setListEnabled(id, enabled, profile: profile); root.actions.setEnabledBlockLists(store.enabledListIDs(for: profile), profileID: profile); errorText = "" }
        catch { errorText = "Could not update this list. \(error)" }
    }
    public func setExcluded(_ host: String, excluded: Bool) {
        // Validate host-only before the store normalizes it to a registrable domain.
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), !host.contains(":"), !host.contains("/"), !host.contains("?"), !host.contains("#"), !host.contains("@") else { errorText = "Enter a host only, such as example.com."; return }
        do { try store.setExcluded(host, excluded: excluded, profile: profileID); revision &+= 1; root.actions.setAdBlockExcludedDomains(store.excludedDomains(for: profileID), profileID: profileID); errorText = ""; hostDraft = "" }
        catch { errorText = "Enter a valid site host. \(error)" }
    }
    public func reset() async {
        guard !busy else { return }; busy = true; let profile = profileID; defer { busy = false; revision &+= 1 }
        do { try await store.resetListChoices(profile: profile); root.actions.setEnabledBlockLists(store.enabledListIDs(for: profile), profileID: profile); errorText = "" }
        catch { errorText = "Could not reset list choices. \(error)" }
    }
    public func listStatus(_ list: BlockList) -> String {
        _ = revision
        let file = store.listDirectory(for: profileID).appendingPathComponent("catalog-state.json")
        let state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AdBlockProfileState.self, from: $0) }
        return state?.lists[list.id] != nil ? (list.bundled ? "Bundled" : "Downloaded") : "Not downloaded"
    }
    public func copyDebug() { root.actions.copyText(store.debugInfo(profile: profileID) + "\n" + root.actions.adBlockDebugInfo(profileID: profileID)) }
}
