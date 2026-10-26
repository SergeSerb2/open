import AppKit
import OpenStore

/// Favicons for rows and the input. Lookups must be synchronous: a row draws what is
/// cached now and redraws when `loaded` fires for its page.
@MainActor
public protocol CommandBarFaviconSource: AnyObject {
    /// The cached icon for `pageURL`, or nil. On a miss the source may start a load and
    /// call `loaded(pageURL)` once it has the image.
    func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage?
}

/// `CommandBarFaviconSource` over `OpenStore.FaviconStore` (an actor). Decoded images are
/// kept per origin in a small main-actor cache, so a keystroke never waits for SQLite.
@MainActor
public final class FaviconStoreSource: CommandBarFaviconSource {
    private let store: FaviconStore
    private var images: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var loading: [String: UUID] = [:]
    private var waiters: [String: [(URL, @MainActor (URL) -> Void)]] = [:]
    private var order: [String] = []
    public var capacity = 512 { didSet { trim() } }

    public init(store: FaviconStore) { self.store = store }

    public func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage? {
        let key = Self.key(pageURL)
        if let image = images[key] { return image }
        guard !misses.contains(key) else { return nil }
        waiters[key, default: []].append((pageURL, loaded))
        guard loading[key] == nil else { return nil }
        let token = UUID()
        loading[key] = token
        let store = store
        Task { @MainActor [weak self] in
            let icon = await store.icon(for: pageURL)
            guard let self, self.loading[key] == token else { return }
            self.loading[key] = nil
            guard let data = icon?.png64 ?? icon?.png32, let image = NSImage(data: data) else {
                self.waiters[key] = nil
                if self.images[key] == nil, !self.misses.contains(key) { self.order.append(key) }
                self.misses.insert(key)
                self.trim()
                return
            }
            self.insert(image, for: key)
        }
        return nil
    }

    /// Adds an icon the engine just delivered (for example a page that finished loading).
    public func insert(_ image: NSImage, for pageURL: URL) { insert(image, for: Self.key(pageURL)) }

    private func insert(_ image: NSImage, for key: String) {
        if images[key] == nil, !misses.contains(key) { order.append(key) }
        images[key] = image
        misses.remove(key)
        loading[key] = nil
        let callbacks = waiters.removeValue(forKey: key) ?? []
        trim()
        for (url, loaded) in callbacks { loaded(url) }
    }

    private func trim() {
        // Successful images and misses share one bounded FIFO of origins.
        while order.count > max(0, capacity) {
            let key = order.removeFirst()
            images[key] = nil
            misses.remove(key)
        }
    }

    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.user = nil; parts.password = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
}

/// A fixed set of icons, keyed by host. Used by renders and checks.
@MainActor
public final class StaticFaviconSource: CommandBarFaviconSource {
    private var images: [String: NSImage]
    /// Returned for hosts without an icon (renders that mask favicons).
    public var placeholder: NSImage?
    public init(_ images: [String: NSImage] = [:]) { self.images = images }
    public func set(_ image: NSImage, host: String) { images[host] = image }
    public func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage? {
        var host = pageURL.host() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return images[host] ?? placeholder
    }
}
