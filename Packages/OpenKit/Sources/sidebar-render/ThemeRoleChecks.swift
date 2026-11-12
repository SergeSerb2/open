import AppKit
import OpenDesign
import OpenModel

/// `sidebar-render theme-roles --ref tools/verification/sidebar-theme-roles.json [--table]`:
/// Open's sidebar role set (`SpaceThemeStyle` → `SidebarRoles`, `ThemeField`) against
/// Arc 1.172.2's measured roles on 45 theme cases and 18 polarity boundary colours
/// (capture session 3). Background and primary title within ΔE00 3, active plate within
/// ΔE00 2, every fixed-opacity role within ± 0.03, polarity equal everywhere.
@MainActor
enum ThemeRoleChecks {
    struct Reference: Decodable {
        struct Arc: Decodable {
            var bg: [String: String]
            var title: String
            var polarity: String
            var activePlate: String?
            var activeBeside: String?
        }
        struct Case: Decodable {
            var id: String
            var mode: String
            var system: String
            var theme: String?
            var key: String?
            var keySpace: String?
            var intensity: Double?
            var colorCount: Int?
            var wheel: String?
            var noise: Double?
            var arc: Arc
        }
        struct Boundary: Decodable {
            var id: String
            var key: String
            var keySpace: String
            var title: String
            var polarity: String
        }
        struct Tolerances: Decodable {
            var backgroundDeltaE00: Double
            var titleDeltaE00: Double
            var plateDeltaE00: Double
            var opacity: Double
        }
        var window: [Double]
        var samplePoints: [String: [Double]]
        var tolerances: Tolerances
        var fixedOpacities: [String: [Double]]
        var cases: [Case]
        var boundary: [Boundary]
    }

