import CoreGraphics

// Layout metrics in points. Frames are `[x, y, w, h]` from the window's top-left
// corner (y grows down), measured on Arc 1.170.0 at sidebar width 228
// (docs/re/runtime-observations.md §1, docs/re/interaction-states.md).
// Values marked `guess` were not measured.

/// Window chrome above the Space list.
public enum ChromeMetrics {
    /// Traffic lights: 16 pt button frames at x 12 / 35 / 58, y 16 (Arc AX, F0001 and F0131:
    /// close `[348, 54, 16, 16]` with the window at `[336, 38]`). The system draws 12 pt
    /// circles centered in them, so the centers are x 20 / 43 / 66, y 24 (F0001 pixels).
    public static let trafficLightFrames: [CGRect] = [
        CGRect(x: 12, y: 16, width: 16, height: 16),
        CGRect(x: 35, y: 16, width: 16, height: 16),
        CGRect(x: 58, y: 16, width: 16, height: 16),
    ]
    public static var trafficLightCenters: [CGPoint] { trafficLightFrames.map { CGPoint(x: $0.midX, y: $0.midY) } }
    public static let trafficLightDiameter: CGFloat = 12
    /// Toolbar buttons are 32×32 at y 7.
    public static let toolbarButtonSize = CGSize(width: 32, height: 32)
    public static let toolbarButtonY: CGFloat = 7
    /// Sidebar toggle x. The other three buttons hang off the sidebar's right edge.
    public static let sidebarToggleX: CGFloat = 77
    /// Back, forward, reload: pitch 34, reload's right edge 6 pt inside the sidebar
    /// (x 122 / 156 / 190 at width 228).
    public static let navButtonPitch: CGFloat = 34
    public static let reloadTrailingInset: CGFloat = 6
    /// Hover plate: the full 32 pt button frame, radius ≈ 6 (F0024).
    public static let buttonPlateRadius: CGFloat = 6
    /// Glyph ink sizes measured at 1x: toggle 19×15, back/forward 15×12, reload 14×17.
    public static let sidebarToggleGlyph = CGSize(width: 19, height: 15)
    public static let arrowGlyph = CGSize(width: 15, height: 12)
    public static let reloadGlyph = CGSize(width: 14, height: 17)

    public static func backX(sidebarWidth w: CGFloat) -> CGFloat { w - reloadTrailingInset - 32 - 2 * navButtonPitch }
    public static func forwardX(sidebarWidth w: CGFloat) -> CGFloat { w - reloadTrailingInset - 32 - navButtonPitch }
    public static func reloadX(sidebarWidth w: CGFloat) -> CGFloat { w - reloadTrailingInset - 32 }
}

/// Command / URL field.
public enum URLFieldMetrics {
    /// `[8, 46, W − 16, 36]`.
    public static let y: CGFloat = 46
    public static let height: CGFloat = 36
    public static let insetX: CGFloat = 8
    /// Same shape as favorite tiles. Fitted by the comparison loop (docs/design.md).
    public static let cornerRadius: CGFloat = 10
    /// Magnifier button `[14, 52, 24, 24]`, glyph ink 12×12.
    public static let magnifierFrame = CGRect(x: 14, y: 52, width: 24, height: 24)
    /// Placeholder `[41, 55, …, 18]`; host text (page loaded) `[20, 55, …, 18]`.
    public static let placeholderX: CGFloat = 41
    public static let hostX: CGFloat = 20
    public static let textY: CGFloat = 55
    public static let textTrailingInset: CGFloat = 12
    /// Text baseline sits 14 pt below the text frame top.
    public static let textBaselineOffset: CGFloat = 14
    /// Copy URL `[W − 70, 49, 30, 30]` and Site Control Center `[W − 42, 49, 30, 30]`.
    public static let accessorySize: CGFloat = 30
    public static let accessoryY: CGFloat = 49
    public static let siteControlsTrailing: CGFloat = 12
    public static let accessoryPitch: CGFloat = 28
}

