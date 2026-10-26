import Foundation

public enum PeekPolicy {
    public struct Click: Sendable {
        public var sourceIsPinnedOrFavorite: Bool
        /// Registrable domains from the AppKit adapter's OpenSuggest PSL lookup.
        public var sourceHost: String?
        public var targetHost: String?
        public var shiftHeld: Bool
        public var peekOtherSitesEnabled: Bool
        public var peekShiftEnabled: Bool
        public init(sourceIsPinnedOrFavorite: Bool, sourceHost: String?, targetHost: String?, shiftHeld: Bool,
                    peekOtherSitesEnabled: Bool, peekShiftEnabled: Bool) {
            self.sourceIsPinnedOrFavorite = sourceIsPinnedOrFavorite; self.sourceHost = sourceHost
            self.targetHost = targetHost; self.shiftHeld = shiftHeld
            self.peekOtherSitesEnabled = peekOtherSitesEnabled; self.peekShiftEnabled = peekShiftEnabled
        }
    }
    public enum Decision: Sendable { case navigate, peek }
    public static func decision(for click: Click) -> Decision {
        if click.shiftHeld && click.peekShiftEnabled { return .peek }
        if click.sourceIsPinnedOrFavorite && click.peekOtherSitesEnabled,
           let source = click.sourceHost, let target = click.targetHost, source != target { return .peek }
        return .navigate
    }
}
