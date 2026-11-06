import AppKit
import Foundation
import OpenDesign
import OpenModel
import OpenStore

@MainActor
enum Checks {
    static var passed = 0
    static var failed = 0
    static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 } else { failed += 1 }
        print("\(condition ? "OK" : "FAIL") \(message)")
    }

    static let primaryRoles: [(String, KeyPath<PrimaryPalette, P3>)] = [
        ("tintedLight", \.tintedLight), ("midTone", \.midTone), ("shaded", \.shaded), ("shadedDark", \.shadedDark),
    ]
    static let semanticRoles: [(String, KeyPath<SemanticPalette, RGBA>)] = [
        ("background", \.background), ("backgroundExtra", \.backgroundExtra), ("title", \.title),
        ("subtitle", \.subtitle), ("hover", \.hover), ("focus", \.focus),
        ("foregroundPrimary", \.foregroundPrimary), ("foregroundSecondary", \.foregroundSecondary),
        ("foregroundTertiary", \.foregroundTertiary), ("minContrastColor", \.minContrast),
        ("maxContrastColor", \.maxContrast), ("cutoutColor", \.cutout),
    ]

    static func color(_ hex: UInt32, alpha: Double = 1) -> RGBA { RGBA(hex: hex, alpha: alpha, .extendedSRGB) }
    static func error(_ a: RGBA, _ b: RGBA, clamp: Bool = false) -> Double {
        func value(_ x: Double) -> Double { clamp ? min(1, max(0, x)) : x }
        return zip([a.red, a.green, a.blue, a.alpha], [b.red, b.green, b.blue, b.alpha])
            .map { abs(value($0) - value($1)) }.max() ?? 0
    }

    /// Committed numbers: runtime-observations.md §3.3, the #FF8558 example.
    /// Its table gives clamped sRGB hex; the optional raw-JSON path checks extended values.
    static func fixtureMath() {
        let primary = ThemeColorMath.primaryPalette(key: ThemeColorMath.toP3(color(0xFF8558).modelColor))
        let palettes = ThemeColorMath.semanticPalettes(primary)
        let expectedPrimary = ["tintedLight": color(0xFFEAE3), "midTone": color(0xFF8558),
                               "shaded": color(0xFF8558), "shadedDark": color(0xA72E00)]
        let light = [0xF6EAE4, 0xFEFDFC, 0x320E00, 0xDCAC94, 0xEDD5C9, 0xD39779,
                     0xFF8558, 0xFF8558, 0xFFEAE3, 0xFFEAE3, 0xA72E00, 0xFFEAE3]
        let dark = [0x320E00, 0x190700, 0xF2E0D7, 0x807571, 0xBF673C, 0xB85727,
                    0xFFEAE3, 0xFF8558, 0xFF8558, 0xA72E00, 0xFFEAE3, 0xA72E00]
        let pe = primaryRoles.map { name, path in error(RGBA(ThemeColorMath.toExtendedSRGB(primary[keyPath: path])), expectedPrimary[name]!, clamp: true) }.max() ?? 0
        var se = 0.0
        for (index, role) in semanticRoles.enumerated() {
            se = max(se, error(palettes.light[keyPath: role.1], color(UInt32(light[index])), clamp: true))
            let alpha = index == 4 ? 0.48 : index == 5 ? 0.8075 : 1.0
            se = max(se, error(palettes.dark[keyPath: role.1], color(UInt32(dark[index]), alpha: alpha), clamp: true))
        }
        check(pe <= 1.0 / 255 && se <= 0.003,
              String(format: "M1 documented fixture primaryMax=%.6f semanticMax=%.6f", pe, se))
    }

    static func math(_ args: [String]) throws {
        if let file = RenderCLI.value(args, "--arc-json") {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any]
            let holders = (root?["sidebar"] as? [String: Any])?["containers"] as? [Any] ?? []
            let spaces = (holders.count > 1 ? holders[1] as? [String: Any] : nil)?["spaces"] as? [Any] ?? []
            var count = 0, pe = 0.0, se = 0.0
            func rgba(_ object: Any?) -> RGBA? {
                guard let v = object as? [String: Any], let r = v["red"] as? Double,
                      let g = v["green"] as? Double, let b = v["blue"] as? Double else { return nil }
                return RGBA(r, g, b, v["alpha"] as? Double ?? 1, .extendedSRGB)
            }
            for i in stride(from: 1, to: spaces.count, by: 2) {
                guard let space = spaces[i] as? [String: Any], let theme = (space["customInfo"] as? [String: Any])?["windowTheme"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: theme),
                      let seed = SpaceStyle.seed(from: SpaceTheme(importedArcThemeJSON: data)),
                      let storedPrimary = theme["primaryColorPalette"] as? [String: Any],
                      let storedSemantic = (theme["semanticColorPalette"] as? [String: Any])?["appearanceBased"] as? [String: Any] else { continue }
                count += 1
                let primary = ThemeColorMath.primaryPalette(key: ThemeColorMath.toP3(seed.keyColor))
                let palettes = ThemeColorMath.semanticPalettes(primary)
                for (name, path) in primaryRoles {
                    guard let expected = rgba(storedPrimary[name]) else { throw CLIError(description: "stored primary palette is incomplete") }
                    pe = max(pe, error(RGBA(ThemeColorMath.toExtendedSRGB(primary[keyPath: path])), expected))
                }
                for (name, palette) in [("light", palettes.light), ("dark", palettes.dark)] {
                    let stored = storedSemantic[name] as? [String: Any] ?? [:]
                    for (role, path) in semanticRoles {
                        guard let expected = rgba(stored[role]) else { throw CLIError(description: "stored semantic palette is incomplete") }
                        se = max(se, error(palette[keyPath: path], expected))
                    }
                }
            }
            check(count > 0 && pe <= 1.0 / 255 && se <= 0.003,
                  String(format: "M1 stored themes count=%d primaryMax=%.6f semanticMax=%.6f", count, pe, se))
        } else { fixtureMath() }
        if failed > 0 { throw CLIError(description: "theme math check failed") }
    }

    struct Random {
        var value: UInt64 = 0x9135_77AC_1206_4451
        mutating func next() -> Double {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Double(value >> 11) / 9007199254740992
        }
    }

    static func harmonyAndPad() {
        let key = ThemeColorMath.rgb(h: 0.17, s: 0.73, l: 0.47)
        let input = ThemeColorMath.hsl(key)
        var hueError = 0.0, slError = 0.0
        for wheel in SpaceStyleWheel.allCases {
            for count in 1...3 {
                let expected: [Double] = wheel == .analogous ? [0, 40, -40] : count == 2 ? [0, 180] : [0, 150, 210]
                let colors = ThemeColorMath.harmony(key: key, count: count, wheel: wheel)
                if colors.count != count { hueError = .infinity }
                for (i, color) in colors.enumerated() {
                    let result = ThemeColorMath.hsl(color)
                    let difference = abs((result.h - input.h) * 360 - expected[i]).truncatingRemainder(dividingBy: 360)
                    hueError = max(hueError, min(difference, 360 - difference))
                    slError = max(slError, abs(result.s - input.s), abs(result.l - input.l))
                }
            }
        }
        check(hueError <= 0.1 && slError < 1e-9, String(format: "M2 preserved analogous and complementary offsets (180 / 150,210), n=1...3 hueMax=%.8f slMax=%.8f", hueError, slError))
        var random = Random(), maxError = 0.0
        for mode in SpaceStyleAppearance.allCases {
            let range = ThemeColorMath.editorRange(key: key, mode: mode)
            for _ in 0..<2000 {
                let h = random.next(), s = 0.01 + 0.99 * random.next()
                let l = range.lowerBound + random.next() * (range.upperBound - range.lowerBound)
                let color = ThemeColorMath.rgb(h: h, s: s, l: l)
                let result = ThemeColorMath.color(at: ThemeColorMath.knob(for: color, range: range), saturation: s, range: range)
                maxError = max(maxError, error(RGBA(ThemeColorMath.toExtendedSRGB(color)), RGBA(ThemeColorMath.toExtendedSRGB(result))))
            }
        }
        check(maxError <= 1.0 / 255, String(format: "M3 6000 pad round trips max=%.9f", maxError))
    }

    static func appearances() {
        var random = Random(), forced = true
        for _ in 0..<500 {
            let key = RGBAColor(red: random.next(), green: random.next(), blue: random.next())
            forced = forced && SpaceThemeStyle(style: SpaceStyle(keyColor: key, appearance: .light), system: .dark).contentAppearance == .light
                && SpaceThemeStyle(style: SpaceStyle(keyColor: key, appearance: .dark), system: .light).contentAppearance == .dark
        }
        let samples: [(UInt32, ContentAppearance)] = [(0xFF8558, .light), (0x2F83E4, .light), (0xF8D558, .light), (0x926400, .dark)]
        let automatic = samples.allSatisfy { SpaceThemeStyle(style: SpaceStyle(keyColor: color($0.0).modelColor), system: .light).contentAppearance == $0.1 }
        check(forced && automatic, "M4 500 forced keys and four Automatic samples")
    }

    static func textures() {
        for scale in [1.0, 2.0] {
            for noise in [0.25, 0.5, 1.0] {
                for texture in SpaceStyleTexture.allCases {
                    let value = ThemeTexture.metrics(texture, noiseFactor: noise, scale: scale)!
                    let expected = ThemeTuning.textureTileDarkness[texture]!
                    check(abs(value.meanAlpha - expected) <= 0.0001
                          && abs(ThemeTexture.layerAlpha(texture, noiseFactor: noise) - noise * ThemeTuning.textureNoiseScale[texture]!) < 1e-12,
                          String(format: "M5 calibrated %@ noise=%.2f scale=%.0f tileMean=%.6f layerAlpha=%.4f", texture.rawValue, noise, scale, value.meanAlpha, ThemeTexture.layerAlpha(texture, noiseFactor: noise)))
                }
            }
        }
        let before = ThemeTexture.generationCount
        _ = ThemeTexture.tile(.sand, noiseFactor: 0.51, scale: 2)
        _ = ThemeTexture.tile(.sand, noiseFactor: 0.50, scale: 2)
        check(ThemeTexture.generationCount == before, "M5 noise changes reuse one tile per texture/scale")
    }

    static func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("space-editor-p1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try RenderCLI.fixtureModel(), store = SnapshotStore(root: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(SnapshotMapper.dto(from: model))
        try store.saveNow(model: model)
        guard let reloaded = try store.load() else { throw CLIError(description: "P1 reload failed") }
        check(try encoder.encode(SnapshotMapper.dto(from: reloaded)) == before, "P1 frozen schema-1 DTO round trip byte-identical")
        for space in 0..<3 {
            let scene = try RenderCLI.scene(model: reloaded, args: ["--space", String(space)], size: CGSize(width: 900, height: 700))
            scene.background.renderScale = 1
            let image = OffscreenRenderer().render(scene, scale: 1)
            let file = directory.appendingPathComponent("window-\(space).png")
            OffscreenRenderer.writePNG(image, to: file)
            check(try Data(contentsOf: file) == Data(contentsOf: RenderCLI.fixtureURL("window-\(space).png")), "P1 legacy window \(space) PNG byte-identical")
        }
        let first = reloaded.spaces[0]
        let tab = first.pinned.compactMap(\.tab).first!
        let folder = reloaded.spaces[2].pinned.compactMap(\.folder).first!
        first.theme = SpaceTheme(style: SpaceStylePresets.all[13].style)
        reloaded.setNodeIcon(id: tab.id, icon: .emoji("🧭")); reloaded.setNodeIcon(id: folder.id, icon: .named("planet"))
        try store.saveNow(model: reloaded)
        guard let edited = try store.load() else { throw CLIError(description: "P1 edited reload failed") }
        check(SnapshotMapper.structurallyEqual(reloaded, edited), "P1 editor style and both icon overrides round trip")

        // Exercise real creation and persistence, without an editor write.
        let newSpace = edited.createSpace(title: "Unthemed Space", profileID: edited.spaces[0].profileID)
        try store.saveNow(model: edited)
        guard let createdSnapshot = try store.load(), let created = createdSnapshot.space(id: newSpace.id) else {
            throw CLIError(description: "P1 new Space reload failed")
        }
        check(created.theme == SpaceTheme() && SpaceStyle.seed(from: created.theme) == nil,
              "P1 new Space creation persists no theme and seeds an empty editor")
    }

    static func run() throws {
        fixtureMath(); harmonyAndPad(); appearances(); costs(); textures(); cacheBounds(); try persistence()
        try EditorChecks.run()
        try PickerScene.check()
        print("checks: \(passed) passed, \(failed) failed")
        if failed > 0 { throw CLIError(description: "checks failed") }
    }

    static func costs() {
        for texture in SpaceStyleTexture.allCases {
            let start = ProcessInfo.processInfo.systemUptime
            let image = ThemeTexture.tile(texture, noiseFactor: 0.45, scale: 2)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            check(image != nil && ms < 500, String(format: "PERF cold tile %@ @2x %.2f ms (loose ceiling 500 ms)", texture.rawValue, ms))
        }
        for index in [4, 13, 22, 31, 40] {
            let style = SpaceThemeStyle(style: SpaceStylePresets.all[index].style, system: .dark)
            let start = ProcessInfo.processInfo.systemUptime
            let image = ThemeField.makeImage(style: style, windowSize: CGSize(width: 2216, height: 1394), isActive: true)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            check(image != nil && ms < 250, String(format: "PERF field style %d %.2f ms (loose ceiling 250 ms)", index, ms))
        }
    }
    static func cacheBounds() {
        let denimBefore = ThemeTexture.denimGenerationCount
        for bucket in 1...20 {
            _ = ThemeTexture.tile(.denim, noiseFactor: Double(bucket) / 20, scale: 2)
            for scale in [1.0, 2.0] { _ = ThemeTexture.tile(.grain, noiseFactor: Double(bucket) / 20, scale: scale) }
        }
        check(ThemeTexture.cachedTileCount <= ThemeTexture.cacheLimit, "M5 tile cache stays bounded after bucket churn")
        check(ThemeTexture.denimGenerationCount == denimBefore, "M5 denim normalized pattern is reused across buckets")
        for index in 1...40 { _ = ThemeTexture.tile(.grain, noiseFactor: 0.8, scale: 1 + Double(index) / 100) }
        check(ThemeTexture.cachedTileCount <= ThemeTexture.cacheLimit, "M5 oldest-half eviction stays bounded across backing scales")
        check(ThemeTexture.knobPreview(.grain, diameter: 40, scale: 0).width == 40
              && ThemeTexture.knobPreview(.grain, diameter: 40, scale: .nan).height == 40,
              "M5 invalid-scale preview returns a neutral disc without a missing-tile crash")
    }
}

private extension RGBA {
    init(_ c: RGBAColor) { self.init(c.red, c.green, c.blue, c.alpha, .extendedSRGB) }
}
