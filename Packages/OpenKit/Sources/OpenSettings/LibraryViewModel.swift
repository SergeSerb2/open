import Foundation
import Observation

@MainActor @Observable public final class LibraryViewModel {
    public var section: LibrarySection { didSet { defaults.set(section.rawValue, forKey: "open.library.lastSection") } }
    public var query = ""
    public var selectedIDs: Set<String> = []
    public var statusText = ""
    public let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults; section = LibrarySection(rawValue: defaults.string(forKey: "open.library.lastSection") ?? "") ?? .archive }
}
