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
    @ObservationIgnored private var knownProfiles: Set<ProfileID> = []
    @ObservationIgnored private var openings: [ProfileID: Task<Void, any Error>] = [:]
    public init(root: SettingsViewModel, store: AdBlockStore) { self.root = root; self.store = store; knownProfiles=Set(root.model.profiles.map(\.id)); refresh() }
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
    public func openSelectedProfile() async {
        let profile = profileID
        guard root.model.profile(id: profile) != nil else { return }
        let task: Task<Void, any Error>
        if let existing = openings[profile] { task = existing }
        else { let store = self.store; task = Task { try await store.openProfile(profile) }; openings[profile] = task }
        do {
            try await task.value
            if root.model.profile(id: profile) == nil { try store.closeProfile(profile) }
            else if profileID == profile { errorText = "" }
            revision &+= 1
        } catch { if profileID == profile { errorText = "Could not open ad block settings. \(error)" } }
        openings[profile] = nil
    }
    public func closeProfile(_ id: ProfileID) throws {
        // Engine callbacks may synchronously refresh Settings. Remove the identity first,
        // so an externally deleted profile cannot recursively close itself on .closed.
        let wasKnown = knownProfiles.remove(id) != nil
        do { try store.closeProfile(id); knownProfiles.remove(id); revision &+= 1 }
        catch { if wasKnown { knownProfiles.insert(id) }; throw error }
    }
    public func setExcluded(_ host: String, excluded: Bool) {
        // Validate host-only before the store normalizes it to a registrable domain.
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), !host.contains(":"), !host.contains("/"), !host.contains("?"), !host.contains("#"), !host.contains("@") else { errorText = "Enter a host only, such as example.com."; return }
        do { _ = try AdBlockSites.shared.registrableDomain(host) }
        catch { errorText = String(describing:error).contains("resource unavailable") ? "Could not validate allowed sites. \(error)" : "Enter a valid site host."; return }
        do { try store.setExcluded(host, excluded: excluded, profile: profileID); revision &+= 1; root.actions.setAdBlockExcludedDomains(store.excludedDomains(for: profileID), profileID: profileID); errorText = ""; hostDraft = "" }
        catch { errorText = "Could not save allowed sites. \(error)" }
    }
    public func reset() async {
        guard !busy else { return }; busy = true; let profile = profileID; defer { busy = false; revision &+= 1 }
        do { try await store.resetListChoices(profile: profile); root.actions.setEnabledBlockLists(store.enabledListIDs(for: profile), profileID: profile); errorText = "" }
        catch { errorText = "Could not reset list choices. \(error)" }
    }
    public func refresh() {
        let current=Set(root.model.profiles.map(\.id))
        for id in knownProfiles.subtracting(current) { do {try closeProfile(id)} catch {errorText="Could not close ad block settings. \(error)"} }
        knownProfiles.formUnion(current);revision &+= 1
        Task { await openSelectedProfile() }
    }
    public func listStatus(_ list: BlockList) -> String {
        _ = revision
        guard let receipt = store.listReceipt(list.id, profile: profileID) else { return "Not downloaded" }
        return list.bundled && receipt.sources.isEmpty ? "Bundled" : "Downloaded"
    }
    public func openInfo(_ list: BlockList) { root.actions.openURL(list.infoURL, profileID: profileID) }
    public func copyDebug() { root.actions.copyText(store.debugInfo(profile: profileID) + "\n" + root.actions.adBlockDebugInfo(profileID: profileID)) }
}
