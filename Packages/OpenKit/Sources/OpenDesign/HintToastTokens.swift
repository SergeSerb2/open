import CoreGraphics
import Foundation

/// First-hide hint toast ("You can use [⌘S] to easily show and hide your Sidebar!"), measured on
/// session 1 frame A0440 (window 2216 wide, sidebar hidden; `docs/re/sidebar-completion.md` §10,
/// completion plan §3.12). Frame `[W − 5 − w, 4, w, 47]` with
/// w = 12 + text₁ + 7 + plate + 6 + text₂ + 13 (399 at the measured ink 79 + 37 + 245).
public enum HintToastMetrics {
    public static let height: CGFloat = 47
    public static let trailingInset: CGFloat = 5
    public static let topInset: CGFloat = 4
    /// Continuous corner ≈ 10 (row insets 7, 5, 4, 3, 2, 1, 0 from the top).
    public static let radius: CGFloat = 10
    /// Ink gaps on A0440 with exclusive pixel edges (toast x 1812 ..< 2211): "You can use" ink
    /// starts 12 pt in (1824), ends at 1903, 7 pt before the plate (1910 ..< 1947); the next run
    /// starts 6 pt after it (1953) and ends at 2198, 13 pt before the edge.
    public static let leadingPadding: CGFloat = 12
    public static let trailingPadding: CGFloat = 13
    public static let textToPlate: CGFloat = 7
    public static let plateToText: CGFloat = 6
    /// Lowercase ink rows 25–32: the baseline sits at y + 28.
    public static let baselineY: CGFloat = 28
    public static let fontSize: CGFloat = 14
    /// Keycap plate `[x + 98, y + 10, 37, 27]` at the measured text: width = keycap ink + 18.
    public static let plateY: CGFloat = 10
    public static let plateHeight: CGFloat = 27
    public static let plateInkPadding: CGFloat = 18
    public static let plateRadius: CGFloat = 6
    public static let plateAlpha: Double = 0.10
    /// Text ink core `#F1F0F3` on A0440; opaque white reproduces that antialiased core
    /// (ΔE00 0.05, `tools/verification/hint-compare.py`); 0.95 gave 2.03 (fitted).
    public static let textAlpha: Double = 1.0
    /// 1 px darker rim `#2A1B40` over the fill: black 0.20 (fitted).
    public static let rimAlpha: Double = 0.20
    /// Soft shadow, ≈ 8 % darkening at the edge, gone after ≈ 9 pt (fitted).
    public static let shadowOpacity: Float = 0.10
    public static let shadowRadius: CGFloat = 8
    public static let shadowOffsetY: CGFloat = 2
    /// Default dark theme fill: vertical gradient, top `#442B68` (y 6) → bottom `#332350` (y 47).
    public static let defaultTop = RGBA(hex: 0x442B68)
    public static let defaultBottom = RGBA(hex: 0x332350)
    /// Other themes (guess): the theme's tooltip fill lightened (top) and darkened (bottom) by
    /// this much OKLab L.
    public static let themedLightness: Double = 0.06
    /// Motion: scale 0.9 → 1 and fade in (guess duration), stay, fade out (lifetime measured ≈ 5–6 s).
    public static let inDuration: CFTimeInterval = 0.20
    public static let lifetime: CFTimeInterval = 5.5
    public static let outDuration: CFTimeInterval = 0.25
    public static let inScale: CGFloat = 0.9

    /// Gradient stops (top, bottom) for a Space style.
    public static func fill(for style: SpaceThemeStyle) -> (top: RGBA, bottom: RGBA) {
        guard style.lightPalette != nil else { return (defaultTop, defaultBottom) }
        let base = style.tooltipFill
        func shifted(_ dL: Double) -> RGBA {
            var lab = OKLab.fromSRGB(base.red, base.green, base.blue)
            lab.L = min(1, max(0, lab.L + dL))
            let (r, g, b) = OKLab.toLinear(lab)
            return RGBA(min(1, max(0, OKLab.encode(r))), min(1, max(0, OKLab.encode(g))), min(1, max(0, OKLab.encode(b))))
        }
        return (shifted(themedLightness), shifted(-themedLightness))
    }
}
