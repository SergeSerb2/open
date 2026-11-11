import CoreGraphics
import QuartzCore

// Command bar tokens. Values are measured on Arc 1.170.0 captures at 1x
// (window 2216×1394, docs/re/interaction-states.md §9, docs/commandbar.md).
// Frame ids (F0063, A0120) name the evidence. Marks: measured, fitted, guess.
// All frames are points from the panel's outer top-left corner (y grows down).

/// Panel, input row, and result rows.
public enum CommandBarMetrics {
    /// S2 19/0003: fixed embedded panel, 79 + 5 × 50 = 329 pt.
    public static let littleOpenWidth: CGFloat = 490
    public static let littleOpenRows = 5
    public static func littleOpenCloseFrame(width: CGFloat) -> CGRect {
        CGRect(x: width - 47, y: 19, width: 26, height: 26)
    }
    /// Outer width, border included (x 725…1490, F0049/F0063).
    public static let panelWidth: CGFloat = 768
    /// Side margin kept when the window is narrower than the panel plus margins. guess.
    public static let minimumWindowMargin: CGFloat = 40
    /// Outer corner radius. Fitted on the corner coverage of F0063 (the edge curve spans ≈ 18 px).
    public static let cornerRadius: CGFloat = 12
    /// Input row height; the separator is the next pixel row (y 592 = panel y + 64, F0063).
    public static let inputRowHeight: CGFloat = 64
    public static let separatorHeight: CGFloat = 1
    /// First row top: panel y + 69 (row y 597, F0063 AX).
    public static let listTop: CGFloat = 69
    /// Rows `[8, y, 750, 50]` (AX `AXRow` frames).
    public static let rowInsetX: CGFloat = 8
    public static let rowHeight: CGFloat = 50
    /// The list shows at most 5 rows; more rows scroll (F0040, F0052 AX: table 502 pt, scroll area 250).
    public static let maxVisibleRows = 5
    /// Last row bottom to the panel's outer bottom edge (F0055 1 row: 129; F0063 4 rows: 279; F0052 5 rows: 329).
    public static let bottomPadding: CGFloat = 10
    /// Panel height without rows: the input row only. guess (no capture without rows).
    public static let emptyListHeight: CGFloat = 64
    /// The panel top sits where a 5-row panel plus 10 pt would be centered: top = (H − 339) / 2 (528 at H 1394). guess beyond that one window height.
    public static let centeringHeight: CGFloat = 339

    /// Height for `rows` visible rows. The privacy footer covers the bottom of the list; panels
    /// with fewer than `footerGrowthRowLimit` rows grow by its height instead (guess).
    public static func panelHeight(rows: Int, footer: Bool = false) -> CGFloat {
        let base = rows > 0 ? listTop + CGFloat(min(rows, maxVisibleRows)) * rowHeight + bottomPadding : emptyListHeight
        return footer && rows < footerGrowthRowLimit ? base + footerHeight : base
    }

    /// Panel frame in a window of `size` (top-left origin).
    public static func panelFrame(windowSize size: CGSize, rows: Int, footer: Bool = false) -> CGRect {
        let w = min(panelWidth, max(320, size.width - 2 * minimumWindowMargin))
        let x = ((size.width - w) / 2).rounded()
        let y = max(minimumWindowMargin, ((size.height - centeringHeight) / 2).rounded())
        return CGRect(x: x, y: y, width: w, height: panelHeight(rows: rows, footer: footer))
    }

    // MARK: Input row

