import CoreGraphics

/// Provisional geometry. No Ctrl+Tab frame exists in capture sessions 1 or 2.
/// See docs/re/sidebar-completion.md §13 and capture request TS-C1.
public enum TabSwitcherTokens {
    public static let itemWidth: CGFloat = 180
    public static let itemHeight: CGFloat = 140
    public static let gap: CGFloat = 8
    public static let inset: CGFloat = 16
    public static let headingHeight: CGFloat = 28
    public static let corner: CGFloat = 16
    public static let maximumVisible = 5
    /// ArcMain 0x1024b69e8: one-shot presentation at request time + 0.1 s.
    public static let presentationDelay: Duration = .milliseconds(100)
    public static let background = Core.popoverBackground
    public static let foreground = Core.foregroundPrimary
    public static let secondary = Core.foregroundSecondary
    public static let selection = Core.baseQuaternary
}
