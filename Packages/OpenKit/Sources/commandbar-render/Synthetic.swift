import AppKit
import OpenDesign
import OpenModel
import OpenStore
import OpenCommandBar

/// Synthetic browser state for renders, flows, and the bench. Neutral titles, public
/// site names, our own theme colors and icons. No user data.
@MainActor
enum Synthetic {
    struct World {
        let model: BrowserModel
        let profile: Profile
        let studio: Space, reading: Space, plain: Space
        let current: Tab
        let other: Tab
    }

    static func tab(_ url: String, _ title: String, pinned: Bool = false, ago: TimeInterval) -> Tab {
        let u = URL(string: url)!
        return Tab(url: u, title: title, pinnedURL: pinned ? u : nil, lastActiveAt: Date().addingTimeInterval(-ago))
    }

    static func world() -> World {
        let profile = Profile(name: "Default")
        profile.favorites = [
            tab("https://mail.example.com/inbox", "Mail", pinned: true, ago: 4_000),
            tab("https://calendar.example.com/week", "Calendar", pinned: true, ago: 9_000),
        ]
        let studio = Space(title: "Studio", icon: .emoji("🌿"), theme: SpaceTheme(importedArcThemeJSON: themeJSON(base: 0xE2783F)), profileID: profile.id)
        let reading = Space(title: "Reading", icon: .emoji("📘"), theme: SpaceTheme(importedArcThemeJSON: themeJSON(base: 0x4F7BE8)), profileID: profile.id)
        let plain = Space(title: "", icon: .emoji("🪐"), profileID: profile.id)
        let current = tab("https://github.com/open-browser/open/pulls", "Pull requests · open-browser/open", pinned: true, ago: 20)
        studio.pinned = [
            .tab(current),
            .tab(tab("https://github.com/open-browser/open/issues", "Issues · open-browser/open", pinned: true, ago: 300)),
            .tab(tab("https://board.example.com/sprint", "Sprint board", pinned: true, ago: 900)),
            .tab(tab("https://notes.example.com/design", "Design notes", pinned: true, ago: 1_800)),
        ]
        studio.today = [
            .tab(tab("https://docs.example.com/guide", "Getting started guide", ago: 120)),
            .split(Split(panes: [tab("https://left.example.com/", "Spec draft", ago: 600), tab("https://right.example.com/", "Review notes", ago: 700)])),
        ]
        let other = tab("https://git-scm.com/book/en/v2", "Git - Book", ago: 3_000)
        reading.pinned = [.tab(other), .tab(tab("https://papers.example.com/list", "Paper queue", pinned: true, ago: 5_000))]
        plain.today = [.tab(tab("https://www.youtube.com/watch?v=synthetic", "Synthetic video", ago: 8_000))]
        let window = BrowserWindowState(focusedSpaceID: studio.id, selectedNodeBySpace: [studio.id: current.id],
                                        sidebarWidth: 228, frameWidth: 1440, frameHeight: 900)
        let model = BrowserModel(profiles: [profile], spaces: [studio, reading, plain], windows: [window])
        return World(model: model, profile: profile, studio: studio, reading: reading, plain: plain, current: current, other: other)
    }

    /// A small history database: a few pages the scripted states need plus `bulk` generic pages.
    static func history(at root: URL, bulk: Int = 0) async -> HistoryStore {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HistoryStore(fileURL: root.appendingPathComponent("history.sqlite3"))
        let now = Date()
        func visit(_ url: String, _ title: String, times: Int, typed: Bool = false, ago: TimeInterval) async {
            for _ in 0..<times { await store.recordVisit(url: URL(string: url)!, title: title, time: now.addingTimeInterval(-ago), typed: typed) }
        }
        await visit("https://github.com/", "GitHub", times: 6, typed: true, ago: 3_600)
        await visit("https://github.com/open-browser/open", "open-browser/open", times: 4, ago: 7_200)
        await visit("https://git-scm.com/docs", "Git - Reference", times: 3, ago: 86_400)
        await visit("https://gitlab.example.org/explore", "Explore projects", times: 1, ago: 172_800)
        await visit("https://www.youtube.com/", "YouTube", times: 5, typed: true, ago: 4_000)
        await visit("https://news.example.org/today", "Morning news", times: 3, ago: 50_000)
        if bulk > 0 {
            var items: [(url: URL, title: String, time: Date)] = []
            items.reserveCapacity(bulk)
            for n in 0..<bulk {
                items.append((URL(string: "https://site-\(n % 5000).example.org/article/\(n)")!, "Article number \(n) about topic \(n % 200)", now.addingTimeInterval(-Double(n * 30))))
            }
            var offset = 0
            while offset < items.count {
                await store.recordVisitsBulk(Array(items[offset..<min(offset + 10_000, items.count)]))
                offset += 10_000
            }
        }
        return store
    }

