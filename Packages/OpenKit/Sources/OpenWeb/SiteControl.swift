import Foundation
import Security

public enum WebSiteSettingState: String, Sendable, Hashable, CaseIterable {
    case allow, block, ask, session
}

/// The registry's stable Chromium type name and its effective exception.
public struct WebSiteSetting: Sendable, Hashable {
    public let kind: String
    public let state: WebSiteSettingState
    public init(kind: String, state: WebSiteSettingState) { self.kind = kind; self.state = state }
}

public struct WebSiteDataKinds: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let cookies = Self(rawValue: 1)
    public static let cache = Self(rawValue: 2)
    public static let storage = Self(rawValue: 4)
}

public enum WebSecurityLevel: String, Sendable, Hashable {
    case secure, neutral, insecure, dangerous, mixedContent
}

public enum WebSiteControlError: Error { case unsupported }

extension WebContentChange {
    public static let security = Self(rawValue: 1 << 16)
}

extension WebProfile {
    public func changedSiteSettings(origin: URL) -> [WebSiteSetting] { [] }
    @discardableResult
    public func setSiteSetting(_ state: WebSiteSettingState, kind: String, origin: URL) -> Bool { false }
    public func clearSiteData(origin: URL, kinds: WebSiteDataKinds) async throws {
        throw WebSiteControlError.unsupported
    }
}

extension WebContent {
    public var securityLevel: WebSecurityLevel { .neutral }
    public var certificateChain: [SecCertificate] { [] }
}
