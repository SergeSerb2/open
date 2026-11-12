import Foundation
import Observation
import OpenModel
import OpenRouting
import OpenStore
import OpenCommands
import OpenAdBlock

@MainActor @Observable public final class SettingsViewModel {
    public typealias PaneID = OpenSettings.PaneID
    public var selectedPane: PaneID { didSet {
        defaults.set(selectedPane.rawValue, forKey: "open.settings.lastPane")
        if selectedSection.legacyPane != selectedPane { selectedSection = .legacy(selectedPane) }
    } }
    public var selectedSection: SettingsSection = .general { didSet {
        defaults.set(selectedSection.rawValue, forKey: "open.settings.lastSection")
        if selectedPane != selectedSection.legacyPane { selectedPane = selectedSection.legacyPane }
    } }
    public var searchQuery = "" { didSet { updateSettingsSearch() } }
    public var searchResults: [SettingsSearchEntry] = []
    public var searchSelection = 0
    public var searchCPUMilliseconds = 0.0
    public var searchFocusRequest = 0
    @ObservationIgnored var onNavigation: (() -> Void)?
    @ObservationIgnored var onUserInput: (() -> Void)?
    public var arrivalID: String?
    public var arrivalRevision = 0
    #if DEBUG || OPEN_AUTOMATION
    @ObservationIgnored public var lastSectionPresentation: [String: Double] = [:]
    @ObservationIgnored public var onSectionDraw: ((SettingsSection, Double) -> Void)?
    #endif
    public var sectionBack: [SettingsSection] = []
    public var sectionForward: [SettingsSection] = []
    public var appearanceWindowID: WindowID?
    public var showsControlsKit = false
    public var focusedSettingID: String?
    public var showsLegacyAdBlock = false
    public var archiveApplyAvailable = false
    public var selectedProfileID: ProfileID { didSet { archiveApplyAvailable = false; if !searchQuery.isEmpty { updateSettingsSearch() }; adBlock?.refresh(); links.littleOpenAutoArchiveAfter = model.profile(id: selectedProfileID)?.settings.littleOpenAutoArchiveAfter ?? .sixHours } }
    public let model: BrowserModel
    public let actions: any SettingsActions
    public let defaults: UserDefaults
    public let root: URL
    public let snapshot: SnapshotStore
    public var links: LinksSettingsModel
    @ObservationIgnored public var routingSnapshotProvider: (@MainActor () -> RoutingSnapshot)? {
        didSet { links.snapshotProvider = routingSnapshotProvider }
    }
    /// Optional deep link into a long pane; used by the renderer and app presenters.
    public var scrollTarget: String?
    public var updateState: String?
    public var statusText = ""
    public var linksError = ""
    public var preferenceRevision = 0
    public var adBlock: AdBlockSettingsModel?
    @ObservationIgnored private var shortcutsStorage: ShortcutsViewModel?
    public var shortcuts: ShortcutsViewModel {
        if let shortcutsStorage { return shortcutsStorage }
        let model = ShortcutsViewModel(root: self)
        shortcutsStorage = model
        return model
    }
    /// A navigation badge must not construct the Shortcuts model on first open.
    var shortcutsHaveConflicts: Bool { shortcutsStorage?.unexpected.isEmpty == false }
    var isRecordingShortcut: Bool { shortcutsStorage?.recordingCommandID != nil }
    func endShortcutCapture() {
        if shortcutsStorage?.recordingCommandID != nil { shortcutsStorage?.cancelRecording() }
        shortcutsStorage?.findByKeys = false
    }
    public func attach(adBlockStore: AdBlockStore, directoryForProfile: (@MainActor (Profile) -> URL)? = nil) {
        let directories = ProfileDirectories(root: root)
        adBlock = AdBlockSettingsModel(root: self, store: adBlockStore,
            directoryForProfile: directoryForProfile ?? { directories.adBlockDirectory(dataDirectoryName: $0.dataDirectoryName) })
    }
    public var showsPreviews = false
    public var showsImport = false { didSet {
        if showsImport && !oldValue { importWizard = ImportWizardViewModel(root: self, startsWithSource: true) }
    } }
    /// One wizard per presentation, shared by the visible sheet and App adapter.
    @ObservationIgnored public private(set) lazy var importWizard = ImportWizardViewModel(root: self)
    public var showsSearchEngines = false
    @ObservationIgnored public private(set) lazy var profiles = ProfilesViewModel(root: self)
    @ObservationIgnored public private(set) lazy var general = GeneralViewModel(root: self)
    @ObservationIgnored public private(set) lazy var advanced = AdvancedViewModel(root: self)
    @ObservationIgnored public private(set) lazy var appIcon = AppIconViewModel(root: self)
    public func bool(_ key: String) -> Bool { _ = preferenceRevision; return defaults.object(forKey: key) as? Bool ?? (SettingsDefaults.values[key] as? Bool ?? false) }
    public func string(_ key: String) -> String { _ = preferenceRevision; return defaults.string(forKey: key) ?? (SettingsDefaults.values[key] as? String ?? "") }
    public func set(_ value: Any, for key: String) { defaults.set(value, forKey: key); defaults.synchronize(); preferenceRevision &+= 1; if !searchQuery.isEmpty { updateSettingsSearch() } }

