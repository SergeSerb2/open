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
    // Lead's open-latency target: final card by click +133ms, including
    // dispatch and the first display refresh (2026-11-13).
    public static let peekOpen: CFTimeInterval = 0.10
    public static let peekDismiss: CFTimeInterval = 0.14
    public static let peekExpand: CFTimeInterval = 0.22
}

/// Media plan §4.1, capture session 2 amendment (Step 2b). Row-relative points.
/// The speaker button sits right after the favicon: AX `[41, y + 7, 26, 26]`, and
/// the title moves from x 43 to x 69 (facts, S2 12/0013, 0022, 0027). The leading
/// recording slot and its dot are guesses (no capture; Arc names
/// `hasLeadingRecordingIndicator`).
public enum RowMediaMetrics {
    public static let buttonSize: CGFloat = 26          // fact S2 12/0022, 0027 (AX)
    public static let buttonX: CGFloat = 41             // fact: 6 pt after the favicon (x 17…35)
    public static let buttonY: CGFloat = 7              // fact
    public static let titleShift: CGFloat = 26          // fact: title AX x 43 → 69
    public static let recordingSlotWidth: CGFloat = 14  // guess (lead 2026-10-26)
    public static let recordingSlotHeight: CGFloat = 20 // guess: centered on the button (y 10)
    public static let recordingDot: CGFloat = 7         // guess
}

/// Media plan §13 (Step 3b). Capture session 2 frames are cited per value.
public enum MiniPlayerMetrics {
    public static let inset: CGFloat = 8                  // fact E2
    public static let gapAbove: CGFloat = 8               // fact E2: the pager ends 8 pt above the stack
    public static let rowHeight: CGFloat = 33             // fact E2, E3
    public static let cornerRadius: CGFloat = 10          // fit E2, E3; cornerCurve .continuous
    public static let button: CGFloat = 24                // code PP-16; fact E2
    public static let buttonY: CGFloat = 5                // inside a row; fact E2, E3
    public static let buttonPlateRadius: CGFloat = 5      // fit E3/E7: continuous RMS 0.034 vs 0.116 at 6
    public static let slotInset: CGFloat = 10             // first slot x, and the gap after the last slot; fact E2, E6
    public static let slotCount = 5                       // fact E2
    public static let faviconSize: CGFloat = 16           // fact E2
    public static let titleX: CGFloat = 14                // fact E3
    public static let titleBaseline: CGFloat = 22         // fact E3
    public static let titleGap: CGFloat = 10              // title end → first title-row button; fact E3
    public static let closeTrailing: CGFloat = 34         // Close x = cardW − 34; fact E3
    public static let pipTrailing: CGFloat = 58           // PiP x = cardW − 58; fact E3
    public static let stackOffset: CGFloat = 7            // fact E6
    public static let stackInset: CGFloat = 5             // per side, per level; fact E6
    public static let stackOpacityStep: CGFloat = 0.2     // fit E6
    public static let expandedGap: CGFloat = 5            // fact E7
    public static let shadowOpacity: Float = 0.21         // fit E2
    public static let shadowRadius: CGFloat = 4           // fit E2
    public static let collapseDelay: TimeInterval = 0.3   // guess
    public static let tooltipDelay: TimeInterval = 0.45   // code PP-6
    // Volume drawer: guess (§13.7 O2).
    public static let drawerSliderInset: CGFloat = 44
    public static let drawerTrackHeight: CGFloat = 4
    public static let drawerTrackRadius: CGFloat = 2
    public static let drawerKnob: CGFloat = 12
    public static let drawerShadowBlur: CGFloat = 2
    public static let drawerShadowOffset = CGSize(width: 0, height: -1)
    public static let volumeStep: Double = 0.05

    /// Card height: one row at rest, two expanded, three with the drawer.
    public static func cardHeight(expanded: Bool, drawer: Bool) -> CGFloat {
        expanded ? (drawer ? 3 : 2) * rowHeight : rowHeight
    }
    /// Slot k's x in a card of width w, on the backing pixel grid (halves round up). Fact E2, E6.
    public static func slotX(_ k: Int, cardWidth w: CGFloat, scale: CGFloat) -> CGFloat {
        let x = slotInset + CGFloat(k) * (w - 2 * slotInset - button) / CGFloat(slotCount - 1)
        return (x * scale + 0.5).rounded(.down) / scale
    }
}

/// Media plan §4.4/§4.6. PP-6 proves corner button sizes/padding and the 15 s skip.
public enum PiPMetrics {
    /// Video PiP window corner, continuous curve. Capture session 2 item 13 (13/0002–0058, window alpha) equals an
    /// on-screen continuous 6 pt calibration window within 1/255 (MediaRenders/section3-parity).
    public static let cornerRadius: CGFloat = 6
    /// Document PiP keeps the earlier guess; no capture shows a Document PiP window.
    public static let documentCornerRadius: CGFloat = 12
    /// Video PiP inner edge: a 1 pt white hairline at ≈ 0.12 alpha over the video on all four sides
    /// (capture session 2 item 13, ring 0 vs ring 1 over 58 frames: median 0.121; MediaRenders/section3-parity).
    public static let edgeStrokeWidth: CGFloat = 1
    public static let edgeStrokeAlpha: CGFloat = 0.12
    public static let minimum = CGSize(width: 284, height: 160)
    public static let compactWidth: CGFloat = 300
    public static let compactPlayGlyph: CGFloat = 24
    public static let compactPadding: CGFloat = 8
    public static let regularPadding: CGFloat = 10
    public static let cornerButton: CGFloat = 28
    public static let cornerPitch: CGFloat = 32
    public static let playButton: CGFloat = 48
    public static let skipButton: CGFloat = 40
    public static let skipGlyph: CGFloat = 20
    public static let compactSkipGlyph: CGFloat = 16
    public static let minimumSkipWidth: CGFloat = 168
    public static let packedTrackGap: CGFloat = 16
    public static let scrubDragThreshold: CGFloat = 3
    public static let disabledControlOpacity: CGFloat = 0.4
    public static let centerGlyphShadowRadius: CGFloat = 2 // guess, N3; pending capture
    public static let documentButtonRadius: CGFloat = 5
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
    public static let screenInset: CGFloat = 10 // video PiP, capture session 2 item 13
    public static let documentScreenInset: CGFloat = 16 // Document PiP remains provisional
    public static let initialScreenFraction: CGFloat = 0.125 // /8 fits one 2560x1440 capture; guess elsewhere
    public static let maximumScreenFraction: CGFloat = 0.5
    public static let minimizedScale: CGFloat = 0.9
    public static let hoverScale: CGFloat = 1.08
    public static let expandedControlGap: CGFloat = 6
    public static let meetingButton: CGFloat = 32
    public static let meetingGap: CGFloat = 12
    public static let precisionLabelGap: CGFloat = 8
    public static let precisionLabelHeight: CGFloat = 14
    public static let hideDelay: TimeInterval = 2
    public static let scrubberHeight: CGFloat = 4
    public static let scrubberHoverHeight: CGFloat = 6
    public static let scrubberHitHeight: CGFloat = 20
    public static let precisionStep: CGFloat = 40
    public static let maximumPrecision: Double = 8
    public static let documentTopBar: CGFloat = 28
    public static let documentTitleGap: CGFloat = 6 // guess pending S11
    public static let documentFavicon: CGFloat = 16
    public static let documentLeading: CGFloat = 10
    public static let documentButton: CGFloat = 20
    public static let documentButtonGap: CGFloat = 6
    public static let documentTrailing: CGFloat = 8
}
