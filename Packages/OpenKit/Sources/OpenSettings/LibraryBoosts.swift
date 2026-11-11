import AppKit
import OpenDesign
import OpenModel

public enum BoostsPresentation: String, Sendable { case list, gallery }

public struct BoostItemSnapshot: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let domain: String
    public let pathPrefix: String?
    public let isEnabled: Bool
    public init(id: String, name: String, domain: String, pathPrefix: String? = nil, isEnabled: Bool) {
        self.id = id; self.name = name; self.domain = domain; self.pathPrefix = pathPrefix; self.isEnabled = isEnabled
    }
}
@MainActor public protocol BoostsProvider: AnyObject {
    func boosts(profileID: ProfileID) -> [BoostItemSnapshot]
}


public extension LibraryViewModel {
    var boostItems: [BoostItemSnapshot] {
        (boostsProvider?.boosts(profileID: historyProfileID) ?? []).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.domain.localizedCaseInsensitiveContains(query)
        }
    }
}
