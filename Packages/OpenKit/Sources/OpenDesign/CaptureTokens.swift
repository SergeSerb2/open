import AppKit

/// The Capture tool (page-platform plan §4.6). Arc's overlay, result panel, and portrait
/// canvas were never captured (PG-6.6), so every value here is a guess until captures C-C1
/// and C-C2 exist; each is one token so a capture fixes it in one edit.
/// (Section 8 decision: these tokens live in their own file instead of `PageTokens.swift`,
/// so the toast and capture work can land in either order without an add/add conflict.)
public enum CaptureMetrics {
    // §4.6.2 Cmd+Shift drag
    /// A held Cmd+Shift mouse-down becomes an area capture after this much pointer travel.
    public static let dragThreshold: CGFloat = 4

    // §4.6.3 Area overlay
    public static let dimAlpha: Double = 0.35
    /// 1 pt white 0.95 inside the selection edge, 1 pt black 0.25 outside it.
    public static let edgeInner = RGBA.white(0.95)
    public static let edgeOuter = RGBA.black(0.25)
    public static let edgeWidth: CGFloat = 1
    /// `W × H` in page points under the selection (above it when there is no room).
    public static let sizeLabelFont = FontToken(11, .medium)
    public static let sizeLabelFill = RGBA.black(0.65)
    public static let sizeLabelText = RGBA.white(1)
    public static let sizeLabelHeight: CGFloat = 20
    public static let sizeLabelRadius: CGFloat = 5
    public static let sizeLabelPadding: CGFloat = 7
    public static let sizeLabelGap: CGFloat = 6
    /// "Drag to capture. Press Esc to cancel." on the toast fill, centered 16 pt from the page top.
    public static let hintText = "Drag to capture. Press Esc to cancel."
    public static let hintFont = FontToken(13, .medium)
    public static let hintHeight: CGFloat = 28
    public static let hintRadius: CGFloat = 14
    public static let hintPadding: CGFloat = 14
    public static let hintTop: CGFloat = 16
    public static let hintFadeOut: CFTimeInterval = 0.15
    /// A smaller drag cancels the capture.
    public static let minimumSelection: CGFloat = 8

    // §4.6.4 Pipeline
    /// Lazy images get this long to load before a full-page capture (PG-6.4 `FullPageCaptureDelay`; value guess).
    public static let fullPageSettle: TimeInterval = 1.0
    /// Full-page height cap in device pixels (memory bound, guess). A taller page is cut.
    public static let fullPageMaxDevicePixels = 32_768
    /// Portrait: the page image is 86 % of the canvas width on a 4:5 canvas.
    public static let portraitImageFraction: CGFloat = 0.86
    public static let portraitAspect: CGFloat = 4.0 / 5.0
    /// Corner radius, shadow blur, and shadow y offset as fractions of the page image width.
    public static let portraitCornerFraction: CGFloat = 0.02
    public static let portraitShadowAlpha: CGFloat = 0.25
    public static let portraitShadowBlurFraction: CGFloat = 0.03
    public static let portraitShadowOffsetFraction: CGFloat = 0.01
    /// The theme field is rendered at this many samples on its long side, then scaled (smooth gradient).
    public static let portraitThemeResolution = 64

    // §4.6.5 Result card: Site Control panel chrome (`Core.popoverBackground`, radius 12,
    // hairline edge, shadow black 0.25 radius 16 y 6).
    public static let cardWidth: CGFloat = 248
    public static let cardPadding: CGFloat = 12
    public static let cardRadius: CGFloat = 12
    public static let cardShadowAlpha: Float = 0.25
    public static let cardShadowRadius: CGFloat = 16
    public static let cardShadowOffsetY: CGFloat = 6
    public static let cardEdge = DesignColor(light: .black(0.10), dark: .white(0.12))
    public static let thumbnailMaxHeight: CGFloat = 160
    public static let thumbnailRadius: CGFloat = 8
    /// "Saved to Library" (11 pt, `Core.foregroundSecondary`) under the thumbnail.
    public static let savedLineFont = FontToken(11, .regular)
    public static let savedLineHeight: CGFloat = 14
    public static let lineGap: CGFloat = 8
    public static let buttonSize: CGFloat = 28
    public static let buttonRadius: CGFloat = 6
    public static let buttonGap: CGFloat = 6
    public static let buttonSymbolSize: CGFloat = 15
    public static let buttonHover = DesignColor(light: .black(0.06), dark: .white(0.10))
    public static let buttonPressed = DesignColor(light: .black(0.12), dark: .white(0.18))
    /// The card stays this long; the pointer over it pauses the clock.
    public static let cardLifetime: TimeInterval = 8
    public static let cardFade: CFTimeInterval = 0.15
    /// Toast anchor (page-platform §4.1.1, PG-1.1): 10 pt from the panel's right edge, 8 pt from its top.
    public static let anchorTrailing: CGFloat = 10
    public static let anchorTop: CGFloat = 8

    // §4.6.7 Shortcut hint
    public static let shortcutHintInterval: TimeInterval = 14 * 24 * 3600
}
