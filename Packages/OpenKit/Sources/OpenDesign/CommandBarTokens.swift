import CoreGraphics
import QuartzCore

// Command bar tokens. Values are measured on Arc 1.170.0 captures at 1x
// (window 2216×1394, docs/re/interaction-states.md §9, docs/commandbar.md).
// Frame ids (F0063, A0120) name the evidence. Marks: measured, fitted, guess.
// All frames are points from the panel's outer top-left corner (y grows down).

/// Panel, input row, and result rows.
public enum CommandBarMetrics {
    /// Outer width, border included (x 725…1490, F0049/F0063).
    public static let panelWidth: CGFloat = 766
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
    /// Site Search chip in the input row. guess: no capture of the scoped state.
    public static let chipHeight: CGFloat = 24
    public static let chipRadius: CGFloat = 6
    public static let chipPaddingX: CGFloat = 8
    public static let chipIconSize: CGFloat = 14
    public static let chipToText: CGFloat = 8

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
    /// Subtitle URLs keep at most this width, truncated in the middle (F0048: "resources.arc.net/…stinct-browsing-areas"). fitted.
    public static let subtitleMaxWidth: CGFloat = 278
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