    /// `count` tabs over 10 Spaces, for the bench (same shape as OpenSuggest's suggest-check model).
    static func benchModel(tabs count: Int) -> (BrowserModel, Profile, [Space]) {
        let profile = Profile(name: "Bench")
        let words = ["alpha", "budget", "canvas", "delta", "editor", "figma", "garden", "harbor", "index", "journal",
                     "kernel", "ledger", "matrix", "notion", "orbit", "planner", "quartz", "review", "signal", "tracker"]
        let spaces = (0..<10).map { Space(title: "Space \($0 + 1)", profileID: profile.id) }
        for i in 0..<count {
            let w1 = words[i % words.count], w2 = words[(i / 7) % words.count]
            let t = tab("https://\(w1)-\(i % 800).example.net/\(w2)/\(i)", "\(w1.capitalized) \(w2) \(i)", pinned: i % 3 == 0, ago: Double(i * 13))
            let s = spaces[i % 10]
            if i % 3 == 0 { s.pinned.append(.tab(t)) } else { s.today.append(.tab(t)) }
        }
        let window = BrowserWindowState(focusedSpaceID: spaces[0].id)
        return (BrowserModel(profiles: [profile], spaces: spaces, windows: [window]), profile, spaces)
    }

    // MARK: Icons (ours)

    /// Simple favicons drawn in code: a rounded square in a site color with a white letter.
    static func favicons() -> StaticFaviconSource {
        let source = StaticFaviconSource()
        let sites: [(String, String, UInt32)] = [
            ("github.com", "G", 0x24292F), ("git-scm.com", "g", 0xE0533A), ("youtube.com", "▶", 0xE5322D),
            ("mail.example.com", "M", 0x3B82F6), ("calendar.example.com", "C", 0x10B981), ("board.example.com", "B", 0x6366F1),
            ("notes.example.com", "N", 0xF59E0B), ("docs.example.com", "D", 0x0EA5E9), ("left.example.com", "S", 0x8B5CF6),
            ("right.example.com", "R", 0xEC4899), ("papers.example.com", "P", 0x14B8A6), ("news.example.org", "N", 0x64748B),
        ]
        for (host, letter, color) in sites { source.set(icon(letter, color: color), host: host) }
        return source
    }

    /// A 32 px bitmap, like the PNGs `FaviconStore` returns.
    static func icon(_ letter: String, color: UInt32) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: 32, height: 32)
        RGBA(hex: color).nsColor.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        let s = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 19, weight: .bold), .foregroundColor: NSColor.white])
        let b = s.size()
        s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Theme

    /// An Arc-shaped theme JSON with our own colors: only the palette roles the bar reads.
    static func themeJSON(base: UInt32) -> Data {
        func rgb(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        func color(_ c: (Double, Double, Double), _ a: Double = 1) -> [String: Any] {
            ["red": c.0, "green": c.1, "blue": c.2, "alpha": a, "colorSpace": "extendedSRGB"]
        }
        func shade(L: Double, chroma: Double) -> (Double, Double, Double) {
            let (r, g, b) = rgb(base)
            let lab = OKLab.fromSRGB(r, g, b)
            let k = lab.chroma > 0 ? chroma / lab.chroma : 0
            let (lr, lg, lb) = OKLab.toLinear(OKLab.Lab(L, lab.a * k, lab.b * k))
            return (OKLab.encode(lr), OKLab.encode(lg), OKLab.encode(lb))
        }
        let light: [String: Any] = ["background": color(shade(L: 0.95, chroma: 0.02)), "title": color(shade(L: 0.22, chroma: 0.06))]
        let dark: [String: Any] = [
            "background": color(shade(L: 0.22, chroma: 0.06)), "backgroundExtra": color(shade(L: 0.16, chroma: 0.04)),
            "title": color(shade(L: 0.92, chroma: 0.02)), "subtitle": color(shade(L: 0.6, chroma: 0.02)),
            "focus": color(shade(L: 0.55, chroma: 0.13), 0.8075),
        ]
        let theme: [String: Any] = [
            "primaryColorPalette": ["shaded": color(rgb(base))],
            "semanticColorPalette": ["appearanceBased": ["light": light, "dark": dark]],
            "background": ["single": ["_0": [
                "style": ["color": ["_0": ["blendedSingleColor": ["_0": ["color": color(rgb(base)), "modifiers": ["noiseFactor": 0, "intensityFactor": 0.8]]]]]],
                "contentOverBackgroundAppearance": "light", "isVibrant": true,
            ]]],
        ]
        return try! JSONSerialization.data(withJSONObject: theme, options: [.sortedKeys])
    }
}