    /// Leading icon frame `[23, 23, 18, 18]` (AX image at 748, 551). Glyph ink 12×12 for the magnifier.
    public static let leadingIconFrame = CGRect(x: 23, y: 23, width: 18, height: 18)
    /// Text field `[53, 20, …, 23]` (AX `commandBarTextField` at 778, 548).
    public static let textFieldX: CGFloat = 53
    public static let textFieldY: CGFloat = 20
    public static let textFieldHeight: CGFloat = 23
    /// Gap between the text field and the trailing item (field ends at 1434, info button at 1444).
    public static let textFieldTrailingGap: CGFloat = 10
    /// Info button `[W − 47, 19, 26, 26]`; it draws a 24 pt circle (F0063 pixels 1445…1468).
    public static let infoButtonSize: CGFloat = 26
    public static let infoButtonTrailing: CGFloat = 21
    public static let infoButtonY: CGFloat = 19
    public static let infoCircleDiameter: CGFloat = 24
    /// Site Search hint group: right edge at W − 22, y 20, keycaps 24 tall (F0061 pixels 1438…1468, 548…571).
    public static let hintTrailing: CGFloat = 22
    public static let hintY: CGFloat = 20
    public static let keycapHeight: CGFloat = 24
    public static let keycapRadius: CGFloat = 5
    /// Keycap side padding around its label ("Tab" ink 22 px in a 31 px cap, F0061).
    public static let keycapPadding: CGFloat = 4
    /// "Search Google" to its first keycap; keycap to "or" (F0040).
    public static let hintLabelGap: CGFloat = 10
    public static let hintKeyGap: CGFloat = 8
    /// Scope chip (CC-41, S2 18/0016: pixel bounds x 535…615, y 393…416 in a panel at [481, 373]):
    /// a capsule at x 54, y 20, 24 tall; text advance + 2 × 10 wide (81 for "Wikipedia"). measured.
    /// The field's AX frame starts 11 pt after the chip (146), but its text ink starts at 149 in both
    /// S2 18/0016 and 0018; with our field insets that takes 13 pt. fitted.
    public static let chipX: CGFloat = 54
    public static let chipHeight: CGFloat = 24
    public static let chipRadius: CGFloat = 12
    public static let chipPaddingX: CGFloat = 10
    public static let chipToText: CGFloat = 13
    /// Outer glow in the chip color: a shadow of the capsule, no offset, blur 16 (Gaussian σ ≈ 8) at alpha
    /// 0.32. fitted on S2 18/0016: left of the chip the red channel falls 56, 51, 49 … 33, 32, 30 over
    /// 13 pt toward the panel's 27 (a blurred edge with σ 8).
    public static let chipGlowBlur: CGFloat = 16
    public static let chipGlowAlpha: CGFloat = 0.32
    /// Hovered chip: an 11 pt `xmark.circle.fill` at the chip's left padding; the text moves right by
    /// 15 and the chip grows by 15. guess (no capture; CC-19 names a close accessory).
    public static let chipCloseSize: CGFloat = 11
    public static let chipCloseGrowth: CGFloat = 15

    // MARK: Privacy footer (CC-42, S2 18/0044: a 5-row panel 329 pt tall; H = panel height, W = panel width)

    /// Black band `[0, H − 61, W, 61]`, clipped by the panel corner (window y 641…701).
    public static let footerHeight: CGFloat = 61
    /// Panels with fewer rows grow by `footerHeight`, so the band never covers the only row. guess.
    public static let footerGrowthRowLimit = 2
    /// `info.circle` 13×13 at `[18, H − 37]` (AX).
    public static let footerIconFrame = CGRect(x: 18, y: 61 - 37, width: 13, height: 13)
    /// Line 1 AX text `[46, H − 48, 365, 16]`; line 2 at `[46, H − 30]` (band-relative y 13 and 31).
    public static let footerTextX: CGFloat = 46
    public static let footerLine1Top: CGFloat = 61 - 48
    public static let footerLine2Top: CGFloat = 61 - 30
    /// Baseline below each AX text top. fitted (ink tops at band y 13 and 31).
    public static let footerTextBaseline: CGFloat = 13
    /// "Search Settings…" `[W − 223.5, H − 49.5, 132, 37]`, "Dismiss" `[W − 82.5, H − 49.5, 72, 37]` (AX).
    public static let footerButtonTop: CGFloat = 61 - 49.5
    public static let footerButtonHeight: CGFloat = 37
    public static let footerSettingsButtonWidth: CGFloat = 132
    public static let footerDismissButtonWidth: CGFloat = 72
    public static let footerDismissTrailing: CGFloat = 10.5
    public static let footerButtonGap: CGFloat = 9
    /// Button corner, continuous. fitted (visual).
    public static let footerButtonRadius: CGFloat = 8
    /// While the footer shows, the (i) button hides and the field takes its place (AX field 656 → 698 pt).
    public static let footerFieldGrowth: CGFloat = 42

    // MARK: Rows (row-relative)

