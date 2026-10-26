import Foundation
import OpenDesign
import OpenModel
import OpenStore

/// A synthetic browser state with neutral titles and our own theme colors.
/// Used for the crops in docs/design.md and for the 1,000-row bench. Contains
/// no user data.
@MainActor
enum Synthetic {
    static func url(_ host: String, _ path: String = "") -> URL { URL(string: "https://\(host).example.com/\(path)")! }

    static func model(bulkRows: Int? = nil) -> BrowserModel {
        let profile = Profile(name: "Default")
        profile.favorites = ["mail", "calendar", "docs", "music", "notes", "maps"].map {
            let u = url($0)
            return Tab(url: u, title: $0.capitalized, pinnedURL: u)
        }
        let warm = Space(title: "Studio", icon: .emoji("🌿"), theme: SpaceTheme(importedArcThemeJSON: themeJSON(
            base: [0xFF8F5A, 0xF2D35B], overlay: 0xFF6A9A, noise: 0, intensity: 0.8, appearance: "light")), profileID: profile.id)
        let pinnedTitles = ["Project board", "Design notes", "Team chat", "Release checklist", "Analytics",
                            "Docs home", "Roadmap", "Inbox zero", "Style guide", "Status page"]
        warm.pinned = pinnedTitles.enumerated().map { i, t in
            let u = url("site\(i)")
            return .tab(Tab(url: u, title: t, pinnedURL: u))
        }
        warm.today = ["Search results", "Long article about gardens", "Recipe: lemon tart"].enumerated().map { i, t in
            .tab(Tab(url: url("page\(i)"), title: t))
        }
        let cool = Space(title: "Reading", icon: .emoji("📘"), theme: SpaceTheme(importedArcThemeJSON: themeJSON(
            base: [0x5B8DEF, 0x8FD3F4], overlay: 0x7B6CF6, noise: 0.35, intensity: 1, appearance: "light")), profileID: profile.id)
        cool.pinned = ["Reading list", "Papers", "Notebook"].enumerated().map { i, t in .tab(Tab(url: url("read\(i)"), title: t, pinnedURL: url("read\(i)"))) }
        let night = Space(title: "", icon: .emoji("🪐"), profileID: profile.id)
        let folder = Folder(title: "Getting started", isExpanded: true, children: [
            .tab(Tab(url: url("welcome"), title: "Welcome", pinnedURL: url("welcome"))),
            .tab(Tab(url: url("tips"), title: "Tips and tricks", pinnedURL: url("tips"))),
            .split(Split(panes: [Tab(url: url("left"), title: "Left pane", pinnedURL: url("left")),
                                 Tab(url: url("right"), title: "Right pane", pinnedURL: url("right"))])),
        ])
        night.pinned = [.folder(folder), .tab(Tab(url: url("later"), title: "Read later", pinnedURL: url("later")))]
        if let n = bulkRows { fillBulk(warm, rows: n) }
        let window = BrowserWindowState(focusedSpaceID: warm.id, sidebarWidth: 228, frameWidth: 1280, frameHeight: 900)
        return BrowserModel(profiles: [profile], spaces: [warm, cool, night], windows: [window])
    }

    /// `rows` sidebar rows in one Space: pinned tabs, folders with children, and Today tabs.
    static func fillBulk(_ space: Space, rows: Int) {
        var pinned: [SidebarNode] = [], today: [SidebarNode] = []
        var made = 0, i = 0
        while made < rows {
            i += 1
            if i % 25 == 0 {
                let kids = (0..<9).map { k in SidebarNode.tab(Tab(url: url("f\(i)k\(k)"), title: "Folder \(i) item \(k)", pinnedURL: url("f\(i)k\(k)"))) }
                pinned.append(.folder(Folder(title: "Folder \(i)", isExpanded: true, children: kids)))
                made += 10
            } else if i % 2 == 0 {
                pinned.append(.tab(Tab(url: url("p\(i)"), title: "Pinned page \(i)", pinnedURL: url("p\(i)"))))
                made += 1
            } else {
                today.append(.tab(Tab(url: url("t\(i)"), title: "Today page \(i)")))
                made += 1
            }
        }
        space.pinned = pinned
        space.today = today
    }

