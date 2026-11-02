import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenStore
import OpenSuggest

/// Scripted states over the synthetic world, run through the real `SuggestEngine`,
/// the real controller, and the real AppKit text path.
@MainActor
enum Scenes {
    static let names = ["empty", "typing-git", "cmd-l", "space-hint", "site-chip", "site-search", "calculator", "actions", "scrolled", "privacy-footer",
                        "completion", "completion-case", "completion-accepted", "split-row", "split-row-selected",
                        "actions-scope", "actions-scope-empty", "tabs-scope", "scope-chip-hover", "site-chip-query"]
    /// Stands in for Open's privacy page in renders (the App has none yet, so its footer hides line 2).
    static let samplePrivacyURL = URL(string: "https://open.example/privacy")!

    struct Env {
        let world: Synthetic.World
        let engine: SuggestEngine
        let history: HistoryStore
        let favicons: StaticFaviconSource
    }

    static func env(bulkHistory: Int = 0) -> Env {
        let world = Synthetic.world()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("commandbar-render-\(UUID().uuidString)")
        let history = blocking { await Synthetic.history(at: dir, bulk: bulkHistory) }
        let engine = SuggestEngine(model: world.model, history: history, fetcher: nil)
        return Env(world: world, engine: engine, history: history, favicons: Synthetic.favicons())
    }

    static func request(_ env: Env, mode: CommandBarMode) -> CommandBarRequest {
        let w = env.world
        return CommandBarRequest(mode: mode, profileID: w.profile.id, spaceID: w.studio.id, currentTabID: w.current.id,
                                 currentTabURL: w.current.url, currentTabTitle: w.current.displayTitle,
                                 allowsRemoteSuggestions: false, searchEngineID: "google")
    }

    static func theme(_ env: Env) -> CommandBarTheme {
        CommandBarTheme(style: SpaceThemeStyle(theme: env.world.studio.theme, system: .dark))
    }

    /// Builds the stage and drives it into state `name`.
    static func run(_ name: String, env: Env, size: CGSize, scale: CGFloat, backdrop: CommandBarBackdrop) throws -> Stage {
        let stage = Stage(size: size, scale: scale, engine: env.engine, backdrop: backdrop)
        let c = stage.controller
        c.favicons = env.favicons
        c.theme = theme(env)
        switch name {
        case "empty":
            c.present(request(env, mode: .newTab))
        case "typing-git":
            c.present(request(env, mode: .newTab))
            stage.type("git")
        case "cmd-l":
            c.present(request(env, mode: .editCurrentURL))
        case "site-search":
            c.present(request(env, mode: .newTab))
            stage.type("youtube")
            stage.settle()
            stage.key(.tab)
            stage.type("lofi beats")
        case "site-chip-query": // "wikipedia" + Tab + "bird": the S2 18/0018 shape
            c.present(request(env, mode: .newTab))
            stage.type("wikipedia")
            stage.settle()
            stage.key(.tab)
            stage.type("bird")
        case "actions-scope-empty": // "actions" + Tab: the Actions chip and the seed list
            c.present(request(env, mode: .newTab))
            stage.type("actions")
            stage.settle()
            stage.key(.tab)
        case "actions-scope": // the Actions scope with a query
            c.present(request(env, mode: .newTab))
            stage.type("actions")
            stage.settle()
            stage.key(.tab)
            stage.type("side")
        case "tabs-scope": // "tabs" + Tab + "review": tab rows only, the split as one row
            c.present(request(env, mode: .newTab))
            stage.type("tabs")
            stage.settle()
            stage.key(.tab)
            stage.type("review")
        case "scope-chip-hover": // the pointer on the chip: the close glyph (guess)
            c.present(request(env, mode: .newTab))
            stage.type("wikipedia")
            stage.settle()
            stage.key(.tab)
            stage.settle()
            let chip = c.view.debugChipFrame, p = c.view.panelFrame
            stage.mouse(.mouseMoved, at: CGPoint(x: p.minX + chip.midX, y: p.minY + chip.midY))
        case "site-chip":
            c.present(request(env, mode: .newTab))
            stage.type("youtube")
            stage.settle()
            stage.key(.tab)
        case "space-hint":
            c.present(request(env, mode: .newTab))
            stage.type("yt")
        case "calculator":
            c.present(request(env, mode: .newTab))
            stage.type("12*(3+4)")
        case "actions":
            c.present(request(env, mode: .newTab))
            stage.type("toggle")
        case "scrolled":
            c.present(request(env, mode: .newTab))
            stage.type("git")
            stage.settle()
            for _ in 0..<6 { stage.key(.down) }
        case "split-row": // empty Cmd+T: the split "Spec draft" | "Review notes" as one row (A0120 shape)
            c.present(request(env, mode: .newTab))
        case "split-row-selected": // "review": the split row selected (white plate, gap shows the fill)
            c.present(request(env, mode: .newTab))
            stage.type("review")
        case "completion": // "gith" + the selected "ub.com" (F0043 shape)
            c.present(request(env, mode: .newTab))
            stage.type("gith")
        case "completion-case": // typed "GitH": the field shows the candidate's case (F0062, CC-6)
            c.present(request(env, mode: .newTab))
            stage.type("GitH")
        case "completion-accepted": // Right arrow: the whole host, caret at the end (F0061)
            c.present(request(env, mode: .newTab))
            stage.type("gith")
            stage.settle()
            stage.key(.right)
        case "privacy-footer":
            c.privacyURL = samplePrivacyURL
            c.present(request(env, mode: .newTab))
            stage.settle()
            stage.key(.info, flags: .command)
        default:
            throw CLIError(description: "unknown state \(name); states: \(names.joined(separator: ", "))")
        }
        stage.settle()
        return stage
    }
}

