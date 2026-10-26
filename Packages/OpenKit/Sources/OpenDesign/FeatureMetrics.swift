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
    /// Host group: the copy button sits 3 pt before the host text, and a 24 pt slot
    /// mirrors it after the text (F0081 AX: 24 · 3 · host · 3 · 24, centered on the bar).
    public static let hostSlot: CGFloat = 25
    /// Space kept between the host group and the side controls. guess.
    public static let barControlGap: CGFloat = 4
    /// Narrower than this, the host and copy button hide. guess: about three characters.
    public static let hostMinimumWidth: CGFloat = 28
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
    /// backdrop fit in docs/re/interaction-states.md. The default tint is
    /// refitted against F0090 sidebar samples (docs/m4.md); the earlier tint was a guess. No existing token is changed.
    public static let defaultControls = RGBA(hex: 0x050627)
    public static let defaultScrim = RGBA(hex: 0x000013, alpha: 0.70)
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

/// Media plan §4.1. Existing row geometry; recording dot size/color are provisional (S9).
public enum RowMediaMetrics {
    public static let buttonSize: CGFloat = 20
    public static let gapAfterTitle: CGFloat = 2
    public static let y: CGFloat = 10
    public static let recordingDot: CGFloat = 7
}

/// Media plan §4.2; guesses stay centralized until S3–S8. PP-6/16/17 supply the noted constants.
public enum MiniPlayerMetrics {
    public static let inset: CGFloat = 8
    public static let verticalInset: CGFloat = 4
    public static let height: CGFloat = 68
    public static let cornerRadius: CGFloat = 10
    public static let titleRowHeight: CGFloat = 36
    public static let titleX: CGFloat = 35
    public static let titleBaseline: CGFloat = 23
    public static let titleTrailing: CGFloat = 9
    public static let rightButtonPitch: CGFloat = 26
    public static let favicon = CGRect(x: 9, y: 9, width: 18, height: 18)
    public static let faviconInk: CGFloat = 16
    public static let button: CGFloat = 24 // PP-16
    public static let rightButtonInset: CGFloat = 30
    public static let titleButtonY: CGFloat = 6
    public static let controlsY: CGFloat = 40
    public static let controlsInset: CGFloat = 6
    public static let controlsPitch: CGFloat = 28
    public static let stackOffset: CGFloat = 5
    public static let stackWidthOffset: CGFloat = 6
    public static let stackOpacity: Float = 0.3
    public static let expandedGap: CGFloat = 6
    public static let collapseDelay: TimeInterval = 0.3
    public static let tooltipDelay: TimeInterval = 0.45 // PP-6
    public static let drawerHeight: CGFloat = 28
    public static let drawerTrackHeight: CGFloat = 4
    public static let drawerKnob: CGFloat = 12
    public static let volumeStep: Double = 0.05
    public static let marqueeLeftFade: CGFloat = 4 // PP-17
    public static let marqueeRightFade: CGFloat = 8
    public static let marqueeSpacing: CGFloat = 32
    public static let marqueeDelay: TimeInterval = 3
    public static let marqueeSpeed: CGFloat = 30 // guess, pt/s
}

/// Media plan §4.4/§4.6. PP-6 proves corner button sizes/padding and the 15 s skip.
public enum PiPMetrics {
    public static let cornerRadius: CGFloat = 12
    public static let minimum = CGSize(width: 284, height: 160)
    public static let compactWidth: CGFloat = 300
    public static let compactPadding: CGFloat = 8
    public static let regularPadding: CGFloat = 10
    public static let cornerButton: CGFloat = 28
    public static let cornerPitch: CGFloat = 32
    public static let playButton: CGFloat = 48
    public static let skipButton: CGFloat = 40
    public static let skipGlyph: CGFloat = 24
    public static let skipDistance: CGFloat = 72
    public static let compactSkipDistance: CGFloat = 56
    public static let trackButton: CGFloat = 32
    public static let trackDistance: CGFloat = 120
    public static let skipSeconds: Double = 15
    public static let topScrim: CGFloat = 56
    public static let bottomScrim: CGFloat = 64
    public static let pillHeight: CGFloat = 24
    public static let pillPadding: CGFloat = 10
    public static let bottomControlsOffset: CGFloat = 16
    public static let screenInset: CGFloat = 16
    public static let initialScreenFraction: CGFloat = 0.2
    public static let maximumScreenFraction: CGFloat = 0.5
    public static let hoverScale: CGFloat = 1.08
    public static let hideDelay: TimeInterval = 2
    public static let scrubberHeight: CGFloat = 4
    public static let scrubberHoverHeight: CGFloat = 6
    public static let scrubberHitHeight: CGFloat = 20
    public static let precisionStep: CGFloat = 40
    public static let maximumPrecision: Double = 8
    public static let documentTopBar: CGFloat = 28
    public static let documentFavicon: CGFloat = 16
    public static let documentLeading: CGFloat = 10
    public static let documentButton: CGFloat = 20
    public static let documentButtonGap: CGFloat = 6
    public static let documentTrailing: CGFloat = 8
}
