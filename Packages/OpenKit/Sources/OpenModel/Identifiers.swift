import Foundation

/// Generic UUID-backed typed identifier.
public struct Identifier<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(uuidString: String) { self.rawValue = UUID(uuidString: uuidString) ?? UUID() }
    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        rawValue = UUID(uuidString: s) ?? UUID()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue.uuidString)
    }
}

public enum ItemTag: Sendable {}
public enum SpaceTag: Sendable {}
public enum ProfileTag: Sendable {}
public enum WindowTag: Sendable {}
public enum RuleTag: Sendable {}

public typealias ItemID = Identifier<ItemTag>
public typealias SpaceID = Identifier<SpaceTag>
public typealias ProfileID = Identifier<ProfileTag>
public typealias WindowID = Identifier<WindowTag>
public typealias RuleID = Identifier<RuleTag>

/// Where a sidebar node lives. Used for tree-change events and parent lookup.
public enum NodeParent: Hashable, Sendable {
    case spacePinned(SpaceID)
    case spaceToday(SpaceID)
    case folder(ItemID)
    case favorites(ProfileID)
    case splitPane(ItemID) // parent split id
}