/// A scene file: fixed rows and input, for matching an Arc capture. Scene files that
/// copy a capture's titles hold personal data and stay in `.re/` (git-ignored).
@MainActor
struct SceneFile: Decodable {
    struct Row: Decodable {
        var kind: String
        var title: String
        var subtitle: String?
        /// "favicon:<url>", "symbol:<name>", "plate:<name>"
        var icon: String
        /// "switch:<label>", "keys:⌘,T"
        var accessory: String?
        /// A Split View row: pane titles (drawn with the rule) and pane icons ("favicon:<url>", …).
        var titleParts: [String]?
        var paneIcons: [String]?
        var vertical: Bool?
    }

    var mode: String?
    var text: String?
    var selectAll: Bool?
    var placeholder: String?
    var leadingIcon: String?
    /// "info", "hint:<site>", "hint+space:<site>", "none"
    var trailing: String?
    var rows: [Row]
    var selected: Int?
    /// Path to an Arc-shaped theme JSON (for example `.re/runtime/theme-current-space.json`).
    var theme: String?
    /// Path to a backdrop PNG (the capture without the bar); its color profile is converted to sRGB.
    var backdrop: String?
    /// "#RRGGBB": the dominant backdrop color (edge style and flat fill).
    var backdropColor: String?
    /// Optional bottom color: the stage draws a vertical gradient from `backdropColor` (pages are rarely flat).
    var backdropBottomColor: String?
    /// Blur the backdrop image under the panel (default true when `backdrop` is set).
    var blurBackdrop: Bool?
    var windowWidth: Double?
    var windowHeight: Double?
    /// Shows the (i) privacy footer (with its "here" line).
    var footer: Bool?
    /// Field selection `[location, length]` in UTF-16 units: an inline completion's tail, or `[n, 0]` for a caret.
    var selection: [Int]?
    /// A scope chip's title ("Wikipedia", "Actions"); the placeholder becomes "Search…".
    var chip: String?

    static func load(_ path: String) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    var size: CGSize { CGSize(width: windowWidth ?? 2216, height: windowHeight ?? 1394) }

