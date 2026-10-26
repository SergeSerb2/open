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

    /// Height for `rows` visible rows.
    public static func panelHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return emptyListHeight }
        return listTop + CGFloat(min(rows, maxVisibleRows)) * rowHeight + bottomPadding
    }

    /// Panel frame in a window of `size` (top-left origin).
    public static func panelFrame(windowSize size: CGSize, rows: Int) -> CGRect {
        let w = min(panelWidth, max(320, size.width - 2 * minimumWindowMargin))
        let x = ((size.width - w) / 2).rounded()
        let y = max(minimumWindowMargin, ((size.height - centeringHeight) / 2).rounded())
        return CGRect(x: x, y: y, width: w, height: panelHeight(rows: rows))
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
}

extension Motion {
    /// Command bar open: fade in while scaling up from 0.96. PROVISIONAL: the captures hold
    /// no mid-animation pixels; AX frames during open/close (F0060, F0064) show a collapsed
    /// layout, not a scale. Arc's toasts and theme editor scale up (F0144, A0465), so the
    /// command bar likely does too (guess).
    public static let commandBarOpen = SpringToken(response: 0.22, dampingFraction: 0.9)
    public static let commandBarOpenScale: CGFloat = 0.96
    /// Close: fade out and shrink to 0.98, ease-in. PROVISIONAL guess.
    public static let commandBarClose: CFTimeInterval = 0.12
    public static let commandBarCloseScale: CGFloat = 0.98
}