    static func write(_ model: BrowserModel, to dir: URL) {
        model.rebuildIndex()
        let store = SnapshotStore(root: dir)
        store.saveNow(model: model)
        store.flush()
    }

    /// An Arc-shaped `windowTheme` with our own colors. The semantic palette is a
    /// simple OKLab derivation (light tint, dark shade); Arc's own formula is unknown.
    static func themeJSON(base: [UInt32], overlay: UInt32?, noise: Double, intensity: Double, appearance: String) -> Data {
        func rgb(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        func color(_ c: (Double, Double, Double), _ a: Double = 1) -> [String: Any] {
            ["red": c.0, "green": c.1, "blue": c.2, "alpha": a, "colorSpace": "extendedSRGB"]
        }
        func shade(_ hex: UInt32, L: Double, chroma: Double) -> (Double, Double, Double) {
            let (r, g, b) = rgb(hex)
            let lab = OKLab.fromSRGB(r, g, b)
            let k = lab.chroma > 0 ? chroma / lab.chroma : 0
            let (lr, lg, lb) = OKLab.toLinear(OKLab.Lab(L, lab.a * k, lab.b * k))
            return (OKLab.encode(lr), OKLab.encode(lg), OKLab.encode(lb))
        }
        let b0 = base[0]
        let light: [String: Any] = [
            "background": color(shade(b0, L: 0.95, chroma: 0.02)), "backgroundExtra": color(shade(b0, L: 0.99, chroma: 0.005)),
            "title": color(shade(b0, L: 0.22, chroma: 0.06)), "subtitle": color(shade(b0, L: 0.77, chroma: 0.07)),
            "hover": color(shade(b0, L: 0.9, chroma: 0.04)), "focus": color(shade(b0, L: 0.74, chroma: 0.09)),
            "foregroundPrimary": color(rgb(b0)), "foregroundSecondary": color(rgb(b0)), "foregroundTertiary": color(shade(b0, L: 0.95, chroma: 0.03)),
            "minContrastColor": color(shade(b0, L: 0.95, chroma: 0.03)), "maxContrastColor": color(shade(b0, L: 0.45, chroma: 0.13)),
            "cutoutColor": color(shade(b0, L: 0.95, chroma: 0.03)),
        ]
        let dark: [String: Any] = [
            "background": color(shade(b0, L: 0.22, chroma: 0.06)), "backgroundExtra": color(shade(b0, L: 0.16, chroma: 0.04)),
            "title": color(shade(b0, L: 0.92, chroma: 0.02)), "subtitle": color(shade(b0, L: 0.6, chroma: 0.01)),
            "hover": color(shade(b0, L: 0.6, chroma: 0.1), 0.48), "focus": color(shade(b0, L: 0.55, chroma: 0.12), 0.8075),
            "foregroundPrimary": color(shade(b0, L: 0.95, chroma: 0.03)), "foregroundSecondary": color(rgb(b0)), "foregroundTertiary": color(rgb(b0)),
            "minContrastColor": color(shade(b0, L: 0.45, chroma: 0.13)), "maxContrastColor": color(shade(b0, L: 0.95, chroma: 0.03)),
            "cutoutColor": color(shade(b0, L: 0.45, chroma: 0.13)),
        ]
        var gradient: [String: Any] = [
            "baseColors": base.map { color(rgb($0)) },
            "modifiers": ["overlay": "grain", "noiseFactor": noise, "intensityFactor": intensity],
            "translucencyStyle": "light", "wheel": ["analogous": [:] as [String: Any]],
        ]
        gradient["overlayColors"] = overlay.map { [color((0, 0, 0), 0), color(rgb($0))] } ?? []
        let theme: [String: Any] = [
            "primaryColorPalette": ["midTone": color(rgb(b0)), "shaded": color(rgb(b0)),
                                    "tintedLight": color(shade(b0, L: 0.95, chroma: 0.03)), "shadedDark": color(shade(b0, L: 0.45, chroma: 0.13))],
            "semanticColorPalette": ["appearanceBased": ["light": light, "dark": dark]],
            "background": ["single": ["_0": [
                "style": ["color": ["_0": ["blendedGradient": ["_0": gradient]]]],
                "contentOverBackgroundAppearance": appearance, "isVibrant": true,
            ]]],
        ]
        return try! JSONSerialization.data(withJSONObject: theme, options: [.sortedKeys])
    }
}
