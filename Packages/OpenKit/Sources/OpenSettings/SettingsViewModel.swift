import Foundation
import Observation
import OpenModel
import OpenRouting
import OpenStore

@MainActor @Observable public final class SettingsViewModel {
    public var selectedPane: PaneID { didSet { defaults.set(selectedPane.rawValue, forKey: "open.settings.lastPane") } }
    public var selectedProfileID: ProfileID
    public let model: BrowserModel
    public let actions: any SettingsActions
    public let defaults: UserDefaults
    public let root: URL
    public let snapshot: SnapshotStore
    public var links: LinksSettingsModel
    public var statusText = ""
    public init(model: BrowserModel, actions: any SettingsActions, defaults: UserDefaults, root: URL, snapshot: SnapshotStore? = nil) {
        self.model = model; self.actions = actions; self.defaults = defaults; self.root = root
        self.snapshot = snapshot ?? SnapshotStore(root: root)
        selectedPane = PaneID(rawValue: defaults.string(forKey: "open.settings.lastPane") ?? "") ?? .general
        selectedProfileID = model.defaultProfile?.id ?? ProfileID()
        links = LinksSettingsModel(snapshot: RoutingSnapshot(spaces: model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: model.displayTitle(for: $0), profileID: $0.profileID) }, windows: model.windows.map { RoutingWindowSnapshot(id: $0.id, kind: $0.style == .littleOpen ? .littleOpen : .standard, focusedSpaceID: $0.focusedSpaceID) }, rules: model.routingRules, defaultDestination: model.defaultDestination, externalLinksInLittleOpen: defaults.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true), spaces: model.spaces.map { SpaceOption(id: $0.id, title: model.displayTitle(for: $0)) }, isDefaultBrowser: actions.isDefaultBrowser())
    }
    public func save() { snapshot.scheduleSave(model: model) }
    public func flush() throws { try snapshot.saveNow(model: model) }
}