    static func run(_ args: [String]) throws {
        guard let path = RenderCLI.value(args, "--ref") else { throw CLIError(description: "theme-roles needs --ref FILE.json") }
        let ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let table = args.contains("--table")
        var failures = 0, passes = 0
        func check(_ ok: Bool, _ what: String) {
            if ok { passes += 1 } else { failures += 1 }
            if !ok || !table { print("  \(ok ? "OK  " : "FAIL") \(what)") }
        }
        let t = ref.tolerances
        let size = CGSize(width: ref.window[0], height: ref.window[1])
        if table {
            print("| Case | Arc bg / title | Open bg / title | ΔE00 bg (max of 3) · title | Contrast Arc · Open | Active plate Arc / Open, ΔE00 | Polarity Arc · Open |")
            print("|---|---|---|---|---|---|---|")
        }
        for c in ref.cases {
            let style = makeStyle(c)
            let field = ThemeField.Evaluator(style: style, windowSize: size, isActive: true)
            let system: ContentAppearance = c.system == "dark" ? .dark : .light
            let content = style.resolvedAppearance(system: system)
            let roles = style.roles(content)
            // Open's grain is a black tile layer: its mean darkens the field by a factor.
            let grain = 1 - ThemeTuning.textureTileDarkness[style.texture]! * ThemeTexture.layerAlpha(style.texture, noiseFactor: style.noiseFactor)
            var worstBG = 0.0, middle = [0.0, 0, 0], arcSum = [0.0, 0, 0], oursSum = [0.0, 0, 0]
            for (name, point) in ref.samplePoints.sorted(by: { $0.key < $1.key }) {
                guard let arc = c.arc.bg[name] else { continue }
                let (r, g, b) = field.color(u: point[0] / size.width, v: point[1] / size.height)
                let ours = [r, g, b].map { min(255, max(0, $0 * 255 * grain)) }
                if style.noiseFactor == 0 { worstBG = max(worstBG, ColorMath.deltaE2000(hex(arc), ours)) }
                for i in 0..<3 { arcSum[i] += hex(arc)[i]; oursSum[i] += ours[i] }
                if name == "middle_center" { middle = ours }
            }
            // Grain speckle is about ± 6 levels per point: compare the mean of the points.
            if style.noiseFactor > 0 {
                let n = Double(ref.samplePoints.count)
                worstBG = ColorMath.deltaE2000(arcSum.map { $0 / n }, oursSum.map { $0 / n })
            }
            let title = components(roles.title)
            let titleDE = ColorMath.deltaE2000(hex(c.arc.title), title)
            let polarity = content == .dark ? "lightText" : "darkText"
            check(worstBG <= t.backgroundDeltaE00, "\(c.id) background ΔE00 \(f(worstBG)) ≤ \(f(t.backgroundDeltaE00))")
            check(titleDE <= t.titleDeltaE00, "\(c.id) title \(hexString(title)) vs Arc \(c.arc.title) ΔE00 \(f(titleDE))")
            check(polarity == c.arc.polarity, "\(c.id) polarity \(polarity) vs Arc \(c.arc.polarity)")
            var plateText = "—"
            if let arcPlate = c.arc.activePlate, let beside = c.arc.activeBeside, content == .light {
                // The plate is a layer: composite it over Arc's own background beside it.
                let plate = over(roles.activePlate, hex(beside))
                let de = ColorMath.deltaE2000(hex(arcPlate), plate)
                check(de <= t.plateDeltaE00, "\(c.id) active plate \(hexString(plate)) vs Arc \(arcPlate) ΔE00 \(f(de))")
                plateText = "`\(arcPlate)` / `\(hexString(plate))`, \(f(de))"
            }
            for (role, values) in ref.fixedOpacities.sorted(by: { $0.key < $1.key }) {
                guard let rgba = fixed(roles, role) else { check(false, "\(c.id) role \(role) missing"); continue }
                let expected = content == .dark ? values[1] : values[0]
                let ink = content == .dark ? rgba.red > 0.99 && rgba.green > 0.99 && rgba.blue > 0.99 : rgba.red < 0.01 && rgba.green < 0.01 && rgba.blue < 0.01
                // The default theme's hover plate is its own measured value (Part C (1)).
                let target = role == "rowHover" && c.theme == "default" ? (content == .dark ? 0.10 : 0.046) : expected
                check(ink && abs(rgba.alpha - target) <= t.opacity, "\(c.id) \(role) \(content == .dark ? "white" : "black") \(f(rgba.alpha)) vs \(f(target))")
            }
            if table {
                let contrastArc = contrast(hex(c.arc.bg["middle_center"] ?? "#000000"), hex(c.arc.title))
                let contrastOurs = contrast(middle, title)
                print("| \(c.id) | `\(c.arc.bg["middle_center"] ?? "?")` / `\(c.arc.title)` | `\(hexString(middle))` / `\(hexString(title))` | \(f(worstBG)) · \(f(titleDE)) | \(f(contrastArc)) · \(f(contrastOurs)) | \(plateText) | \(c.arc.polarity) · \(polarity) |")
            }
        }
        for b in ref.boundary {
            let style = SpaceThemeStyle(style: SpaceStyle(keyColor: color(b.key, b.keySpace)), system: .light)
            let content = style.resolvedAppearance(system: .light)
            let polarity = content == .dark ? "lightText" : "darkText"
            let title = components(style.roles(content).title)
            let de = ColorMath.deltaE2000(hex(b.title), title)
            check(polarity == b.polarity, "boundary \(b.id) polarity \(polarity) vs Arc \(b.polarity)")
            check(de <= t.titleDeltaE00, "boundary \(b.id) title \(hexString(title)) vs Arc \(b.title) ΔE00 \(f(de))")
        }
        // Increase Contrast (lead decision §2.8): off is identical; on raises the roles.
        // Pad hue 0° Dark (#945D5F, title 4.08 : 1) can reach 4.5 with a lighter title;
        // slate (#9495AB) cannot even with white: the title stops at white (open question).
        func raisedContrast(_ key: String, _ mode: SpaceStyleAppearance) -> (SidebarRoles, SidebarRoles, Double) {
            let style = SpaceThemeStyle(style: SpaceStyle(keyColor: color(key, key == "#666786" ? "p3" : "srgb"), appearance: mode), system: .light)
            let content = style.resolvedAppearance(system: .light)
            let plain = style.roles(content), raised = style.roles(content, increaseContrast: true)
            let e = ThemeField.Evaluator(style: style, windowSize: size, isActive: true)
            let worst = [0.0, 0.5, 1.0].map { v -> Double in
                let (r, g, b) = e.color(u: 0.1, v: v)
                return contrast([r, g, b].map { $0 * 255 }, components(raised.title))
            }.min() ?? 0
            check(plain == SidebarRoles(content: content, title: style.titleColor(content).withAlpha(1), isDefaultTheme: false),
                  "Increase Contrast off (\(key)): role set equals the plain rules")
            return (plain, raised, worst)
        }
        let (_, pad, padContrast) = raisedContrast("#852F32", .dark)
        check(padContrast >= 4.45 && pad.subtitle.alpha == 0.75 && pad.spaceTitle.alpha == 0.75 && pad.newTabLabel.alpha == 0.60
              && pad.separator.alpha == 0.30, "Increase Contrast on, pad 0° Dark: title \(f(padContrast)) : 1 ≥ 4.5, secondary 0.75 / 0.60 / 0.30")
        let (_, slate, slateContrast) = raisedContrast("#666786", .automatic)
        check(components(slate.title).allSatisfy { $0 > 254 }, "Increase Contrast on, slate: title stops at white (\(f(slateContrast)) : 1, 4.5 is out of reach)")
        print("sidebar-render theme-roles: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func makeStyle(_ c: Reference.Case) -> SpaceThemeStyle {
        let system: ContentAppearance = c.system == "dark" ? .dark : .light
        guard c.theme != "default", let key = c.key else { return .defaultTheme(system: system) }
        let mode: SpaceStyleAppearance = c.mode == "dark" ? .dark : c.mode == "light" ? .light : .automatic
        let style = SpaceStyle(keyColor: color(key, c.keySpace ?? "srgb"), colorCount: c.colorCount ?? 1,
                               wheel: c.wheel == "complementary" ? .complementary : .analogous, appearance: mode,
                               noiseFactor: c.noise ?? 0, intensityFactor: c.intensity ?? 0.8)
        return SpaceThemeStyle(style: style, system: system)
    }

    static func fixed(_ r: SidebarRoles, _ name: String) -> RGBA? {
        switch name {
        case "subtitle": r.subtitle
        case "spaceTitle": r.spaceTitle
        case "newTabLabel": r.newTabLabel
        case "newTabGlyph": r.newTabGlyph
        case "placeholder": r.placeholder
        case "urlText": r.urlText
        case "bottomGlyph": r.bottomGlyph
        case "toolbarGlyphDisabled": r.toolbarGlyphDisabled
        case "separator": r.separator
        case "fieldFill": r.fieldFill
        case "fieldHover": r.fieldHover
        case "tileFill": r.tileFill
        case "rowHover": r.rowHover
        default: nil
        }
    }

    static func color(_ s: String, _ space: String) -> RGBAColor {
        let v = hex(s).map { $0 / 255 }
        if space == "p3" { return ThemeColorMath.toExtendedSRGB(P3(v[0], v[1], v[2])) }
        return RGBAColor(red: v[0], green: v[1], blue: v[2])
    }
    static func hex(_ s: String) -> [Double] {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        let n = UInt32(h, radix: 16) ?? 0
        return [Double((n >> 16) & 0xFF), Double((n >> 8) & 0xFF), Double(n & 0xFF)]
    }
    /// sRGB 0…255 of an opaque role colour (converted when it is not authored in sRGB).
    static func components(_ c: RGBA) -> [Double] {
        let converted = c.cgColor.converted(to: CGColorSpace(name: CGColorSpace.extendedSRGB)!, intent: .relativeColorimetric, options: nil)
        let v = converted?.components ?? [0, 0, 0, 1]
        return (0..<3).map { min(255, max(0, Double(v[$0]) * 255)) }
    }
    static func over(_ layer: RGBA, _ background: [Double]) -> [Double] {
        let top = components(layer.withAlpha(1))
        return (0..<3).map { top[$0] * layer.alpha + background[$0] * (1 - layer.alpha) }
    }
    static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func l(_ c: [Double]) -> Double {
            func lin(_ v: Double) -> Double { let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])
        }
        let x = l(a), y = l(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func hexString(_ c: [Double]) -> String { String(format: "#%02X%02X%02X", Int(c[0].rounded()), Int(c[1].rounded()), Int(c[2].rounded())) }
    static func f(_ v: Double) -> String { String(format: "%.2f", v) }
}