/// Favorites grid ("Top Apps").
public enum FavoritesMetrics {
    public static let sectionTop: CGFloat = 82
    public static let inset: CGFloat = 8
    public static let tileHeight: CGFloat = 47
    public static let columnGap: CGFloat = 8
    public static let rowGap: CGFloat = 8
    public static let cornerRadius: CGFloat = URLFieldMetrics.cornerRadius
    public static let iconFrameSize: CGFloat = 18
    public static let iconInkSize: CGFloat = 16
    /// guess: below this tile width the grid drops to 3 columns.
    public static let minTileWidthForFour: CGFloat = 44

    /// Columns for `count` favorites. Measured: 6 favorites → 3 columns at width
    /// 228 and at width 500. guess: rows are balanced with at most 4 per row.
    public static func columns(count: Int, sidebarWidth: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let maxColumns = tileWidth(sidebarWidth: sidebarWidth, columns: 4) >= minTileWidthForFour ? 4 : 3
        let rows = (count + maxColumns - 1) / maxColumns
        return (count + rows - 1) / rows
    }

    /// Tile width: (W − 2·inset − (columns − 1)·gap) / columns.
    public static func tileWidth(sidebarWidth: CGFloat, columns: Int) -> CGFloat {
        (sidebarWidth - 2 * inset - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
    }

    /// Section height: the grid plus 8 pt above and below. Without favorites, 8 pt: the
    /// Space header then keeps the 8 pt gap Arc keeps between the URL field, the tiles, and
    /// the header's hover fill (F0001, A0413). Fitted: Arc shows a favorites empty-state card
    /// here (`sidebarFavoritesEmptyStateDismissButton`, not captured); its window-only sidebar
    /// (A0361, a different header with no Favorites section) starts its list 1–3 pt lower.
    public static func sectionHeight(count: Int, sidebarWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return inset }
        let cols = columns(count: count, sidebarWidth: sidebarWidth)
        let rows = (count + cols - 1) / cols
        return 2 * inset + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * rowGap
    }
}

