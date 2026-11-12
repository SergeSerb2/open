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
    /// Arc's overlay pill (capture s4 `t6/07-library-capture/e6-capture-ui`): a click captures the
    /// hovered element, a drag captures an area.
    public static let hintText = "Click or drag to capture a portion of this page"
    /// The hovered element's outline (s4 `e6-capture-ui`: white, rounded). Width and radius GUESS — capture pending.
    public static let elementOutlineWidth: CGFloat = 2
    public static let elementOutlineRadius: CGFloat = 8
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
    /// Portrait canvas: the popover preview's proportions (239 × 127 pt, page card 96 pt tall;
    /// PB2 capture `43-pb2-probe`). A wide page fills at most 86 % of the width.
    public static let portraitAspect: CGFloat = 239.0 / 127.0
    public static let portraitImageHeightFraction: CGFloat = 96.0 / 127.0
    public static let portraitImageFraction: CGFloat = 0.86
    /// Corner radius, shadow blur and shadow y offset as fractions of the canvas width (GUESS).
    public static let portraitShadowAlpha: CGFloat = 0.22
    public static let portraitShadowBlurFraction: CGFloat = 0.03
    public static let portraitShadowOffsetFraction: CGFloat = 0.008
    /// Watermark tile: 32 pt in the 239 pt preview, 3.5 pt from the bottom-left corner.
    public static let portraitWatermarkFraction: CGFloat = 32.0 / 239.0
    public static let portraitWatermarkInsetFraction: CGFloat = 3.5 / 239.0
    /// Tile: white ~15 %, ~8 pt corners on 32 pt (LEAD 13:40).
    public static let portraitWatermarkTileAlpha: CGFloat = 0.15
    public static let portraitWatermarkRadiusFraction: CGFloat = 8.0 / 32.0
    /// Frosted frame around the page card: ~4 pt wide, white ~35 %, ~8 pt outer radius (LEAD 13:40).
    public static let portraitFrameFraction: CGFloat = 4.0 / 239.0
    public static let portraitFrameRadiusFraction: CGFloat = 8.0 / 239.0
    public static let portraitFrameAlpha: CGFloat = 0.35
    // Popover (AX frames of capture `43-pb2-probe/p-1-portrait-ax`, points from its top-left).
    public static let portraitPopoverSize = CGSize(width: 286, height: 246)
    public static let portraitButtonFrame = CGRect(x: 22.6, y: 22.6, width: 240.8, height: 32.8)
    public static let portraitPreviewFrame = CGRect(x: 23.5, y: 63.5, width: 239, height: 127)
    public static let portraitSwatchSize: CGFloat = 17
    public static let portraitLeftSwatchOrigin = CGPoint(x: 26.5, y: 202.5)
    public static let portraitRightSwatchOrigin = CGPoint(x: 242.5, y: 202.5)
    public static let portraitPreviewRadius: CGFloat = 10

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
