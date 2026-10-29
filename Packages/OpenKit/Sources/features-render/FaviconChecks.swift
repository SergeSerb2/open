import AppKit
import ImageIO
import OpenModel
import OpenFeatures
import OpenSidebar
import OpenStore

/// Full store -> decoded cache -> real sidebar row/tile draws, with disposable data.
@MainActor
enum FaviconChecks {
    static func png(size: Int = 64, blue: Bool = false, noise: Bool = false) -> Data {
        var pixels = Data(count: size * size * 4)
        pixels.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            var state: UInt32 = 0x12345678
            for i in stride(from: 0, to: p.count, by: 4) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                p[i] = noise ? UInt8(truncatingIfNeeded: state) : (blue ? 20 : 220)
                p[i+1] = noise ? UInt8(truncatingIfNeeded: state >> 8) : 80
                p[i+2] = noise ? UInt8(truncatingIfNeeded: state >> 16) : (blue ? 220 : 20)
                p[i+3] = 255
            }
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    static func pixels(_ image: NSImage?) -> Data? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var data = Data(count: 64 * 64 * 4)
        data.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return data
    }

    static func idle(_ cache: StoredFaviconCache) async throws {
        for _ in 0..<3000 {
            if cache.isIdle { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CLIError(description: "favicon worker deadline")
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stored-favicons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FaviconStore(databaseURL: root.appendingPathComponent("icons.sqlite3"))
        let cache = StoredFaviconCache(store: store)
        let url = URL(string: "https://stored.example.invalid/pinned")!
        let red = png(), blue = png(blue: true)
        check(cache.report(red, for: url), "FV1 accept engine report through App cache")
        try await idle(cache)
        let stored = await store.icon(for: url)
        check(stored != nil && cache.completedReports == 1, "FV1 report persists in FaviconStore")

        let profile = Profile()
        let pin = Tab(url: url, title: "Imported pin", pinnedURL: url)
        let favorite = Tab(url: url, title: "Imported favorite", pinnedURL: url)
        profile.favorites = [favorite]
        let slept = Tab(url: url, title: "Slept tab"); slept.live.sleepPhase = .sleeping
        let space = Space(title: "Stored icons", profileID: profile.id, pinned: [.tab(pin)], today: [.tab(slept)])
        let window = BrowserWindowState(focusedSpaceID: space.id)
        let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        let defaultsName = "Open.Favicons.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let c = BrowserWindowController(model: model, windowID: window.id, factory: FakeWebContentHostFactory(),
                                        size: CGSize(width: 1280, height: 900), defaults: defaults)
        defer { c.container.closeAll(); c.window?.close() }
        let cold = StoredFaviconCache(store: store)
        c.context.storedFavicons = cold
        let host = OffscreenRenderer.host(c.contentView, scale: 2)
        defer { host.contentView = nil; host.close() }
        func display() { OffscreenRenderer.settle(c.contentView) }
        display(); try await idle(cold); try await Task.sleep(for: .milliseconds(10)); display()
        let expected = pixels(cache.image(for: url))
        check([pin, slept, favorite].allSatisfy { !$0.live.hasWebContent && $0.live.faviconPNG == nil && pixels(c.sidebar.drawnFavicon(tabID: $0.id)) == expected } && expected != nil,
              "FV2 cold store draws unloaded imported pin, slept row and Favorite pixels")
        let missing = Tab(url: URL(string: "https://missing.example.invalid/")!, title: "No icon")
        _ = model.newTab(in: space.id, url: missing.url, title: missing.title)
        display(); try await idle(cold); display()
        check(cold.image(for: missing.url) == nil, "FV3 missing icon keeps existing placeholder")
        check(cold.report(blue, for: url), "FV4 accept replacement report")
        try await idle(cold); try await Task.sleep(for: .milliseconds(10)); display()
        let replacement = pixels(cold.image(for: url))
        check(replacement != nil && replacement != expected && pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == replacement,
              "FV4 replacement redraws existing unloaded row without reload")
        let reopened = try FaviconStore(databaseURL: root.appendingPathComponent("icons.sqlite3"))
        let persisted = await reopened.decodedIcon(for: url)
        check(pixels(persisted.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) }) == replacement,
              "FV4 replacement survives new store connection")

        pin.live.faviconPNG = red
        try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == replacement && c.sidebar.drawnFaviconSource(tabID: pin.id) == "stored",
              "FV4 unloaded row ignores retained stale live PNG")
        pin.live.hasWebContent = true
        try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == expected, "FV4 live page image wins over stored replacement")
        pin.live.hasWebContent = false; pin.live.faviconPNG = nil
        try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == replacement, "FV4 clearing live image restores stored replacement")

        // FV15 exercises the actual row's Observation subscription across FIFO eviction.
        let evicted = StoredFaviconCache(store: store)
        c.context.storedFavicons = evicted
        display(); try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        for i in 0..<StoredFaviconCache.capacity {
            _ = evicted.image(for: URL(string: "https://evict.example.invalid/\(i)")!)
        }
        try await idle(evicted)
        _ = evicted.report(red, for: url)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == expected && evicted.cachedCount <= StoredFaviconCache.capacity,
              "FV15 visible row redraws after its entry is evicted by 1025 keys and reported again")
        _ = evicted.report(blue, for: url); try await idle(evicted)

        // Exercise copy provenance through the same async worker and drawn row.
        let copyToken = UUID(), iconURL = URL(string: "https://stored.example.invalid/icon.png")!
        _ = evicted.report(red, for: url, iconURL: iconURL, copyToken: copyToken)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: pin.id)) == replacement,
              "FV16 confirmed copy preserves existing destination pixels")
        let copiedURL = URL(string: "https://copied.example.invalid/page")!
        let copiedTab = model.newTab(in: space.id, url: copiedURL, title: "Confirmed copy")
        _ = evicted.report(red, for: copiedURL, iconURL: iconURL, copyToken: copyToken)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: copiedTab.id)) == expected,
              "FV16 confirmed copy draws stored pixels")
        _ = evicted.removeCopy(for: copiedURL, token: UUID())
        try await idle(evicted)
        check(await store.icon(for: copiedURL) != nil, "FV16 unrelated provenance cannot remove destination record")
        _ = evicted.removeCopy(for: copiedURL, token: copyToken)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(await store.icon(for: copiedURL) == nil && c.sidebar.drawnFaviconSource(tabID: copiedTab.id) == "placeholder",
              "FV16 empty report revokes only its copied record and redraws placeholder")
        _ = evicted.report(red, for: copiedURL, iconURL: iconURL, copyToken: copyToken)
        try await idle(evicted)
        _ = evicted.report(blue, for: copiedURL, iconURL: iconURL)
        try await idle(evicted)
        _ = evicted.removeCopy(for: copiedURL, token: copyToken)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(pixels(c.sidebar.drawnFavicon(tabID: copiedTab.id)) == replacement,
              "FV16 late empty report preserves newer engine pixels")
        // FV17: a stale revocation queued behind a pending ordinary report (same
        // main-actor turn, so the worker has not run) must not discard that write.
        let queuedURL = URL(string: "https://queued.example.invalid/page")!, queuedToken = UUID()
        let queuedTab = model.newTab(in: space.id, url: queuedURL, title: "Queued revocation")
        _ = evicted.report(red, for: queuedURL, iconURL: iconURL, copyToken: queuedToken)
        try await idle(evicted)
        _ = evicted.report(blue, for: queuedURL, iconURL: iconURL)
        _ = evicted.removeCopy(for: queuedURL, token: queuedToken)
        try await idle(evicted); try await Task.sleep(for: .milliseconds(10)); display()
        check(await store.icon(for: queuedURL) != nil && pixels(c.sidebar.drawnFavicon(tabID: queuedTab.id)) == replacement,
              "FV17 queued revocation keeps the pending ordinary report")

        let prefix = "https://key.example.invalid/"
        let boundaryURL = URL(string: prefix + String(repeating: "x", count: 8192 - prefix.utf8.count))!
        try await store.ingest(imageData: red, iconURL: nil, for: boundaryURL, pageSpecific: true)
        var refusedURL = false
        do { try await store.ingest(imageData: red, iconURL: nil, for: URL(string: boundaryURL.absoluteString + "x")!, pageSpecific: true) }
        catch { refusedURL = true }
        check(await store.icon(for: boundaryURL) != nil && refusedURL, "FV5 accept URL at 8192 bytes; refuse 8193 bytes")
        func frames(_ count: Int) -> Data {
            let source = CGImageSourceCreateWithData(png(size: 16) as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, count, nil)!
            for _ in 0..<count { CGImageDestinationAddImage(destination, image, nil) }
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
        try await store.ingest(imageData: frames(32), iconURL: nil, for: boundaryURL, pageSpecific: true)
        var refusedFrames = false
        do { try await store.ingest(imageData: frames(33), iconURL: nil, for: boundaryURL, pageSpecific: true) }
        catch { refusedFrames = true }
        check(refusedFrames, "FV5 accept 32 frames; refuse 33 before decoding")

        let prior = await store.icon(for: url)?.png64
        for (name, data) in [("encoded bytes", Data(count: FaviconStore.maximumInputBytes + 1)),
                             ("decoded edge", png(size: FaviconStore.maximumDimension + 1)), ("invalid image", Data("bad".utf8))] {
            var refused = false
            do { try await store.ingest(imageData: data, iconURL: nil, for: url, pageSpecific: true) }
            catch { refused = true }
            let after = await store.icon(for: url)?.png64
            check(refused && after == prior, "FV5 refuse \(name) and preserve stored icon")
        }
        try await store.ingest(imageData: png(size: FaviconStore.maximumDimension), iconURL: nil, for: url, pageSpecific: true)
        check(await store.icon(for: url) != nil, "FV5 accept decoded edge at 1024 px")
        let other = URL(string: "https://stored.example.invalid/other")!
        try await store.ingest(imageData: red, iconURL: nil, for: other, pageSpecific: true)
        check(await store.icon(for: other)?.png64 != prior, "FV6 page keys keep different paths distinct")
        let canonical = await store.icon(for: URL(string: "https://stored.example.invalid:443/other?q=1#x")!)?.png64
        let otherData = await store.icon(for: other)?.png64
        check(canonical == otherData,
              "FV6 canonical origin/path ignores query, fragment and default port")

        // Entry and pending work limits include misses. No callback arrays grow on draws.
        let bounded = StoredFaviconCache(store: store)
        for i in 0...StoredFaviconCache.capacity { _ = bounded.image(for: URL(string: "https://cache.example.invalid/\(i)")!) }
        check(bounded.cachedCount == StoredFaviconCache.capacity, "FV7 decoded cache refuses growth past 1024 entries")
        try await idle(bounded)
        var accepted = 0
        for i in 0...StoredFaviconCache.maximumPendingReports {
            if bounded.report(red, for: URL(string: "https://queue.example.invalid/\(i)")!) { accepted += 1 }
        }
        check(accepted == 32 && bounded.rejectedReports == 1, "FV7 pending reports bounded at 32; excess refused")
        check(!bounded.report(Data(count: FaviconStore.maximumInputBytes + 1), for: url), "FV7 raw limit refused before queue retention")
        try await idle(bounded)

        let limits = try FaviconStore(databaseURL: root.appendingPathComponent("limits.sqlite3"))
        for i in 0...FaviconStore.maximumEntries {
            try await limits.ingest(imageData: red, iconURL: nil, for: URL(string: "https://limit.example.invalid/\(i)")!, pageSpecific: true)
        }
        let count = await limits.count()
        let oldest = await limits.icon(for: URL(string: "https://limit.example.invalid/0")!)
        check(count == FaviconStore.maximumEntries && oldest == nil,
              "FV8 disk count stays at 4096 and evicts oldest")
        let noisy = png(noise: true)
        for i in 0..<500 {
            try await limits.ingest(imageData: noisy, iconURL: nil, for: URL(string: "https://payload.example.invalid/\(i)")!, pageSpecific: true)
        }
        let stats = await limits.statistics()
        let bytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("limits.sqlite3") }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        check(stats.totalBytes <= FaviconStore.maximumStoredBytes && stats.count < count && bytes <= 34 * 1024 * 1024,
              "FV9 PNG payload <= 8 MiB; SQLite + rollback journal <= 34 MiB (\(bytes) bytes)")

        // FV13 goes through the real persistent ingest path, beyond the old physical cap.
        let wideFile = root.appendingPathComponent("wide.sqlite3")
        let wide = try FaviconStore(databaseURL: wideFile)
        func wideURL(_ i: Int) -> URL {
            let prefix = "https://wide.example.invalid/\(i)-"
            return URL(string: prefix + String(repeating: "x", count: 8192 - prefix.utf8.count))!
        }
        var written = 0, refused = 0, firstFailure = -1
        for i in 0..<1200 {
            do { try await wide.ingest(imageData: red, iconURL: nil, for: wideURL(i), pageSpecific: true); written += 1 }
            catch { refused += 1; if firstFailure == -1 { firstFailure = i } }
        }
        let wideBytes = (try FileManager.default.attributesOfItem(atPath: wideFile.path)[.size] as! NSNumber).intValue
        let wideOldest = await wide.icon(for: wideURL(0)), wideNewest = await wide.icon(for: wideURL(1199))
        check(written == 1200 && refused == 0 && wideOldest == nil && wideNewest != nil && wideBytes <= FaviconStore.maximumDatabaseBytes,
              "FV13 8 KiB URL writes keep succeeding via oldest eviction: written=\(written) refused=\(refused) firstFailure=\(firstFailure) databaseBytes=\(wideBytes)")

        try await scroll(root: root, defaults: defaults, check: check)
    }

    static func scroll(root: URL, defaults: UserDefaults, check: (Bool, String) -> Void) async throws {
        let store = try FaviconStore(databaseURL: root.appendingPathComponent("scroll.sqlite3"))
        let profile = Profile()
        let tabs = (0..<1000).map { Tab(url: URL(string: "https://scroll.example.invalid/\($0)")!, title: "Stored \($0)") }
        let data = png()
        for tab in tabs { try await store.ingest(imageData: data, iconURL: nil, for: tab.url, pageSpecific: true) }
        let cache = StoredFaviconCache(store: store)
        for tab in tabs { _ = cache.image(for: tab.url) }
        try await idle(cache)
        check(tabs.allSatisfy { cache.image(for: $0.url) != nil } && cache.cachedCount == 1000, "FV10 1000 distinct stored icons decoded before scroll")
        let space = Space(title: "1000 icons", profileID: profile.id, pinned: tabs.map { .tab($0) })
        let window = BrowserWindowState(focusedSpaceID: space.id)
        let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        let c = BrowserWindowController(model: model, windowID: window.id, factory: FakeWebContentHostFactory(),
                                        size: CGSize(width: 1280, height: 900), defaults: defaults)
        c.context.storedFavicons = cache
        let host = OffscreenRenderer.host(c.contentView, scale: 2)
        defer { c.container.closeAll(); host.contentView = nil; host.close(); c.window?.close() }
        guard let outline = c.sidebar.focusedOutline, let clip = outline.enclosingScrollView?.contentView else { throw CLIError(description: "FV10 missing outline") }
        let maxY = outline.frame.height - clip.bounds.height
        var y: CGFloat = 0, samples: [Double] = []
        while y < maxY {
            y = min(maxY, y + 120)
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y)); outline.enclosingScrollView?.reflectScrolledClipView(clip)
            c.contentView.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        let p95 = samples.sorted()[Int(Double(samples.count) * 0.95)]
        check(p95 <= 8.33, String(format: "FV10 1000 stored-icon rows scroll p95 %.3f ms <= 8.33 ms (%d steps)", p95, samples.count))
    }
}
