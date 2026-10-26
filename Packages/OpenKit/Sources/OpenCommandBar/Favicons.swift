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
    private var loading: Set<String> = []
    private var order: [String] = []
    public var capacity = 512

    public init(store: FaviconStore) { self.store = store }

    public func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage? {
        let key = Self.key(pageURL)
        if let image = images[key] { return image }
        guard !misses.contains(key), !loading.contains(key) else { return nil }
        loading.insert(key)
        let store = store
        Task { @MainActor [weak self] in
            let icon = await store.icon(for: pageURL)
            guard let self else { return }
            self.loading.remove(key)
            guard let data = icon?.png64 ?? icon?.png32, let image = NSImage(data: data) else {
                self.misses.insert(key)
                return
            }
            self.insert(image, for: key)
            loaded(pageURL)
        }
        return nil
    }

    /// Adds an icon the engine just delivered (for example a page that finished loading).
    public func insert(_ image: NSImage, for pageURL: URL) { insert(image, for: Self.key(pageURL)) }

    private func insert(_ image: NSImage, for key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        misses.remove(key)
        while order.count > capacity { images[order.removeFirst()] = nil }
    }

    static func key(_ url: URL) -> String { "\(url.scheme ?? "https")://\(url.host() ?? url.absoluteString)" }
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
