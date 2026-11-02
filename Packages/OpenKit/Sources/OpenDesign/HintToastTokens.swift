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
    /// Plate, text, rim, shadow and fill colors come from the shared toast rule
    /// (`SpaceThemeStyle.toastFill`, `toastText`, `toastKeycapFill`; `ToastMetrics` rim and shadow):
    /// one source for this hint and `ToastView` (page-platform §4.1.2). The A0440 fit is the
    /// default dark theme there: fill `#442B68` → `#332350`, opaque white text (ink core `#F1F0F3`,
    /// ΔE00 0.05 in `tools/verification/hint-compare.py`), rim black 0.20 (`#2A1B40`), plate white 0.10.

    /// Motion: scale 0.9 → 1 and fade in (guess duration), stay, fade out (lifetime measured ≈ 5–6 s).
    public static let inDuration: CFTimeInterval = 0.20
    public static let lifetime: CFTimeInterval = 5.5
    public static let outDuration: CFTimeInterval = 0.25
    public static let inScale: CGFloat = 0.9
}