    public init(model: BrowserModel, actions: any SettingsActions, defaults: UserDefaults, root: URL, snapshot: SnapshotStore, focusedProfileID: ProfileID? = nil) {
        SettingsDefaults.register(in: defaults)
        self.model = model; self.actions = actions; self.defaults = defaults; self.root = root
        self.snapshot = snapshot
        let initialPane = PaneID(rawValue: defaults.string(forKey: "open.settings.lastPane") ?? "") ?? .general
        selectedPane = initialPane
        selectedSection = SettingsSection(rawValue: defaults.string(forKey: "open.settings.lastSection") ?? "") ?? .legacy(initialPane)
        selectedProfileID = focusedProfileID ?? model.windows.first.flatMap { model.space(id: $0.focusedSpaceID)?.profileID } ?? model.defaultProfile?.id ?? ProfileID()
        links = Self.makeLinks(model: model, actions: actions, defaults: defaults, snapshotProvider: nil)
        refreshLinks()
    }
    @ObservationIgnored private var keyBindingStamp = "unread"
    @ObservationIgnored private var cachedKeyBindings = KeyBindingStore.empty
    @ObservationIgnored public private(set) var keyBindingLoadCount = 0
    public var shortcutsStore: KeyBindingStore {
        let url=root.appendingPathComponent("State/keybindings.json")
        let attributes=try? FileManager.default.attributesOfItem(atPath:url.path)
        let stamp="\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? NSNumber ?? 0)|\(attributes?[.systemFileNumber] as? NSNumber ?? 0)"
        if stamp != keyBindingStamp {
            cachedKeyBindings=(try? KeyBindingStore.load(from:url)) ?? .empty
            keyBindingStamp=stamp; keyBindingLoadCount += 1
        }
        return cachedKeyBindings
    }
    public var routingSpaces: [RoutingSpaceSnapshot] { model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) } }
    @discardableResult public func commitLinks() -> Bool {
        let oldHotkey = bool("open.links.littleOpenHotkeyEnabled")
        set(links.externalLinksInLittleOpen, for: "open.links.externalInLittleOpen")
        set(links.littleOpenHotkeyEnabled, for: "open.links.littleOpenHotkeyEnabled")
        set(links.optionCommandClickLittleOpen, for: "open.links.optionCommandClickLittleOpen")
        if oldHotkey != links.littleOpenHotkeyEnabled { actions.keyBindingsDidChange(store: shortcutsStore) }
        if let profile = model.profile(id: selectedProfileID), profile.settings.littleOpenAutoArchiveAfter != links.littleOpenAutoArchiveAfter {
            var settings = profile.settings; settings.littleOpenAutoArchiveAfter = links.littleOpenAutoArchiveAfter
            model.updateProfileSettings(id: selectedProfileID, settings: settings); save()
        }
        guard !links.issues().contains(where: \.isError) else {
            linksError="Routes could not be saved. Check each pattern and choose an existing Space for every rule."
            return false
        }
        let oldRules=model.routingRules,oldDestination=model.defaultDestination
        let copy=links.currentRouting();model.routingRules=copy.rules;model.defaultDestination=copy.defaultDestination
        do {try snapshot.saveNow(model:model);linksError="";return true}
        catch {model.routingRules=oldRules;model.defaultDestination=oldDestination;linksError="Routes could not be saved. Try again when your data folder is available.";return false}
    }
    /// The sheet keeps its local draft open if another rule or the durable save fails.
    @discardableResult public func saveLinkRule(_ draft: RuleDraft) -> Bool {
        if let index=links.drafts.firstIndex(where:{$0.id == draft.id}) {links.drafts[index]=draft}
        else {links.drafts.append(draft)}
        return commitLinks()
    }
    public var linkTestSummary: String? {
        guard let decision=links.testDecision else {return nil}
        let target:String
        switch decision.resolved {
        case .littleOpen: target="Little Open"
        case .space(let id,_): target=model.space(id:id).map{model.displayTitle(for:$0)} ?? "the selected Space"
        case nil: return "This link cannot be opened. Use an http or https address."
        }
        if let rule=decision.traces.first(where:{$0.outcome == .matched})?.rule {
            let pattern:String,kind:String
            switch rule.match {case .hostContains(let value):pattern=value;kind="Host contains";case .hostEquals(let value):pattern=value;kind="Host equals";case .urlPrefix(let value):pattern=value;kind="URL starts with"}
            return "Opens in \(target) · matched “\(pattern)” (\(kind))"
        }
        return "Opens in \(target) · default destination"
    }
    public func refreshLinks(preserveDrafts: Bool = false) {
        let previous = links
        links = Self.makeLinks(model: model, actions: actions, defaults: defaults, snapshotProvider: routingSnapshotProvider)
        links.littleOpenHotkeyEnabled = bool("open.links.littleOpenHotkeyEnabled")
        links.optionCommandClickLittleOpen = bool("open.links.optionCommandClickLittleOpen")
        links.littleOpenAutoArchiveAfter = model.profile(id: selectedProfileID)?.settings.littleOpenAutoArchiveAfter ?? .sixHours
        if preserveDrafts {
            links.drafts = previous.drafts; links.defaultDestinationKind = previous.defaultDestinationKind; links.defaultSpaceID = previous.defaultSpaceID
            links.defaultProfileID = previous.defaultProfileID
            links.testURLString = previous.testURLString; links.testSourceBundleID = previous.testSourceBundleID; links.testMostRecentSpaceID = previous.testMostRecentSpaceID
            if previous.testDecision != nil { links.runTest() }
        }
    }
    private static func makeLinks(model: BrowserModel, actions: any SettingsActions, defaults: UserDefaults,
                                  snapshotProvider: (@MainActor () -> RoutingSnapshot)?) -> LinksSettingsModel {
        let snapshot = RoutingSnapshot(
            spaces: model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) },
            windows: [], rules: model.routingRules, defaultDestination: model.defaultDestination,
            externalLinksInLittleOpen: defaults.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true,
            profiles: model.profiles.map(\.id))
        return LinksSettingsModel(snapshot: snapshot,
            spaces: model.spaces.map { SpaceOption(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) },
            profiles: model.profiles.map { RoutingProfileOption(id: $0.id, name: $0.name) },
            isDefaultBrowser: actions.isDefaultBrowser(), defaults: defaults, snapshotProvider: snapshotProvider)
    }
    public func refreshExternalState() { general.refresh(); profiles.refresh(); adBlock?.refresh(); refreshLinks(preserveDrafts: true) }
    public func save() { snapshot.scheduleSave(model: model) }
    public func flush() throws { try snapshot.saveNow(model: model) }
}