    /// Selection `[2, 2, 746, 46]` (pixels 735…1480 × 599…644, F0063).
    public static let selectionInset: CGFloat = 2
    /// Selection corner: coverage reaches full ≈ 8 px from the corner (F0063). fitted.
    public static let selectionRadius: CGFloat = 8
    /// Icon 16×16 at `[16, 17]` (AX `AXImage`). Plate 24×24 at `[12, 13]` (pixels 745…768 × 610…633).
    public static let iconFrame = CGRect(x: 16, y: 17, width: 16, height: 16)
    public static let iconPlateFrame = CGRect(x: 12, y: 13, width: 24, height: 24)
    public static let iconPlateRadius: CGFloat = 5
    /// Title origin x 44: AX text frame at 776 (row + 43), text drawn 1 pt inside it (ink at 778, F0063).
    /// Baseline 30 pt below the row top (cap ink 767…776 in a row at 747).
    public static let titleX: CGFloat = 44
    public static let textBaseline: CGFloat = 30
    /// The subtitle is its own text "— <subtitle>" placed after the title's whole-point width
    /// (F0040 AX: "google.com" [776, 75], "— google.com" at 853). Gap fitted on ink: 4 pt (F0048 row 3).
    public static let subtitlePrefix = "— "
    public static let subtitleGap: CGFloat = 4
    /// Accessory arrow plate 24×24 at `[711, 13]` in a 750 pt row, so 15 pt from the row's right
    /// end. The label's AX frame ends 7 pt before the plate (1437 vs 1444); its ink, 8 pt (fitted, F0063).
    public static let accessoryPlateTrailing: CGFloat = 15
    public static let accessoryPlateY: CGFloat = 13
    public static let accessoryPlateSize: CGFloat = 24
    public static let accessoryPlateRadius: CGFloat = 5
    public static let accessoryLabelGap: CGFloat = 8
    /// Shortcut keycaps on action rows. guess: hint keycaps at 22 pt, right-aligned like the arrow plate.
    public static let rowKeycapHeight: CGFloat = 22
    public static let rowKeycapGap: CGFloat = 4
    /// Title and subtitle stop this far before the accessory. guess.
    public static let accessoryTextGap: CGFloat = 16
    /// A row title keeps at most this width, truncated at the tail. measured: S2 18/0044 (one frame), row 2's
    /// 93-character title ends at 468 pt of ink (a 475 pt box: tail truncation ends on a glyph) while its "Switch to
    /// Tab" accessory is ≈ 350 pt further right.
    public static let titleMaxWidth: CGFloat = 475
    /// Subtitle URLs keep at most this width, truncated in the middle (F0048: "resources.arc.net/…stinct-browsing-areas"). fitted.
    public static let subtitleMaxWidth: CGFloat = 278

    // MARK: Split View row (A0120 row 3; re/commandbar-completion.md CC-13, CC-14)

    /// Plate 30×30 at row `[12, 10]` for two side-by-side panes (pixels: columns 12–41, rows 10–39). measured.
    public static let splitPlateOrigin = CGPoint(x: 12, y: 10)
    public static let splitPlateHeight: CGFloat = 30
    /// Each pane cell is 15 pt wide; 3–4 side-by-side panes widen the plate to 15 × n. guess (no capture).
    public static let splitCellWidth: CGFloat = 15
    /// Corner radius ≈ 7, continuous. fitted from the corner coverage.
    public static let splitPlateRadius: CGFloat = 7
    /// A 1 pt gap at each cell boundary shows the row background (columns 26–27 at half coverage). measured.
    public static let splitCellGap: CGFloat = 1
    /// Pane favicon ≈ 9 pt, centered in its cell (left favicon ink `[15, 21, 9, 9]`). measured.
    public static let splitPaneIconSize: CGFloat = 9
    /// The title starts 8 pt after the plate (x 50 for two panes; title ink at 50.5). measured.
    public static let splitTitleGap: CGFloat = 8
    /// The rule between pane titles: 1 pt wide, row y 20.5–32.5. measured. It starts 4.5 pt after the
    /// first title's advance and the next title starts 5 pt after it (A0120: rule over columns 870–871 at
    /// half coverage each, so from x 870.5; next title ink at 877). fitted on one sample.
    public static let splitRuleWidth: CGFloat = 1
    public static let splitRuleTop: CGFloat = 20.5
    public static let splitRuleHeight: CGFloat = 12
    public static let splitRuleGapBefore: CGFloat = 4.5
    public static let splitRuleGapAfter: CGFloat = 5
}

/// Shadow under the panel. Fitted on the darkening around the panel in F0063 against
/// F0064 (no panel): one Gaussian, σ 48 px, 24 pt down, black 0.51 (RMS 0.007 in luminance ratio).
public enum CommandBarShadow {
    public static let opacity: Float = 0.51
    /// Core Animation's `shadowRadius` is the Gaussian σ in points (checked in the comparison loop).
    public static let radius: CGFloat = 48
    public static let offsetY: CGFloat = 24
}