    func icon(_ s: String) -> CommandBarIcon {
        if s.hasPrefix("favicon:"), let u = URL(string: String(s.dropFirst(8))) { return .favicon(u, fallback: "globe") }
        if s.hasPrefix("plate:") { return .symbol(String(s.dropFirst(6)), plate: true) }
        if s.hasPrefix("symbol:") { return .symbol(String(s.dropFirst(7)), plate: false) }
        return .symbol("globe", plate: false)
    }

    var preview: CommandBarPreview {
        let rows = self.rows.enumerated().map { i, r -> CommandBarRow in
            var acc = CommandBarAccessory.none
            if let a = r.accessory {
                if a.hasPrefix("switch:") { acc = .switchTo(String(a.dropFirst(7))) }
                if a.hasPrefix("keys:") { acc = .keys(a.dropFirst(5).split(separator: ",").map(String.init)) }
            }
            let rowIcon = r.paneIcons.map { CommandBarIcon.split($0.map(icon), vertical: r.vertical ?? false) } ?? icon(r.icon)
            return CommandBarRow(id: "scene:\(i)", kind: SuggestionKind(rawValue: r.kind) ?? .navigate, title: r.title,
                                 subtitle: r.subtitle ?? "", icon: rowIcon, accessory: acc, titleParts: r.titleParts ?? [])
        }
        var trailingValue = CommandBarTrailing.info
        if let t = trailing {
            if t.hasPrefix("hint+space:") { trailingValue = .siteSearchHint(name: String(t.dropFirst(11)), space: true) }
            else if t.hasPrefix("hint:") { trailingValue = .siteSearchHint(name: String(t.dropFirst(5)), space: false) }
            else if t == "none" { trailingValue = .none }
        }
        let input = CommandBarInput(placeholder: placeholder ?? (chip == nil ? CommandBarText.placeholder : CommandBarText.scopePlaceholder),
                                    leadingIcon: icon(leadingIcon ?? "symbol:magnifyingglass"), chip: chip.map { .init(name: $0) }, trailing: trailingValue)
        return CommandBarPreview(mode: CommandBarMode(rawValue: mode ?? "newTab") ?? .newTab, text: text ?? "",
                                 selectAllText: selectAll ?? false, input: input, rows: rows, selectedIndex: selected ?? 0,
                                 showsFooter: footer ?? false,
                                 selectedRange: selection.flatMap { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil })
    }

    func loadTheme() throws -> CommandBarTheme {
        guard let theme else { return .default }
        let data = try Data(contentsOf: URL(fileURLWithPath: theme))
        guard let style = SpaceThemeStyle(arcWindowThemeJSON: Self.wrapTheme(data)) else { throw CLIError(description: "cannot parse theme \(theme)") }
        return CommandBarTheme(style: style)
    }

    /// Accepts either a full `windowTheme` object or one without the `background` key.
    static func wrapTheme(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if root["background"] == nil {
            root["background"] = ["single": ["_0": ["style": ["color": ["_0": ["blendedSingleColor": ["_0": [
                "color": ["red": 0.5, "green": 0.5, "blue": 0.5, "alpha": 1]]]]]], "contentOverBackgroundAppearance": "light"]]]
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    func loadBackdrop() throws -> CommandBarBackdrop {
        let color = backdropColor.flatMap(RGBA.init(hexString:)) ?? CommandBarBackdrop.darkPage.color
        guard let path = backdrop else { return CommandBarBackdrop(color: color) }
        let bitmap = try Bitmap(path: path)
        return CommandBarBackdrop(color: color, image: bitmap.cgImage, imageScale: CGFloat(bitmap.width) / size.width)
    }
}

extension RGBA {
    init?(hexString s: String) {
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

extension Bitmap {
    /// The bitmap as an sRGB CGImage.
    var cgImage: CGImage? {
        var copy = data
        let w = width, h = height
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
