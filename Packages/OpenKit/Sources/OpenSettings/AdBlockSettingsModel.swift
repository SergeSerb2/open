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
    public private(set) var openedProfiles: Set<ProfileID> = []
    public var isReady: Bool { openedProfiles.contains(profileID) && !store.isRetired(profileID) }
    @ObservationIgnored private var knownProfiles: Set<ProfileID> = []
    @ObservationIgnored private var openings: [ProfileID: Task<Void, any Error>] = [:]
    @ObservationIgnored private let directoryForProfile: @MainActor (Profile) -> URL
    public init(root: SettingsViewModel, store: AdBlockStore, directoryForProfile: @escaping @MainActor (Profile) -> URL) {
        self.root = root; self.store = store; self.directoryForProfile = directoryForProfile
        knownProfiles=Set(root.model.profiles.map(\.id)); refresh()
    }
    public var profileID: ProfileID { root.selectedProfileID }
    public var enabled: Bool { _ = revision; return store.isEnabled }
    public var enabledIDs: [String] { _ = revision; return isReady ? store.enabledListIDs(for: profileID) : [] }
    public var domains: [String] { _ = revision; return isReady ? store.excludedDomains(for: profileID) : [] }
    public var lists: [BlockList] { store.catalog.lists.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) } }
    private var unavailableText: String { store.isRetired(profileID) ? "This Profile was deleted." : "Ad block settings are still loading for this Profile." }
    public var lastError: String? { _ = revision; return store.lastError(for: profileID) == nil ? nil : "The last list update failed. Your previous lists are still active." }
    public func setEnabled(_ on: Bool) {
        guard !store.isRetired(profileID) else { errorText = unavailableText; return }
        do { try store.setEnabled(on); revision &+= 1; root.actions.setAdBlockEnabled(on, profileID: profileID); errorText = "" }
        catch { errorText = "Could not save ad blocking. Try again when your data folder is available." }
    }
    public func setList(_ id: String, enabled: Bool) async {
        guard isReady else {errorText=unavailableText;return}
        guard !busy else { return }; busy = true; let profile = profileID; defer { busy = false; revision &+= 1 }
        do { try await store.setListEnabled(id, enabled, profile: profile); root.actions.setEnabledBlockLists(store.enabledListIDs(for: profile), profileID: profile); errorText = "" }
        catch { errorText = plainError(error, fallback:"This list could not be updated. Check your connection and try again.") }
    }
    public func openSelectedProfile() async {
        let root = self.root
        let profile = profileID
        guard let selected = root.model.profile(id: profile), !store.isRetired(profile) else { return }
        let task: Task<Void, any Error>
        if let existing = openings[profile] { task = existing }
        else {
            let store = self.store
            let directory = directoryForProfile(selected)
            task = Task { try await store.openProfile(profile, directory: directory) }; openings[profile] = task
        }
        do {
            try await task.value
            if root.model.profile(id: profile) == nil || store.isRetired(profile) { try store.closeProfile(profile) }
            else {openedProfiles.insert(profile); if profileID == profile { errorText = "" }}
            revision &+= 1
        } catch { if profileID == profile { errorText = plainError(error,fallback:"Ad block settings could not be opened. Try opening this Profile again.") } }
        openings[profile] = nil
    }
    public func closeProfile(_ id: ProfileID) throws {
        // Engine callbacks may synchronously refresh Settings. Remove the identity first,
        // so an externally deleted profile cannot recursively close itself on .closed.
        let wasKnown = knownProfiles.remove(id) != nil; openedProfiles.remove(id)
        do { try store.closeProfile(id); knownProfiles.remove(id); revision &+= 1 }
        catch { if wasKnown && root.model.profile(id: id) != nil && !store.isRetired(id) { knownProfiles.insert(id) }; throw error }
    }
    public func setExcluded(_ host: String, excluded: Bool) {
        guard isReady else {errorText=unavailableText;return}
        // Validate host-only before the store normalizes it to a registrable domain.
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), !host.contains(":"), !host.contains("/"), !host.contains("?"), !host.contains("#"), !host.contains("@") else { errorText = "Enter a host only, such as example.com."; return }
        do { _ = try AdBlockSites.shared.registrableDomain(host) }
        catch { errorText = String(describing:error).contains("resource unavailable") ? "Allowed sites could not be checked. Try again when ad blocking is ready." : "Enter a valid site host."; return }
        do { try store.setExcluded(host, excluded: excluded, profile: profileID); revision &+= 1; root.actions.setAdBlockExcludedDomains(store.excludedDomains(for: profileID), profileID: profileID); errorText = ""; hostDraft = "" }
        catch { errorText = plainError(error,fallback:"Allowed sites could not be saved. Your last saved sites are kept.") }
    }
    public func reset() async {
        guard isReady else {errorText=unavailableText;return}
        guard !busy else { return }; busy = true; let profile = profileID; defer { busy = false; revision &+= 1 }
        do { try await store.resetListChoices(profile: profile); root.actions.setEnabledBlockLists(store.enabledListIDs(for: profile), profileID: profile); errorText = "" }
        catch { errorText = plainError(error,fallback:"List choices could not be reset. Your previous lists are still active.") }
    }
    public func refresh() {
        let current=Set(root.model.profiles.map(\.id))
        for id in knownProfiles.subtracting(current) { do {try closeProfile(id)} catch {errorText="Ad block settings are updating. Try deleting this Profile after the update finishes."} }
        knownProfiles.formUnion(current);openedProfiles.formIntersection(current);openedProfiles.remove(profileID);revision &+= 1
        Task { [weak self] in await self?.openSelectedProfile() }
    }
    private func plainError(_ error:any Error,fallback:String)->String {
        let description=String(describing:error)
        if description.contains("Profile was deleted") {return "This Profile was deleted."}
        if description.contains("profile is not open") {return "Ad block settings are still loading for this Profile."}
        if description.contains("in progress") {return "This Profile’s block lists are updating. Try again when the update finishes."}
        return fallback
    }
    public func listStatus(_ list: BlockList) -> String {
        _ = revision
        guard let receipt = store.listReceipt(list.id, profile: profileID) else { return "Not downloaded" }
        return list.bundled && receipt.sources.isEmpty ? "Bundled" : "Downloaded"
    }
    public func openInfo(_ list: BlockList) { root.actions.openURL(list.infoURL, profileID: profileID) }
    public func copyDebug() { root.actions.copyText(store.debugInfo(profile: profileID) + "\n" + root.actions.adBlockDebugInfo(profileID: profileID)) }
}