/// Space header and the tab list. Row offsets are relative to the row top.
public enum SpaceListMetrics {
    /// Sidebar completion §2.7: guessed geometry until a capture is available.
    public static let unreadDotSize: CGFloat = 6
    public static let unreadDotTrailingCenter: CGFloat = 26
    public static let unreadDotCenterY: CGFloat = 20
    public static func resetGlyphPlate(indent: CGFloat) -> CGRect { CGRect(x: 16 + indent, y: 10, width: 20, height: 20) }
    /// Header band 36 pt: icon `[13, 5, 26, 26]`, title `[41, 9, W − 58, 18]`.
    public static let headerHeight: CGFloat = 36
    public static let headerIconFrame = CGRect(x: 13, y: 5, width: 26, height: 26)
    public static let headerTitleX: CGFloat = 41
    public static let headerTitleY: CGFloat = 9
    public static let headerTitleBaselineOffset: CGFloat = 14
    /// Header hover fill `[8, 0, W − 16, 36]` (A0413).
    public static let headerFillInsetX: CGFloat = 8
    /// "…" button, shown on hover at the header's right end. guess size.
    public static let headerMoreSize: CGFloat = 26
    public static let headerMoreTrailing: CGFloat = 11
    /// First outline row is an empty 3 pt spacer.
    public static let spacerRowHeight: CGFloat = 3
    public static let rowHeight: CGFloat = 41
    /// Hover/selected fill `[8, y + 2, W − 16, 36]`.
    public static let rowFillInsetX: CGFloat = 8
    public static let rowFillInsetTop: CGFloat = 2
    public static let rowFillHeight: CGFloat = 36
    /// Fitted by the comparison loop (docs/design.md).
    public static let rowFillCornerRadius: CGFloat = 10
    public static let faviconX: CGFloat = 17
    public static let faviconY: CGFloat = 11
    public static let faviconSize: CGFloat = 18
    public static let faviconInk: CGFloat = 16
    public static let titleX: CGFloat = 43
    /// Title right edge at x 211 → 17 pt from the sidebar edge.
    public static let titleTrailingInset: CGFloat = 17
    /// Title baseline 25 pt below the row top (ink bottom of row 1 at y 263, row top 239, F0001).
    public static let titleBaselineOffset: CGFloat = 25
    /// Text origin inside the AX title frame, fitted on ink boxes (F0001):
    /// row titles and "New Tab" 1 pt, the Space title 3 pt, the URL placeholder 1 pt.
    public static let textInset: CGFloat = 1
    /// Row titles keep 1 pt free at the right when they truncate (2 pt in all with the inset):
    /// AX title width 128 drops "Import Logins & B…" (126.2 pt, F0090), 152 keeps
    /// "Import Logins & Book…" (149.9, F0081), 168 keeps "…apple.…" (164.4, F0001).
    public static let textTrailingInset: CGFloat = 1
    public static let headerTextInset: CGFloat = 3
    /// Close (×) or unload (−) button `[W − 39, y + 7, 26, 26]`; the title then ends at its left edge.
    public static let accessorySize: CGFloat = 26
    public static let accessoryY: CGFloat = 7
    public static let accessoryTrailingInset: CGFloat = 13
    /// Folder child indent per level (F0079: child icon x 33, title x 59).
    public static let indentPerLevel: CGFloat = 16
    /// Split row cell pitch at width 228 (icons x 33 / 129 in a depth-1 row). guess for other widths: equal halves.
    public static let splitDividerWidth: CGFloat = 1
    /// Selected split row (F0081): the selected fill is a card, and each pane gets
    /// its own cell inside it, 4 pt inside the card and 4 pt apart:
    /// `[12, y + 6, 100, 28]` and `[116, y + 6, 100, 28]` at depth 0, width 228.
    /// Corner ≈ 8 (row-by-row edge profile). The divider hides while the cells show.
    public static let splitCellInset: CGFloat = 4
    public static let splitCellGap: CGFloat = 4
    public static let splitCellTop: CGFloat = 6
    public static let splitCellHeight: CGFloat = 28
    public static let splitCellCornerRadius: CGFloat = 8
    /// Peek badge on the source row (F0090, F0101): a 24 pt plate `[W − 38, y + 8, 24, 24]`,
    /// corner ≈ 6, with the Peek page's favicon (AX `[W − 35, y + 11, 18, 18]`, 16 pt ink).
    /// The title then ends at `W − 39`, as with the close button.
    public static let peekBadgeTrailingInset: CGFloat = 38
    public static let peekBadgeY: CGFloat = 8
    public static let peekBadgeSize: CGFloat = 24
    public static let peekBadgeCornerRadius: CGFloat = 6
    /// "/" before a pinned tab's title once it left its pinned URL (F0090, F0101 at depth 1):
    /// a 2 pt stroke ≈ 14.5 pt tall, ≈ 8° from vertical (top x 57, bottom x 55), centered
    /// 3 pt left of the title origin at y + 19.5. The title moves 2 pt (AX x 61 vs 59).
    public static let pinnedSlashSize = CGSize(width: 2, height: 14.5)
    public static let pinnedSlashAngle: CGFloat = 0.14
    public static let pinnedSlashCenterX: CGFloat = -3
    public static let pinnedSlashCenterY: CGFloat = 19.5
    public static let pinnedSlashTitleShift: CGFloat = 2
    /// Pinned/Today divider row: 17 pt, 1 pt line at y + 7 from x 18 to W − 18.
    public static let dividerRowHeight: CGFloat = 17
    public static let dividerLineY: CGFloat = 7
    public static let dividerLineInset: CGFloat = 18
    /// "Clear": arrow `[W − 58, y + 3, 12, 9]`, label `[W − 46, y, 29, 15]`; the line then ends at W − 66.
    public static let clearArrowFrame = CGRect(x: -58, y: 3, width: 12, height: 9)
    public static let clearLabelX: CGFloat = -46
    public static let clearLabelBaseline: CGFloat = 11
    public static let clearLineEnd: CGFloat = -66
    /// "New Tab" plus glyph ink 11×11 at x 20…30.
    public static let newTabGlyphInk: CGFloat = 11
}