/// Panel material. The panel is translucent: a dark tint over a blurred, saturated
/// copy of what lies behind it. Fitted on four backdrops (dark page F0063, empty-state
/// purple A0327, olive A0526, white page A0120): `fill = tint · a + saturate(backdrop, s) · (1 − a)`
/// in sRGB, RMS 0.37 levels.
public enum CommandBarMaterial {
    public static let tint = RGBA(23.0 / 255, 22.6 / 255, 22.1 / 255)
    public static let tintAlpha: Double = 0.885
    public static let saturation: Double = 1.95
    /// Backdrop blur radius. guess: the photo capture (F0040) shows only soft color blobs.
    public static let blurRadius: CGFloat = 30

    /// Fill over a uniform backdrop color (sRGB 0…1).
    public static func fill(over backdrop: RGBA) -> RGBA {
        let y = 0.2126 * backdrop.red + 0.7152 * backdrop.green + 0.0722 * backdrop.blue
        func ch(_ t: Double, _ b: Double) -> Double {
            let s = min(1, max(0, y + saturation * (b - y)))
            return t * tintAlpha + s * (1 - tintAlpha)
        }
        return RGBA(ch(tint.red, backdrop.red), ch(tint.green, backdrop.green), ch(tint.blue, backdrop.blue))
    }

    /// The panel edge has two looks. Over a dark page: 1 px black (a ≈ 0.93) and a 1 px
    /// light inner ring (white ≈ 0.21) (F0043–F0063). Over light pages, photos, and empty
    /// Space backgrounds: one opaque gray line, no inner ring (A0120, A0121, A0327, A0526).
    /// The switch point lies between backdrop luma 36 (dark style) and 58 (light style). guess: 47.
    public static let darkBackdropLumaThreshold: Double = 47.0 / 255
}

/// Colors the command bar paints. The panel is dark in every capture (macOS Dark);
/// a light variant was not captured.
public enum CommandBarRole {
    /// Border styles (see `CommandBarMaterial.darkBackdropLumaThreshold`).
    public static let outerEdgeOverDark = RGBA.black(0.93)
    public static let innerEdgeOverDark = RGBA.white(0.23)
    public static let edgeOverLight = RGBA(hex: 0x3E3E3E)
    /// Separator under the input: `CommandBarHairlineDividerColor` white 0.10 (#2F2F30 on #181819).
    public static let separator = CommandBarColors.hairlineDivider.dark
    /// Typed text. fitted on F0052/F0061 core pixels (#E0E2E6) and F0048 (inside the selection).
    public static let inputText = RGBA(hex: 0xE5E7EA)
    /// Typed text inside the selection: core #ECECEF on #807571 (F0048). fitted.
    public static let inputTextSelected = RGBA(hex: 0xF2F2F5)
    /// Placeholder "Search or Enter URL…": fitted on F0063 (core ≈ #949494).
    public static let placeholder = RGBA.white(0.55)
    /// Leading icon in the input (magnifier, globe). fitted (core ≈ #F0F0F0).
    public static let inputIcon = RGBA.white(0.95)
    /// Row title: white ≈ 0.80 `CommandBarTextPrimaryColor` (#CCCCCC core, F0063). White on the selected row.
    public static let rowTitle = CommandBarColors.textPrimary.dark
    public static let rowTitleSelected = RGBA.white(1)
    /// Subtitle, "Switch to Tab", Space name, hint label: `CommandBarTextSecondaryColor` white 0.33 (#646465).
    public static let secondaryText = CommandBarColors.textSecondary.dark
    public static let secondaryTextSelected = RGBA.white(1)
    /// "— subtitle" on the selected row: core #9EB1CE over the blue selection #3B679F (S2 18/0009 row 1)
    /// solves to white ≈ 0.5 at the text core. fitted (one sample; was a 0.7 guess).
    public static let subtitleSelected = RGBA.white(0.52)
    /// Row glyphs (magnifier, globe): core #AEAEAF (F0052), #B3B3B3 (F0048 globe). fitted.
    public static let rowGlyph = RGBA.white(0.72)
    public static let rowGlyphSelected = RGBA.white(1)
    /// Plates: arrow plate, keycaps, action icon plate: `CommandBarAccessoryBackgroundColor` white 0.05.
    public static let plate = CommandBarColors.accessoryBackground.dark
    /// Scope chip fill, its glow, and the selected row inside a scope: Display P3 `#FFA500` (S2 18/0016
    /// and 0018 read P3 #FFA501 through the capture's display profile; sRGB clips it to #FFA000, CC-41).
    /// guess: one color for every site and scope.
    public static let scopeChip = RGBA(hex: 0xFFA500, .displayP3)
    /// The rule between a Split View row's pane titles: value 67 over a 49 panel (A0120). fitted.
    public static let splitTitleRule = RGBA.white(0.17)
    /// Arrow on an unselected row: `CommandBarAccessoryForegroundColor` white 0.66.
    public static let plateGlyph = CommandBarColors.accessoryForeground.dark
    /// Selected row: white plate; the arrow takes the selection color (F0063).
    public static let plateSelected = RGBA.white(1)
    /// Keycap label ("Tab", "Space"): core #B2B2B3 on the plate (F0061) → white 0.66. fitted.
    public static let keycapText = CommandBarColors.accessoryForeground.dark
    /// Caret: the system accent (#007AFF core, F0063). Selection: the theme's `dark.subtitle` (#807571, F0048).
    public static let caretWidth: CGFloat = 1
    /// Info button glyph: white 0.55 over the circle (core #988F8B on #190700, F0063).
    public static let infoGlyph = RGBA.white(0.57)
    /// Spaces without a theme (A0327, A0359): selection composite #4349D8 over the panel. With the
    /// themes' focus alpha (0.8075) the blue channel leaves sRGB, so the token is extended sRGB. fitted.
    public static let defaultFocus = RGBA(76 / 255, 84 / 255, 260 / 255, 0.8075, .extendedSRGB)
    /// Info circle without a theme: #050627 (A0327).
    public static let defaultInfoFill = RGBA(hex: 0x050627)
    /// Input selection without a theme. guess.
    public static let defaultTextSelection = RGBA(hex: 0x4A4B6E)

