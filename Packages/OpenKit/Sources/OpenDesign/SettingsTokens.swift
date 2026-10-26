import AppKit

/// Settings measurements: review round 1, a-settings.png A0499–A0507 (0.70 px/pt,
/// ±1.5 pt), and ARC_PreferencesFeature Assets.car color facts. See docs/settings.md.
public enum SettingsTokens {
    // First-run plan §3.7. Open layout choices, pending the designer's review.
    public static let firstRunSize = CGSize(width:560,height:520)
    public static let firstRunWordmark = FontToken(28, .semibold)
    public static let firstRunStepTopInset:CGFloat = 36
    public static let firstRunSparseTextWidth:CGFloat = 400
    public static let firstRunHorizontalInset: CGFloat = 32
    public static let firstRunVerticalInset: CGFloat = 28
    public static let firstRunIconSize: CGFloat = 80
    public static let firstRunIdentityWidth: CGFloat = 380
    public static let firstRunButtonWidth: CGFloat = 240
    public static let contentInset: CGFloat = 64
    public static let bandHeight: CGFloat = 89
    public static let titleHeight: CGFloat = 28
    public static let firstBoxGap: CGFloat = 19
    public static let groupGap: CGFloat = 10
    public static let radius: CGFloat = 8
    public static let rowHeight: CGFloat = 36
    public static let controlRowHeight: CGFloat = 44
    public static let tileRowHeight: CGFloat = 40
    public static let label = FontToken(13, .regular)
    public static let section = FontToken(11, .regular)
    public static let tabLabel = FontToken(11, .regular)
    public static let sectionTitle = FontToken(11, .semibold)
    public static let secondary = DesignColor(light: RGBA(hex:0x666666), dark: RGBA(hex:0xB0B0B0))
    public static let segmentAccent = DesignColor(RGBA(hex:0x007AFF))
    public static let title = FontToken(13, .semibold)
    public static let emptyTitle = FontToken(18, .medium)
    public static let keycap = FontToken(12, .medium)
    public static let content = DesignColor(light: RGBA(hex: 0xF5F5F5), dark: RGBA(hex: 0x202020))
    public static let band = DesignColor(light: RGBA(hex: 0xECECEC), dark: RGBA(hex: 0x282828))
    public static let fill = DesignColor(light: .white(0.60), dark: .white(0.015))
    public static let border = DesignColor(light: .black(0.10), dark: .white(0.08))
    public static let divider = DesignColor(light: .black(0.06), dark: .white(0.05))
    public static let selectedTab = DesignColor(light: .black(0.06), dark: .white(0.10))
    public static let selectedProfile = DesignColor(light: RGBA(hex: 0x458AFF, alpha: 0.08), dark: RGBA(hex: 0x458AFF, alpha: 0.08))
    public static let button = DesignColor(light: .black(0.15), dark: RGBA(hex: 0xE0DFE0, alpha: 0.07))
    public static let link = DesignColor(RGBA(hex: 0x458AFF))
}
