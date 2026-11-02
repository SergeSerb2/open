import Foundation

/// Copy URL without trackers for every Copy URL path (page-platform D-5, §4.2.1): `copy-url`,
/// `copy-url-markdown`, `copy-url-quote`, the pane bar and toolbar Copy buttons, and the Site Control
/// Copy URL button. A thin API over `TrackerStripping`, the rule decoded from Arc (RE CC-31a,
/// Section 2 item 12): there is one tracker table. Navigation never changes; only the copy is clean.
public enum URLCleaner {
    /// Arc's toast titles after Copy URL (PG-1.10, main binary strings): something removed, or the
    /// URL as it was.
    public static let cleanedTitle = "Copied a clean link without trackers"
    public static let plainTitle = "Copied Current URL"

    /// The URL without tracking query items, and the removed names. Keeps item order and the
    /// fragment; returns the input unchanged for anything but http(s).
    public static func clean(_ url: URL) -> (url: URL, removed: [String]) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return (url, []) }
        return TrackerStripping.strip(url)
    }

    /// The toast title for a copy that removed `removed`.
    public static func toastTitle(removed: [String]) -> String { removed.isEmpty ? plainTitle : cleanedTitle }
}