    // Privacy footer (S2 18/0044 raw pixels after the display profile; `interaction-states.md` §20.9).
    /// Band: `#000000` across the band.
    public static let footerBand = RGBA(hex: 0x000000)
    /// `info.circle` in the band (ink 13×13, core #767676). fitted.
    public static let footerIcon = RGBA.white(0.5)
    /// Line 1, 13 Bold (fitted: ink width 364 px and ink mass match 13 Bold, not Semibold).
    public static let footerTitle = RGBA.white(0.93)
    /// Line 2 and its underlined "here", 13 Regular (core #7A7A7A). fitted.
    public static let footerBody = RGBA.white(0.5)
    /// "Search Settings…" and "Dismiss": fill and 1 pt edge, title white 13 Regular (fitted on ink widths
    /// 104 and 45 px). The buttons sit on half points, so the edge covers two pixels at half strength
    /// each: `#494988` read from one pixel is a mix; the pair solves to `#6362AD`. measured.
    public static let footerButtonFill = RGBA(hex: 0x302F63)
    public static let footerButtonEdge = RGBA(hex: 0x6362AD)
    /// Button titles: cores #E5E5EB over the fill solve to white ≈ 0.9. fitted.
    public static let footerButtonTitle = RGBA.white(0.9)
}

// MARK: - D3 command card (plan D3 §2.1, §2.2; the mock-up CSS is the spec; Arc 1.172 capture session 2)

/// Geometry of one command card size: the New Tab card (`.newTab`) or the inline address
/// editor anchored to the sidebar URL field (`.inline`). Panel-relative points, y down.
public struct CommandCardLayout: Sendable, Hashable {
    public var inputRowHeight: CGFloat
    /// Leading icon: x, size; the text starts `iconGap` after it.
    public var inputPaddingLeft: CGFloat
    public var inputPaddingRight: CGFloat
    public var inputIconSize: CGFloat
    public var inputGap: CGFloat
    public var inputFontSize: CGFloat
    /// List: padding top, sides, bottom; rows `rowHeight` tall every `rowPitch`.
    public var listPaddingTop: CGFloat
    public var listPaddingX: CGFloat
    public var listPaddingBottom: CGFloat
    public var rowHeight: CGFloat
    public var rowPitch: CGFloat
    public var rowPaddingLeft: CGFloat
    public var rowPaddingRight: CGFloat
    public var rowGap: CGFloat
    public var rowFontSize: CGFloat
    /// The selected row's white tile: 24 pt, starting `tileOffset` before the icon.
    public var tileOffset: CGFloat

    public var listTop: CGFloat { inputRowHeight + listPaddingTop }
    public var iconSize: CGFloat { 18 }
    /// Title x inside a row.
    public var titleX: CGFloat { rowPaddingLeft + iconSize + rowGap }
    public var textX: CGFloat { inputPaddingLeft + inputIconSize + inputGap }

