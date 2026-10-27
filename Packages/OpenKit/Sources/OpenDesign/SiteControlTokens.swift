import AppKit
import QuartzCore

// Measured Site Control values: plan §3, Appendix A; S2 09/0010.
public enum SiteControlMetrics {           // §3. m = measured (S2), g = guess, o = Open choice
    public static let width: CGFloat = 236, padding: CGFloat = 10                         // m
    public static let cornerRadius: CGFloat = 16                                           // m ≈ 16–18; lead C
    public static let arrowHeight: CGFloat = 10, arrowSideAngle: CGFloat = 45               // m (visible tip → body top; 2 pt/row)
    public static let arrowTipRadius: CGFloat = 7, arrowBaseWidth: CGFloat = 26             // m (fit to rows 81–90)
    public static let arrowBaseFillet: CGFloat = 2, arrowTipBelowAnchor: CGFloat = 2        // g / m
    public static let windowMargin: CGFloat = 8, contentAnchorInset: CGFloat = 12          // o
    public static let actionButton = CGSize(width: 48, height: 32), actionGap: CGFloat = 8 // m
    public static let actionRadius: CGFloat = 6, actionGlyph: CGFloat = 17                 // m (corner insets) / g (visual)
    public static let gapAfterActions: CGFloat = 37, sectionGap: CGFloat = 43              // m
    public static let labelBaselineAboveContent: CGFloat = 14, labelRowHeight: CGFloat = 24 // m / g
    public static let extensionTile = CGSize(width: 48, height: 32), extensionColumns = 4  // m / g
    public static let extensionRowPitch: CGFloat = 40, extensionIcon: CGFloat = 16, tileRadius: CGFloat = 6 // g / g / m
    public static let rowIcon: CGFloat = 32, rowPitch: CGFloat = 43, rowTextX: CGFloat = 50 // m
    public static let rowTitleBaseline: CGFloat = 13, rowSubtitleBaseline: CGFloat = 29   // m (±1)
    public static let rowGlyph: CGFloat = 15, circlePressedLevels: CGFloat = -8             // g (no row hover plate)
    public static let focusOutset: CGFloat = 2, circleFocusDiameter: CGFloat = 36          // o
    public static let gapBeforeSeparator: CGFloat = 15, gapAfterSeparator: CGFloat = 10    // m
    public static let footerHeight: CGFloat = 32, pillRadius: CGFloat = 8, pillPadding: CGFloat = 10 // m / g / g
    public static let pillLockGlyph: CGFloat = 13, pillLockGap: CGFloat = 6                // m (ink 10 × 14)
    public static let moreButton: CGFloat = 32                                             // m
    public static let reloadRowHeight: CGFloat = 32, reloadGap: CGFloat = 11, globalOffHeight: CGFloat = 28 // o
    public static let maxHeight: CGFloat = 640, inUseDot: CGFloat = 6                      // o; height = min(content, maxHeight, window room) (§3.1)
    public static let sparkleOpacity = (topRight: 1.0, topLeft: 0.35, bottomRight: 0.35)   // g (resting frame, Q15)
    public static let buttonSparkleOpacity: CGFloat = 0.45                                 // g (URL field button, Q15)
    public static let shadowOpacity: Float = 0.25, shadowRadius: CGFloat = 12, shadowOffsetY: CGFloat = 4 // g; shared with the theme popover
}
public enum SiteControlColors {            // macOS Dark measured (IS §20.15); Light = guess; mode = the window's (§3.2)
    public static let fallbackTint = RGBA(hex: 0x49475A), fallbackBackdropWeight: [CGFloat] = [0.28, 0.28, 0.21]
    public static let fallbackBlurSigma: CGFloat = 5                                       // fit + validation (§3.2)
    public static let rim = DesignColor(light: .black(0.10), dark: .white(0.20))           // m (dark) / g (light)
    public static let actionFillTop = DesignColor(light: .black(0.04), dark: RGBA(hex: 0x272727))    // m / g
    public static let actionFillBottom = DesignColor(light: .black(0.08), dark: RGBA(hex: 0x161616)) // m / g
    public static let actionRing = DesignColor(light: .black(0.12), dark: .black(0.30))    // m / g
    public static let actionShadow = DesignColor(light: .black(0.10), dark: .black(0.20))  // fit (radius 1, y 1) / g
    public static let actionHighlight = DesignColor(light: .white(0.6), dark: RGBA(hex: 0x575757))
    public static let actionHighlightHover = DesignColor(light: .white(0.4), dark: RGBA(hex: 0x484848))
    public static let glyph = DesignColor(light: .black(0.75), dark: .white(0.85))
    public static let label = DesignColor(light: .black(0.80), dark: RGBA(hex: 0xDBDBDF))
    public static let rowTitle = DesignColor(light: .black(0.85), dark: RGBA(hex: 0xDFDFE2))
    public static let rowSubtitle = DesignColor(light: .black(0.50), dark: RGBA(hex: 0x9F9EA9))   // also hover accessory, chevron, notes
    public static let circleOn = DesignColor(light: RGBA(hex: 0x2B2A3C), dark: RGBA(hex: 0xECEDFF))  // disc; glyph is a knock-out
    public static let circleOff = DesignColor(light: .black(0.10), dark: .white(0.28))     // disc; glyph is a knock-out
    public static let tileFill = DesignColor(light: .black(0.05), dark: .white(0.08))
    /// S2 09/0010 y335: +35 sRGB levels on sidebar and page material.
    /// Dark uses plus-lighter compositing; Light remains an alpha guess.
    public static let separator = DesignColor(light: .black(0.12), dark: RGBA(hex: 0x232323))
    public static let pillFill = DesignColor(light: .black(0.04), dark: .white(0.05))
    public static let moreFill = DesignColor(light: .black(0.10), dark: .black(0.28))
}
public enum BoostGlyph {                    // one token for the Boost identity (§3.4, §3.7, §4.11, §4.13); Open's own sparkles as layers
    public static let outline = "paintbrush.pointed", fill = "paintbrush.pointed.fill"
}
public enum BoostEditorMetrics {          // §4
    public static let width: CGFloat = 268, inset: CGFloat = 14, headerHeight: CGFloat = 52
    public static let wheelArea: CGFloat = 176, ringDiameter: CGFloat = 128, ringWidth: CGFloat = 18, padRadius: CGFloat = 46, puck: CGFloat = 24
    public static let sideButton: CGFloat = 28, sliderRow: CGFloat = 28
    public static let fontChip = CGSize(width: 56, height: 36), toolTile: CGFloat = 54, toolGap: CGFloat = 8
    public static let zapRow: CGFloat = 30, zapVisibleRows = 5
    public static let codeDefault = CGSize(width: 560, height: 640), codeMinimum = CGSize(width: 420, height: 360)
    public static let gutterWidth: CGFloat = 36, codeFontSize: CGFloat = 12, codeLineHeight: CGFloat = 16
    public static let contentInset: CGFloat = 12   // from the web panel's top-right corner
}
public enum BoostEditorColors {           // BO-22 values (facts); usage per §4 (guess)
    public static let segmentBackground = DesignColor(light: .black(0.07), dark: .white(0.10))
    public static let segmentSelection = DesignColor(light: .white(1), dark: .white(0.30))
    public static let sliderTrack = DesignColor(RGBA(hex: 0x3B3746, alpha: 0.05))
    public static let sliderTint = DesignColor(RGBA(hex: 0x017AFF))
    public static let warning = DesignColor(RGBA(hex: 0xFF5A5F))
    public static let puck = DesignColor(RGBA(hex: 0xFAFBFF))
    public static let puckPad = DesignColor(light: .black(0.04), dark: .white(0.06))
    public static let label = DesignColor(light: .white(1), dark: .black(0.80))
    public static let zapPreview = DesignColor(RGBA(hex: 0xD9D9D9))
    public static let interstitialForeground = DesignColor(RGBA(hex: 0x2E2740))
    public static let interstitialFooter = DesignColor(RGBA(hex: 0xCEDBFC))
    public static let accents: [DesignColor] = [0x300EFF, 0x55B948, 0xDD0EFF, 0xFF560E, 0xFF0E82, 0x860EFF, 0xFF0E0E, 0xF1A23C]
        .enumerated().map { DesignColor(RGBA(hex: UInt32($0.element), [1, 7].contains($0.offset) ? .displayP3 : .sRGB)) }
}
public extension SiteControlMetrics {
    static let disabledAlpha: CGFloat = 0.3, focusWidth: CGFloat = 2, moreGlyph: CGFloat = 13
    // SF vector optical boxes are calibrated separately from their point size.
    static let symbolRasterPhase: [String: CGPoint] = ["square.and.arrow.up": CGPoint(x: 0.25,y: 0.5),"paintbrush.pointed": CGPoint(x: 0.75,y: 0.75),"gearshape.fill": CGPoint(x: 0.75,y: 0)]
    static let symbolRasterCompensation: [String: CGSize] = ["square.and.arrow.up": CGSize(width: 1,height: 0),"paintbrush.pointed": CGSize(width: 1,height: 0),"camera": CGSize(width: 1,height: 0),"text.viewfinder": CGSize(width: 1,height: 1),"lock.fill": CGSize(width: 2,height: 0),"ellipsis": CGSize(width: 2,height: 1),"gearshape.fill": CGSize(width: 2,height: 2)]
    static let actionInk = [CGSize(width: 14,height: 17),CGSize(width: 16,height: 16),CGSize(width: 19,height: 15),CGSize(width: 15,height: 18)]
    static let gearInk = CGSize(width: 13,height: 13) // S2 09/0010; 15 pt symbol optical box
    static let rowTitleTrailing: CGFloat = 16 // includes the tail-ellipsis optical inset
    static let pillLockInk = CGSize(width: 10,height: 14), moreInk = CGSize(width: 13,height: 3)
    static let actionRingWidth: CGFloat = 1, actionHighlightHeight: CGFloat = 1
    static let actionShadowRadius: CGFloat = 1, actionShadowOffsetY: CGFloat = 1, actionPressedLevels: CGFloat = -6
    static let separatorHeight: CGFloat = 1
    static let openScale: CGFloat = 0.15, closeScale: CGFloat = 0.9, openSettle: CFTimeInterval = 0.30
    /// Step 1 reserves the measured no-Boosts section stack; Step 2 supplies its views.
    static var reservedSectionHeight: CGFloat { gapAfterActions + extensionTile.height + sectionGap + rowIcon + rowPitch }
    static var chromeHeight: CGFloat { padding*2 + actionButton.height + reservedSectionHeight + gapBeforeSeparator + separatorHeight + gapAfterSeparator + footerHeight }
}
extension Motion {
    public static let popoverOpen = SpringToken(response: 0.20, dampingFraction: 0.8)
    public static let popoverOpenFade: CFTimeInterval = 0.08, popoverClose: CFTimeInterval = 0.19
    public static let heightGrow: CFTimeInterval = 0.20, heightShrink: CFTimeInterval = 0.25
}
extension Typography {
    public static let siteControlLabel = FontToken(14, .semibold), siteControlRowTitle = FontToken(14, .semibold)
    public static let siteControlRowSubtitle = FontToken(13, .regular), siteControlPill = FontToken(14, .medium)
    public static let siteControlSecondary = FontToken(13, .regular)
    public static let editorTitle = FontToken(14, .semibold)
}