/// Bottom bar: Home, Space switcher, plus.
public enum BottomBarMetrics {
    public static let height: CGFloat = 50
    /// Buttons are 32×32, 9 pt above the window bottom → y 9 in the 50 pt bar.
    public static let buttonSize = CGSize(width: 32, height: 32)
    public static let buttonY: CGFloat = 9
    public static let homeX: CGFloat = 8
    /// Plus button right edge is 8 pt from the sidebar edge.
    public static let plusTrailingInset: CGFloat = 8
    /// Switcher strip `[42, 0, W − 84, 50]`. Items 36×34 at pitch 34 (frames overlap by 2), y 8.
    public static let switcherLeading: CGFloat = 42
    public static let switcherTrailing: CGFloat = 42
    public static let switcherItemSize = CGSize(width: 36, height: 34)
    public static let switcherPitch: CGFloat = 34
    public static let switcherItemY: CGFloat = 8
    /// Hover plate: the item frame inset by 1 pt, `[x + 1, 9, 34, 32]`.
    public static let switcherPlateInset = CGSize(width: 1, height: 1)
    public static let switcherEmojiSize: CGFloat = 14
    public static let plateRadius: CGFloat = 6
}

/// Web content panel next to the sidebar.
public enum PanelMetrics {
    /// Panel frame: `[sidebarWidth, 10, W − sidebarWidth − 10, H − 20]`; hidden sidebar: `[10, 10, W − 20, H − 20]`.
    public static let inset: CGFloat = 10
    public static let cornerRadius: CGFloat = 6
    /// CSS `0 1px 6px rgba(0,0,0,.25)` → CALayer radius 3, offset 1 down.
    public static let shadowOpacity: Float = 0.25
    public static let shadowRadius: CGFloat = 3
    public static let shadowOffsetY: CGFloat = 1
    /// Empty panel (no page): white ≈ 10 % over the gradient.
    public static let emptyFillWhiteAlpha: Double = 0.10

    public static func frame(windowSize: CGSize, sidebarWidth: CGFloat, sidebarHidden: Bool = false) -> CGRect {
        let x = sidebarHidden ? inset : sidebarWidth
        return CGRect(x: x, y: inset, width: windowSize.width - x - inset, height: windowSize.height - 2 * inset)
    }
}

/// Window-level values.
public enum WindowMetrics {
    public static let defaultSidebarWidth: CGFloat = 228
    /// guess: 500 is the widest stop (the user dragged to it, F0127).
    public static let maxSidebarWidth: CGFloat = 500
    /// guess: Arc's minimum was not captured; below it a drag hides the sidebar.
    public static let minSidebarWidth: CGFloat = 180
    /// System window corner: continuous, about 16 pt.
    public static let cornerRadius: CGFloat = 16
    /// Hover-reveal card when the sidebar is hidden: `[5, 5, S, H − 10]` (F0129, F0130). The
    /// traffic lights move with it (AX close `[17, 21, 16, 16]`).
    public static let revealCardInset: CGFloat = 5
    /// Corner: circular, radius 12. The card edge per pixel row at all four corners of F0129
    /// fits a circle of radius 11.75 (RMS 0.08 px) better than a continuous corner (11.5,
    /// RMS 0.22 px); the earlier "≈ 10" was a visual estimate.
    public static let revealCardRadius: CGFloat = 12
    /// Card stroke: the outermost 1 px inside the card, `SidebarBorderColor` (white 0.30; F0129
    /// stroke `#696875` over the card fill `#272739`).
    public static let revealCardStrokeWidth: CGFloat = 1
    /// Card shadow: black, no offset, the same on all four sides. F0129 against F0128 (the same
    /// view without the card): 7.5 % darker at 0.5 pt, 4.3 % at 2.5, 2.0 % at 4.5, 0.4 % at 7.5,
    /// none at 8.5. A Gaussian edge with σ ≈ 4 and peak 0.17 fits.
    public static let revealCardShadowOpacity: Float = 0.17
    public static let revealCardShadowRadius: CGFloat = 4

    /// Card frame for a window of `size` and sidebar width `width`.
    public static func revealCardFrame(windowSize size: CGSize, sidebarWidth width: CGFloat) -> CGRect {
        CGRect(x: revealCardInset, y: revealCardInset, width: width, height: max(0, size.height - 2 * revealCardInset))
    }
}

