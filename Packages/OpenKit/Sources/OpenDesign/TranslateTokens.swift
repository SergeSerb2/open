import AppKit

// Page translation tokens (page-platform §4.7.3). The plan names `PageTokens.swift` for every page
// token; these live in their own file so the toast work (Step 1) and this work (Step 9) do not edit
// one new file at once. Values are guesses pending capture C-R1 unless marked.

/// The status button under the URL field: "Translation Available" (PG-7.3), later "Share Quote".
public enum URLStatusMetrics {
    /// `[8, 88, W − 16, 28]` in sidebar space: 6 pt under the URL field `[8, 46, W − 16, 36]`.
    public static let insetX: CGFloat = 8
    public static let y: CGFloat = 88
    public static let height: CGFloat = 28
    /// Content below the URL field moves down this much while the button shows (28 + 6).
    public static let pushDown: CGFloat = 34
    public static let cornerRadius: CGFloat = 8
    public static let symbolSize: CGFloat = 13
    public static let symbolToTitle: CGFloat = 6
    /// PG-7.3 (`FUN_10014bc74`): the short title at a button width of 200 pt or less.
    public static let compactWidth: CGFloat = 200
    public static let spinnerSize: CGFloat = 12
    public static func frame(sidebarWidth w: CGFloat) -> CGRect { CGRect(x: insetX, y: y, width: max(0, w - 2 * insetX), height: height) }
}

/// The translate popover (§4.7.3), drawn with the Site Control panel chrome (`PopoverShape`).
public enum TranslateMetrics {
    public static let width: CGFloat = 300
    public static let padding: CGFloat = 16
    public static let cornerRadius: CGFloat = 12
    public static let arrowHeight: CGFloat = 10
    /// The shadow and arrow need room around the body inside the panel window.
    public static let shadowMargin: CGFloat = 14
    public static let titleToButtons: CGFloat = 12
    public static let errorTopGap: CGFloat = 6
    public static let buttonHeight: CGFloat = 28
    public static let buttonRadius: CGFloat = 7
    public static let buttonGap: CGFloat = 8
    public static let buttonPaddingX: CGFloat = 14
    /// Gap between the status button's bottom and the arrow tip.
    public static let anchorGap: CGFloat = 2
}

public extension Typography {
    /// The status button title: 12 pt Medium (§4.7.3).
    static let statusButton = FontToken(12, .medium)
    /// Popover title: 13 pt Semibold; buttons 13 pt Medium; error line 12 pt (§4.7.3).
    static let translateTitle = FontToken(13, .semibold)
    static let translateButton = FontToken(13, .medium)
    static let translateError = FontToken(12, .regular)
}
