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
    public static let buttonSparkleSize: CGFloat = 4 // §3.10, approximate captured size
    public static let buttonSparkleOpacity: CGFloat = 0.45                                 // g (URL field button, Q15)
    public static let shadowOpacity: Float = 0.25, shadowRadius: CGFloat = 12, shadowOffsetY: CGFloat = 4 // g; shared with the theme popover
    // Geometry above is Arc-measured and still holds in Arc 1.172 (session 2 14c: padding 10, tiles 48 × 32 every 56,
    // one setting row → 254 pt). D3 changes only the material and colours (lead 11:45).
    /// D3 §2.5 panel shadow: y 18, blur 50 (σ 25), black 34 %.
    public static let panelShadowOpacity: Float = 0.34, panelShadowRadius: CGFloat = 25, panelShadowOffsetY: CGFloat = 18
    /// The Space tint reaches clear at this fraction of the panel width.
    public static let tintStop: CGFloat = 0.62
}
public enum SiteControlColors {            // macOS Dark measured (IS §20.15); Light = guess; mode = the window's (§3.2)
    // Shipped with .hudWindow: interim (lead 2026-11-06). S11/S12 remain FAIL.
    // The fitted bitmap below remains exclusive to the offscreen harness.
    public static let liveMaterialTint = DesignColor(light: .black(0), dark: RGBA(hex: 0x686881, alpha: 0.32))
    /// D3 body under the Space tint. Light: D3 §2.5. Dark: tuned against the Arc 1.170 dark capture (S11/S12).
    public static let body = DesignColor(light: RGBA(250.0 / 255, 250.0 / 255, 246.0 / 255, 0.94), dark: RGBA(94.0 / 255, 94.0 / 255, 94.0 / 255, 0.82))
    /// Dark tint at the left edge, clear at `darkTintStop`. Fitted with the dark `body` on the four S11 probes of the Arc 1.170
    /// dark capture (P1 / P2 exact, P3 ΔE00 2.33, P4 exact; LEAD 11:45). D2 may derive it from the Space.
    public static let darkTint = RGBA(15.0 / 255, 9.0 / 255, 66.0 / 255, 0.37)
    public static let darkTintStop: CGFloat = 0.75
    /// "Insecure" chip: red tint with red text (D3 §2.5).
    public static let insecureFill = DesignColor(RGBA(220.0 / 255, 60.0 / 255, 40.0 / 255, 0.12))
    public static let insecureText = DesignColor(RGBA(hex: 0xD8432C))
    public static let fallbackTint = RGBA(hex: 0x49475A), fallbackBackdropWeight: [CGFloat] = [0.28, 0.28, 0.21]
    public static let fallbackBlurSigma: CGFloat = 5                                       // fit + validation (§3.2)
    // Light: D3 §2.5 (lead-approved light look). Dark: Arc 1.170 measured values, unchanged.
    public static let rim = DesignColor(light: .black(0.20), dark: .white(0.20))
    public static let actionFillTop = DesignColor(light: .white(1), dark: RGBA(hex: 0x272727))
    public static let actionFillBottom = DesignColor(light: .white(1), dark: RGBA(hex: 0x161616))
    public static let actionRing = DesignColor(light: .black(0.08), dark: .black(0.30))
    public static let actionShadow = DesignColor(light: .black(0.22), dark: .black(0.20))
    public static let actionHighlight = DesignColor(light: .clear, dark: RGBA(hex: 0x575757))
    public static let actionHighlightHover = DesignColor(light: .clear, dark: RGBA(hex: 0x484848))
    public static let glyph = DesignColor(light: RGBA(hex: 0x3A382F), dark: .white(0.85))
    public static let label = DesignColor(light: RGBA(hex: 0x26241C), dark: RGBA(hex: 0xDBDBDF))
    public static let rowTitle = DesignColor(light: RGBA(hex: 0x26241C), dark: RGBA(hex: 0xDFDFE2))
    public static let rowSubtitle = DesignColor(light: RGBA(hex: 0x26241C, alpha: 0.6), dark: RGBA(hex: 0x9F9EA9))   // also hover accessory, chevron, notes
    public static let circleOn = DesignColor(light: RGBA(hex: 0x2B2A3C), dark: RGBA(hex: 0xECEDFF))  // disc; glyph is a knock-out
    public static let circleOff = DesignColor(light: .black(0.10), dark: .white(0.28))     // disc; glyph is a knock-out
    public static let tileFill = DesignColor(light: .black(0.07), dark: .white(0.08))
    /// S2 09/0010 y335: +35 sRGB levels on sidebar and page material.
    /// Dark uses plus-lighter compositing; Light remains an alpha guess.
    public static let separator = DesignColor(light: RGBA(128.0 / 255, 128.0 / 255, 128.0 / 255, 0.25), dark: RGBA(hex: 0x232323))
    public static let pillFill = DesignColor(light: .black(0.04), dark: .white(0.05))
    public static let moreFill = DesignColor(light: RGBA(128.0 / 255, 128.0 / 255, 128.0 / 255, 0.18), dark: .black(0.28))
}
public enum BoostGlyph {                    // one token for the Boost identity (§3.4, §3.7, §4.11, §4.13); Open's own sparkles as layers
    public static let outline = "paintbrush.pointed", fill = "paintbrush.pointed.fill"
}
public enum BoostEditorMetrics {           // §4, editor-window points; AX S2 10/0030 unless noted
    public static let window = CGSize(width: 183, height: 588), codeWindow = CGSize(width: 480, height: 588)
    public static let cornerRadius: CGFloat = 12, topOffset: CGFloat = 160, screenMargin: CGFloat = 8   // m / m (one sample) / o
    public static let headerHeight: CGFloat = 40, inset: CGFloat = 18
    public static let done = CGRect(x: 0, y: 0, width: 40, height: 40), name = CGRect(x: 46, y: 8, width: 91, height: 24)
    public static let undo = CGRect(x: 143, y: 0, width: 40, height: 40)
    public static let ringFrame = CGRect(x: 18, y: 58, width: 147, height: 147), plate = CGRect(x: 25, y: 65, width: 133, height: 133)
    public static let ringRadius: CGFloat = 20, plateRadius: CGFloat = 13.5, padRadius: CGFloat = 66.5  // m / m / g (theme rule)
    public static let dotPitch: CGFloat = 4, dotSize: CGFloat = 1                                     // m
    public static let primaryDisc: CGFloat = 30, primaryDragDisc: CGFloat = 38, knobRing: CGFloat = 2  // m
    public static let knobGradientTop: CGFloat = -14, knobGradientBottom: CGFloat = 12              // m (levels vs the center color)
    public static let secondaryDisc: CGFloat = 19, secondaryOffsetDegrees: CGFloat = 45               // m
    public static let defaultKnobAngle: CGFloat = 0, defaultKnobRadius: CGFloat = 40, guideWidth: CGFloat = 2  // m
    public static let colorButtons = [CGRect(x: 18, y: 220, width: 42, height: 38), CGRect(x: 70, y: 220, width: 43, height: 38),
                                      CGRect(x: 123, y: 220, width: 42, height: 38)]
    public static let buttonRadius: CGFloat = 9                                                         // g (visual)
    public static let fontCard = CGRect(x: 18, y: 273, width: 147, height: 120), fontCardRadius: CGFloat = 11  // m / g (visual)
    public static let fontColumns: [CGFloat] = [23, 51, 79, 106, 134], fontRows: [CGFloat] = [281, 307, 333, 359], fontCell: CGFloat = 26
    public static let size = CGRect(x: 18, y: 408, width: 70, height: 38), textCase = CGRect(x: 96, y: 408, width: 69, height: 38)
    public static let zap = CGRect(x: 18, y: 461, width: 147, height: 38), code = CGRect(x: 18, y: 514, width: 147, height: 38)
    public static let rowLabelInset: CGFloat = 12, rowGlyphTrailingInset: CGFloat = 15                 // m (ink)
    public static let fontBaselineOffsets: [String: CGFloat] = ["Courier": -2,"Hoefler Text": -2,"SignPainter": -2,"Papyrus": -3]
    public static let makeLabelKern: CGFloat = -0.25
    public static let nameChevronGap: CGFloat = 11, nameChevron: CGFloat = 12                          // m (ink)
    public static let advancedWindow = CGRect(x: -34, y: 258, width: 250, height: 232), advancedSlider = CGSize(width: 186, height: 16)
    public static let advancedLabelY: [CGFloat] = [299, 361, 423], advancedSliderY: [CGFloat] = [318, 380, 442]
    public static let codeHeader: CGFloat = 40, codeBottomBar: CGFloat = 70, codeButton: CGFloat = 38
    public static let back = CGRect(x: 10, y: 9, width: 60, height: 23), segment = CGSize(width: 50, height: 24)
    public static let codeHammerOffsetY: CGFloat = 1
    public static let codeHammerGlyph: CGFloat = 14.5 // optical extent calibrated to S2 10/0071
    public static let codeBackGlyphOffset: CGFloat = 3
    public static let codeBackGlyphWidth: CGFloat = 16, codeBackLabelX: CGFloat = 26, codeBackBaseline: CGFloat = 16
    public static let codeSegmentTop: CGFloat = 8, codeControlFont: CGFloat = 13, codeButtonGlyph: CGFloat = 15
    public static let codeSegmentRadius: CGFloat = 6
    public static let codeFont: CGFloat = 12, codeLineHeight: CGFloat = 16, gutterFont: CGFloat = 10
    public static let codeInset = CGSize(width: 8,height: 6), codeResizeStrip: CGFloat = 8
    public static let codeBarInset: CGFloat = 15, codeBarTop: CGFloat = 17, codeBarGap: CGFloat = 10
    // Open choice (lead 2026-11-06): JavaScript notice.
    public static let codeNoticeHeight: CGFloat = 28, codeNoticeHairlinePixels: CGFloat = 1
    public static let codeNoticeFont: CGFloat = 11, codeNoticeFontWeight = NSFont.Weight.regular
    public static let codeNoticeLeading: CGFloat = 12, codeNoticeLines = 1
    public static let codeNoticeLineBreak = NSLineBreakMode.byTruncatingTail
    public static let codeNoticeDismissHit: CGFloat = 20, codeNoticeDismissTrailing: CGFloat = 6
    public static let codeNoticeDismissGlyphSize: CGFloat = 9, codeNoticeDismissWeight = NSFont.Weight.semibold
    public static let codeNoticeDismissGlyph = "xmark", codeNoticeDismissLabel = "Dismiss"
    public static let codeNoticeText = "JavaScript in a Boost runs on this site like the site's own code."
    public static let cssSaveDelay: TimeInterval = 0.150, jsSaveDelay: TimeInterval = 0.500
    public static let codeFadeOut: TimeInterval = 0.08, codeFadeIn: TimeInterval = 0.12
    public static let codeMinimum = CGSize(width: 360, height: 420), gutterWidth: CGFloat = 36   // o
    public static let firstRunCardTop: CGFloat = 271, makeABoost = CGRect(x: 14, y: 493, width: 155, height: 38)
    public static let maybeLater = CGRect(x: 46, y: 541, width: 91, height: 31), firstRunIcon: CGFloat = 70  // m / BO-17 asset size
    public static let titleBaselines: [CGFloat] = [347, 370, 393], waveCrestY: CGFloat = 463          // m
    public static let waveAmplitude: CGFloat = 1.95, wavePeriod: CGFloat = 17, waveFirstCrestX: CGFloat = 7 // m
    public static let badgeBorder: CGFloat = 3, badgeRotationDegreesCCW: CGFloat = 12                  // m (border, direction) / g (angle)
    public static let zapDone = CGSize(width: 59, height: 38), zapDoneRadius: CGFloat = 8, zapDoneTop: CGFloat = 10 // m
    public static let bannerLine: CGFloat = 28, bannerTwoLines: CGFloat = 42                       // o (lead round 2)
}
public enum BoostEditorColors {            // light only; IS §20.15 and §20.6
    public static let header = RGBA(hex: 0xF5F5F7), hairline = RGBA(hex: 0xE9E9EB), background = RGBA(hex: 0xFDFDFF)
    public static let button = RGBA(hex: 0xEBEBED), buttonPressed = RGBA(hex: 0xDFDFE0), buttonOn = RGBA(hex: 0x333333)
    public static let advancedOn = RGBA(hex: 0x474747), label = RGBA(hex: 0x3A3A3B), title = RGBA(hex: 0x252526)
    public static let headerGlyph = RGBA(hex: 0xACACAD), chevron = RGBA(hex: 0x7C7C7D), disabledGlyph = RGBA(hex: 0xBDBDBF)
    public static let fontGlyph = RGBA(hex: 0x999999), fontSelected = RGBA(hex: 0xD9D9D9), fontSelectedGlyph = RGBA(hex: 0x8C8C8C)
    public static let plate = RGBA(hex: 0xFAFAFA), dot = RGBA.black(0.075), guide = RGBA.black(0.06)
    public static let secondaryOutline = RGBA(hex: 0xC8C2CA)
    public static let ringStops: [(degrees: CGFloat, color: UInt32)] = [(0, 0xEB4838), (30, 0xEB7636), (60, 0xF4BA49), (90, 0xD4FD58),
        (120, 0x90FC74), (150, 0x80FCAD), (180, 0x7CF8F1), (210, 0x356FF6), (240, 0x392EF4), (270, 0x8237F5), (300, 0xDD31BF), (330, 0xDF3470), (360, 0xEB4838)]
    public static let noColorKnobs = (primary: RGBA(hex: 0x717171), secondary: RGBA(hex: 0x333333))
    public static let warning = RGBA(hex: 0xFF5A5F)                                   // BO-22; banners
    public static let greyRingStops: [Double] = [113,141,191,233,226,227,227,117,72,92,110,107,113] // measured P3-neutral S2 10/0030–0031
    public static let firstRunDim = RGBA.black(0.30), firstRunTitle = RGBA(hex: 0x3139FF), firstRunBody = RGBA(hex: 0x95939F)
    public static let makeABoost = (top: RGBA(hex: 0x4E4FFF), bottom: RGBA(hex: 0x333AFF)), firstRunFooter = RGBA(hex: 0xCEDBFC) // m (vertical)
    public static let maybeLater = RGBA(hex: 0x7F819E)
    public static let zapFrame = RGBA(hex: 0x3139FF), zapBar = RGBA(hex: 0xFBFBFD), zapDone = RGBA(hex: 0xEDEEFF)
    public static let zapBarTextPopupOpen = RGBA(hex: 0xDBDFFF)                     // m (darkest pixel, popup open)
    // S2 10/0071 code-header neutral fills (private capture, flat interior probes).
    public static let codePlaceholder = RGBA.black(0.3)
    public static let codeToolsGlyph = RGBA(hex: 0x323233) // opaque-core match for Open's SF raster
    public static let codeBackGlyph = RGBA(hex: 0x262626) // S2 10/0071, arrow opaque core
    public static let codeSegmentSelected = RGBA(hex: 0xC8C8C8), codeSegmentIdle = RGBA(hex: 0xE4E4E4)
    public static let codeComment = RGBA(hex: 0x8E8E93), codeString = RGBA(hex: 0xC41A16), codeNumber = RGBA(hex: 0x1C00CF)
    public static let codeKeyword = RGBA(hex: 0x9B2393), codeProperty = RGBA(hex: 0x326D74), codeGutter = RGBA(hex: 0xA0A0A5)
    // Open choice (lead 2026-11-06): JavaScript notice.
    public static let codeNoticeBackground = RGBA(hex: 0xF2F2F4), codeNoticeHairline = RGBA.black(0.08)
    public static let codeNoticeText = RGBA.black(0.60), codeNoticeDismiss = RGBA.black(0.45)
    public static let advancedMaterialOverWhite = RGBA(hex: 0xEDEDED)               // m (S2 10/0042, editor (91, 300)); calibration only
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
    public static let knobRelease = SpringToken(response: 0.2,dampingFraction: 0.9)
    public static let boostEditorOpenDuration: CFTimeInterval = 0.15,boostEditorCloseDuration: CFTimeInterval = 0.12,codeModeResize: CFTimeInterval = 0.20
}
extension Typography {
    public static let siteControlLabel = FontToken(14, .semibold), siteControlRowTitle = FontToken(14, .semibold)
    public static let siteControlRowSubtitle = FontToken(13, .regular), siteControlPill = FontToken(14, .medium)
    public static let siteControlSecondary = FontToken(13, .regular)
    public static let editorFontCell = FontToken(12,.regular) // measured S2 10/0030–0031
    public static let editorName = FontToken(13,.medium),editorButton = FontToken(14,.medium),editorSlider = FontToken(13,.regular)
    public static let firstRunTitle = FontToken(22,.bold),firstRunPrimary = FontToken(14,.medium),firstRunSecondary = FontToken(12,.medium)
}
