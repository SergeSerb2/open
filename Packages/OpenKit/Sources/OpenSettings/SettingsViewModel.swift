import Foundation
import Observation
import OpenModel
import OpenRouting
import OpenStore
import OpenCommands
import OpenAdBlock

@MainActor @Observable public final class SettingsViewModel {
    public typealias PaneID = OpenSettings.PaneID
    public var selectedPane: PaneID { didSet { defaults.set(selectedPane.rawValue, forKey: "open.settings.lastPane") } }
    public var selectedProfileID: ProfileID { didSet { links.littleOpenAutoArchiveAfter = model.profile(id: selectedProfileID)?.settings.littleOpenAutoArchiveAfter ?? .sixHours } }
    public let model: BrowserModel
    public let actions: any SettingsActions
    public let defaults: UserDefaults
    public let root: URL
    public let snapshot: SnapshotStore
    public var links: LinksSettingsModel
    /// Optional deep link into a long pane; used by the renderer and app presenters.
    public var scrollTarget: String?
    public var statusText = ""
    public var preferenceRevision = 0
    public var adBlock: AdBlockSettingsModel?
    @ObservationIgnored public private(set) lazy var shortcuts = ShortcutsViewModel(root: self)
    public func attach(adBlockStore: AdBlockStore) { adBlock = AdBlockSettingsModel(root: self, store: adBlockStore) }
    public var showsPreviews = false
    public var showsImport = false
    public var showsSearchEngines = false
    @ObservationIgnored public private(set) lazy var profiles = ProfilesViewModel(root: self)
    @ObservationIgnored public private(set) lazy var general = GeneralViewModel(root: self)
    @ObservationIgnored public private(set) lazy var advanced = AdvancedViewModel(root: self)
    @ObservationIgnored public private(set) lazy var appIcon = AppIconViewModel(root: self)
    public func bool(_ key: String) -> Bool { _ = preferenceRevision; return defaults.object(forKey: key) as? Bool ?? (SettingsDefaults.values[key] as? Bool ?? false) }
    public func string(_ key: String) -> String { _ = preferenceRevision; return defaults.string(forKey: key) ?? (SettingsDefaults.values[key] as? String ?? "") }
    public func set(_ value: Any, for key: String) { defaults.set(value, forKey: key); defaults.synchronize(); preferenceRevision &+= 1 }

    public init(model: BrowserModel, actions: any SettingsActions, defaults: UserDefaults, root: URL, snapshot: SnapshotStore? = nil, focusedProfileID: ProfileID? = nil) {
        SettingsDefaults.register(in: defaults)
        self.model = model; self.actions = actions; self.defaults = defaults; self.root = root
        self.snapshot = snapshot ?? SnapshotStore(root: root)
        selectedPane = PaneID(rawValue: defaults.string(forKey: "open.settings.lastPane") ?? "") ?? .general
        selectedProfileID = focusedProfileID ?? model.windows.first.flatMap { model.space(id: $0.focusedSpaceID)?.profileID } ?? model.defaultProfile?.id ?? ProfileID()
        links = LinksSettingsModel(snapshot: RoutingSnapshot(spaces: model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) }, windows: model.windows.map { RoutingWindowSnapshot(id: $0.id, kind: $0.style == .littleOpen ? .littleOpen : .standard, focusedSpaceID: $0.focusedSpaceID) }, rules: model.routingRules, defaultDestination: model.defaultDestination, externalLinksInLittleOpen: defaults.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true), spaces: model.spaces.map { SpaceOption(id: $0.id, title: model.displayTitle(for: $0)) }, isDefaultBrowser: actions.isDefaultBrowser(), defaults: defaults)
        refreshLinks()
    }
    public var shortcutsStore: KeyBindingStore { (try? KeyBindingStore.load(from: root.appendingPathComponent("State/keybindings.json"))) ?? .empty }
    public var routingSpaces: [RoutingSpaceSnapshot] { model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) } }
    public func commitLinks() {
        let oldHotkey = bool("open.links.littleOpenHotkeyEnabled")
        set(links.externalLinksInLittleOpen, for: "open.links.externalInLittleOpen")
        set(links.littleOpenHotkeyEnabled, for: "open.links.littleOpenHotkeyEnabled")
        set(links.optionCommandClickLittleOpen, for: "open.links.optionCommandClickLittleOpen")
        if oldHotkey != links.littleOpenHotkeyEnabled { actions.keyBindingsDidChange(store: shortcutsStore) }
        if let profile = model.profile(id: selectedProfileID), profile.settings.littleOpenAutoArchiveAfter != links.littleOpenAutoArchiveAfter {
            var settings = profile.settings; settings.littleOpenAutoArchiveAfter = links.littleOpenAutoArchiveAfter
            model.updateProfileSettings(id: selectedProfileID, settings: settings); save()
        }
        guard !links.issues().contains(where: \.isError) else { return }
        let copy = links.currentRouting(); model.routingRules = copy.rules; model.defaultDestination = copy.defaultDestination; save()
    }
    public func refreshLinks(preserveDrafts: Bool = false) {
        let previous = links
        links = LinksSettingsModel(snapshot: RoutingSnapshot(spaces: model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) }, windows: [], rules: model.routingRules, defaultDestination: model.defaultDestination, externalLinksInLittleOpen: bool("open.links.externalInLittleOpen")), spaces: model.spaces.map { SpaceOption(id: $0.id, title: model.displayTitle(for: $0)) }, isDefaultBrowser: actions.isDefaultBrowser(), defaults: defaults)
        links.littleOpenHotkeyEnabled = bool("open.links.littleOpenHotkeyEnabled")
        links.optionCommandClickLittleOpen = bool("open.links.optionCommandClickLittleOpen")
        links.littleOpenAutoArchiveAfter = model.profile(id: selectedProfileID)?.settings.littleOpenAutoArchiveAfter ?? .sixHours
        if preserveDrafts {
            links.drafts = previous.drafts; links.defaultDestinationKind = previous.defaultDestinationKind; links.defaultSpaceID = previous.defaultSpaceID
            links.testURLString = previous.testURLString; links.testSourceBundleID = previous.testSourceBundleID; links.testMostRecentSpaceID = previous.testMostRecentSpaceID
            if previous.testDecision != nil { links.runTest() }
        }
    }
    public func refreshExternalState() { general.refresh(); profiles.refresh(); adBlock?.refresh(); refreshLinks(preserveDrafts: true) }
    public func save() { snapshot.scheduleSave(model: model) }
    public func flush() throws { try snapshot.saveNow(model: model) }
}