/// Hover reveal while the sidebar is hidden. Arc registers named zones with a hover
/// tracker (`WindowHoverTracker`, regions "InnerLeftEdge", "OuterLeftEdge",
/// "WindowTrafficLightRegion", "ArcSidebar", "ArcWindow"); a zone counts as hovered after
/// its dwell delay (registration at `0x100030670` in Arc 1.170.0). See docs/re/interaction-states.md §13.
public enum RevealMetrics {
    /// Dwell before a zone counts: 0.15 s (`0x3fc3333333333333` for the inner edge, the
    /// traffic-light region, the sidebar, and the window); 0.16 s for the outer edge.
    public static let dwell: Double = 0.15
    public static let outerEdgeDwell: Double = 0.16
    /// The card hides once the pointer has been out of every hold zone this long. guess: the
    /// same 0.15 s debounce as the sidebar zone.
    public static let exitDelay: Double = 0.15
    /// Arc scales its edge zones by one length read from the window view store (two doubles,
    /// top then left). guess: the 10 pt content inset.
    public static let zoneUnit: CGFloat = 10
    /// Inner left edge: x 0 … 0.6 u; once the pointer is in it (or outside the window), x −2 u … 1.5 u.
    public static var innerEdgeWidth: CGFloat { 0.6 * zoneUnit }
    public static var innerEdgeHeldRange: ClosedRange<CGFloat> { (-2 * zoneUnit)...(1.5 * zoneUnit) }
    /// Outer left edge (left of the window): 250 pt while the pointer is in the window or the
    /// zone, 50 pt when it comes from elsewhere (`0x1000301f8`).
    public static let outerEdgeHeld: CGFloat = 250
    public static let outerEdgeApproach: CGFloat = 50
    /// Top-left corner: 40 pt wide, 1.5 u above the top edge to 2 u below it (`0x10002ff7c`, `0x10002fed0`).
    public static let topLeftWidth: CGFloat = 40
    public static var topLeftRange: ClosedRange<CGFloat> { (-1.5 * zoneUnit)...(2 * zoneUnit) }
    /// Traffic-light region: the three buttons down to 50 pt below the window top (`0x100030390`).
    public static let trafficLightRegionHeight: CGFloat = 50
}

/// Arc-style tooltip: a capsule window (docs/re/interaction-states.md §5).
public enum TooltipMetrics {
    public static let height: CGFloat = 27
    public static let twoLineHeight: CGFloat = 42
    public static let horizontalPadding: CGFloat = 11
    public static let keycapHeight: CGFloat = 17
    public static let keycapMinWidth: CGFloat = 17
    public static let keycapRadius: CGFloat = 4
    public static let keycapGap: CGFloat = 3
    public static let labelToKeycaps: CGFloat = 7
    /// Gap between the anchor and the capsule. guess.
    public static let anchorGap: CGFloat = 6
    public static let shadowMargin: CGFloat = 33
    /// guess: hover delay before a tooltip shows.
    public static let showDelay: Double = 0.6
}

/// Space Manager Library columns. All values are guesses from completion §3.2.
public enum SpaceManagerMetrics {
    public static let inset: CGFloat = 16
    public static let gap: CGFloat = 12
    public static let columnWidth: CGFloat = 244
    public static let headerHeight: CGFloat = 44
    public static let pitch = columnWidth + gap
}

/// Hover preview geometry (completion §3.6; guesses pending capture C4).
public enum HoverPreviewMetrics {
    public static let pageWidth: CGFloat = 420
    public static let pageMaxHeight: CGFloat = 560
    public static let windowInset: CGFloat = 10
    public static let folderWidth: CGFloat = 300
    public static let rowHeight: CGFloat = 32
    public static let headerHeight: CGFloat = 36
    public static let sidebarGap: CGFloat = 8
    public static let radius: CGFloat = 10
    public static let shadowOpacity: Float = 0.25
    public static let shadowRadius: CGFloat = 12
    public static let shadowOffsetY: CGFloat = 4
}
/// Auto-archive education geometry (completion §3.11; guesses).
public enum BannerMetrics {
    public static let inset: CGFloat = 8
    public static let padding: CGFloat = 12
    public static let radius: CGFloat = 10
    public static let titleSize: CGFloat = 13
    public static let messageSize: CGFloat = 12
    public static let lineHeight: CGFloat = 15
    public static let buttonHeight: CGFloat = 24
}
