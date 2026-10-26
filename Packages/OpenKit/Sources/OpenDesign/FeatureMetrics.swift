import CoreGraphics
import QuartzCore

/// Additive M4 metrics. Existing sidebar and design tokens stay unchanged.
/// Evidence: docs/re/interaction-states.md §11, F0081 AX and focus-ring pixels.
public enum SplitMetrics {
    public static let gap: CGFloat = 10
    public static let barHeight: CGFloat = 32
    public static let ringWidth: CGFloat = 2
    /// Lead decision Q2; the original measurement is unavailable (plan choice).
    public static let minimumPane: CGFloat = 200
    public static let back = CGRect(x: 5, y: 4, width: 32, height: 24)
    public static let forward = CGRect(x: 42, y: 4, width: 32, height: 24)
    public static let reload = CGRect(x: 79, y: 4, width: 32, height: 24)
}

/// Evidence: docs/re/interaction-states.md §12, F0090 AX, F0102 pixels.
public enum PeekMetrics {
    public static let widthFraction: CGFloat = 0.8
    public static let verticalInset: CGFloat = 2
    public static let buttonDiameter: CGFloat = 33
    public static let buttonHitWidth: CGFloat = 35
    public static let buttonGap: CGFloat = 13
    public static let buttonTop: CGFloat = 9
    public static let buttonPitch: CGFloat = 43
    public static let scrimAlpha: Double = 0.70
    /// Default-Space fallback measured from F0090/F0102: §12 circle core and
    /// backdrop fit in docs/re/interaction-states.md. No existing token is changed.
    public static let defaultControls = RGBA(hex: 0x050627)
    public static let defaultScrim = RGBA(hex: 0x0E0019, alpha: 0.70)
    /// F0090 core glyphs are lavender-white (sRGB); fitted source tint after AA.
    public static let defaultGlyph = RGBA(hex: 0xF0F1FF)
    /// Fitted guesses from F0090's ≈16 pt shadow, not measured animation values.
    public static let shadowOpacity: Float = 0.18
    public static let shadowRadius: CGFloat = 8
}

extension Motion {
    /// Provisional guesses: docs/re/interaction-states.md §19 has no timing capture.
    public static let splitExpand: CFTimeInterval = 0.22
    public static let splitRemove: CFTimeInterval = 0.14
    public static let peekOpen: CFTimeInterval = 0.18
    public static let peekDismiss: CFTimeInterval = 0.14
    public static let peekExpand: CFTimeInterval = 0.22
}