    /// Panel height for `rows` visible rows (at most five). measured: 329 at five rows (Arc08).
    public func panelHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return inputRowHeight }
        return listTop + CGFloat(min(rows, CommandBarMetrics.maxVisibleRows)) * rowPitch + listPaddingBottom
    }

    /// `.big` in the mock-up: input 64 (22 / 18 padding, gap 16, 19 pt), rows 46 + 4 (13 / 9, gap 13, 15 pt).
    public static let newTab = CommandCardLayout(inputRowHeight: 64, inputPaddingLeft: 22, inputPaddingRight: 18, inputIconSize: 18, inputGap: 16,
                                                 inputFontSize: 19, listPaddingTop: 5, listPaddingX: 9, listPaddingBottom: 10, rowHeight: 46, rowPitch: 50,
                                                 rowPaddingLeft: 13, rowPaddingRight: 9, rowGap: 13, rowFontSize: 15, tileOffset: 4)
    /// `.inl` in the mock-up: input 50 (14 / 20 padding, gap 12, 15 pt, favicon 16), rows as New Tab with 9 / 9 padding, gap 11.
    public static let inline = CommandCardLayout(inputRowHeight: 50, inputPaddingLeft: 14, inputPaddingRight: 20, inputIconSize: 16, inputGap: 12,
                                                 inputFontSize: 15, listPaddingTop: 5, listPaddingX: 9, listPaddingBottom: 9, rowHeight: 46, rowPitch: 50,
                                                 rowPaddingLeft: 9, rowPaddingRight: 9, rowGap: 11, rowFontSize: 15, tileOffset: 3)
}

/// Card look (plan D3 §2.1). Light/Dark follow the window's effective appearance.
public enum CommandCard {
    /// Card at a 1280 pt window: 768 wide at x 256 (Arc08 PNG boundary).
    public static let width: CGFloat = 768
    public static let cornerRadius: CGFloat = 12
    /// Inline editor: anchored to the sidebar URL field, 1 pt above it; never narrower than this.
    public static let inlineMinimumWidth: CGFloat = 340
    public static let inlineTopOffset: CGFloat = -1
    public static let body = DesignColor(light: RGBA(hex: 0xF9F9F9), dark: RGBA(hex: 0x30302E))
    public static let text = DesignColor(light: RGBA(hex: 0x1E1E1C), dark: RGBA(hex: 0xF4F3EE))
    public static let secondaryText = DesignColor(light: RGBA(hex: 0x1E1E1C, alpha: 0.56), dark: RGBA(hex: 0xF4F3EE, alpha: 0.56))
    public static let separator = DesignColor(light: .black(0.08), dark: .white(0.09))
    /// The tint reaches clear at this fraction of the card width.
    public static let tintStop: CGFloat = 0.30
    /// Shadow y 22, blur 70 (Gaussian σ 35), black 38 %, plus a 0.5 pt black 22 % hairline.
    public static let shadowOffsetY: CGFloat = 22, shadowRadius: CGFloat = 35, shadowOpacity: Float = 0.38
    public static let hairline = RGBA.black(0.22), hairlineWidth: CGFloat = 0.5
    /// Scrim over the window content behind the New Tab card (not the inline editor).
    public static let scrim = RGBA.black(0.10)
    /// Round (i) button: 24 pt, Light white / Dark #1C1C1B, shadow y 1 blur 3 black 18 %.
    public static let infoDiameter: CGFloat = 24
    public static let infoFill = DesignColor(light: .white(1), dark: RGBA(hex: 0x1C1C1B))
    public static let infoShadowOpacity: Float = 0.18, infoShadowRadius: CGFloat = 1.5, infoShadowOffsetY: CGFloat = 1
    /// Rows.
    public static let rowRadius: CGFloat = 8
    public static let faviconRadius: CGFloat = 5
    public static let tileSize: CGFloat = 24, tileRadius: CGFloat = 6, tileFavicon: CGFloat = 16
    public static let selectedText = RGBA.white(1), selectedSubtitle = RGBA.white(0.8)
    /// Trailing hint on the selected row: 13 pt semibold white, 8 pt gap, 20 pt key cap radius 5.
    public static let hintFontSize: CGFloat = 13, hintGap: CGFloat = 8, keyCapSize: CGFloat = 20, keyCapRadius: CGFloat = 5
    /// Input text selection: the accent at 55 %.
    public static let textSelectionAlpha = 0.55
}
