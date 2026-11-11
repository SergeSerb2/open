import AppKit

/// Settings measurements: review round 1, a-settings.png A0499–A0507 (0.70 px/pt,
/// ±1.5 pt), and ARC_PreferencesFeature Assets.car color facts. See docs/settings.md.
public enum SettingsTokens {
    /// Original Open Settings, Plan G. Legacy tokens below stay scoped to the
    /// existing sheets, first run and Library until their own design passes.
    public enum Redesign {
        public static let window = CGSize(width: 960, height: 660)
        public static let minimum = CGSize(width: 800, height: 540)
        public static let navigationWidth: CGFloat = 232
        public static let columnWidth: CGFloat = 620
        public static let topInset: CGFloat = 44
        public static let rowHeight: CGFloat = 44
        public static let helpRowHeight: CGFloat = 60
        public static let radius: CGFloat = 12
        public static let background = DesignColor(light: RGBA(hex: 0xFBFAF8), dark: RGBA(hex: 0x15151C))
        public static let card = DesignColor(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x1D1D27))
        public static let text = DesignColor(light: RGBA(hex: 0x1B1A26), dark: RGBA(hex: 0xF2F1F7))
        public static let secondary = DesignColor(light: RGBA(hex: 0x6C6B7B), dark: RGBA(hex: 0xA09FB0))
        // Original tertiary colors are used only for decoration. Small text
        // uses secondary, which meets AA on both content and control surfaces.
        public static let tertiary = DesignColor(light: RGBA(hex: 0x9B9AA8), dark: RGBA(hex: 0x6F6E80))
        public static let control = DesignColor(light: RGBA(hex: 0xF1F0F4), dark: RGBA(hex: 0x2A2A37))
        public static let hairline = DesignColor(light: RGBA(hex: 0x181630, alpha: 0.08), dark: .white(0.07))
        public static let controlLine = DesignColor(light: RGBA(hex: 0x181630, alpha: 0.10), dark: .white(0.08))
        public static let key = DesignColor(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x2C2C3A))
        public static let keyLine = DesignColor(light: RGBA(hex: 0x181630, alpha: 0.16), dark: .white(0.14))
        public static let accent = DesignColor(light: RGBA(hex: 0x5B5BD6), dark: RGBA(hex: 0x7B7BEA))
        public static let navigationBase = DesignColor(light: RGBA(hex: 0xFBFAF8), dark: RGBA(hex: 0x101019))
        public static let sunStart = RGBA(hex: 0xFFC56E)
        public static let sunEnd = RGBA(hex: 0xFF8F3A)
        public static let sunText = RGBA(hex: 0x3A1A00)
        public static let attentionText = DesignColor(light: RGBA(hex: 0x8D3D00), dark: RGBA(hex: 0xFFC56E))
        public static let hero = [RGBA(hex: 0x2F2F8C), RGBA(hex: 0x16163F), RGBA(hex: 0x0A0A1E)]
        public static let preview = [RGBA(hex: 0x3A3AA5), RGBA(hex: 0x1B1B52), RGBA(hex: 0x0B0B22)]
        public static let white = RGBA(hex: 0xFFFFFF)
        public static let shadow = RGBA.black(0.12)
        public static let title = FontToken(22, .semibold)
        public static let label = FontToken(13, .regular)
        public static let help = FontToken(11.5, .regular)
        public static let section = FontToken(11, .semibold)
        public static let navigation = FontToken(13, .medium)
        public static let group = FontToken(10.5, .semibold)
        public static let sectionDuration: TimeInterval = 0.12
        public static let searchDuration: TimeInterval = 0.16
        public static let arrivalDuration: TimeInterval = 0.6

        /// Preserve the Space hue and reduce saturation only when its lightness
        /// cannot provide 4.5:1 against every surface used behind accent text.
        @MainActor public static func accessibleAccent(_ source: NSColor?, dark: Bool) -> NSColor {
            let fallback = accent.resolved(dark ? .dark : .light).nsColor
            let source = source?.usingColorSpace(.sRGB) ?? fallback
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let surfaces = [background, card, control].map { $0.resolved(dark ? .dark : .light).nsColor }
            var candidate = NSColor(srgbRed: source.redComponent, green: source.greenComponent, blue: source.blueComponent, alpha: 1)
            for _ in 0..<100 {
                if surfaces.allSatisfy({ contrast(candidate, $0) >= 4.5 }) { return candidate }
                if dark { brightness = min(1, brightness + 0.015); saturation = max(0, saturation - 0.012) }
                else { brightness = max(0, brightness - 0.01) }
                candidate = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            }
            return dark ? .white : .black
        }
        @MainActor public static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
            func luminance(_ color: NSColor) -> Double {
                guard let color = color.usingColorSpace(.sRGB) else { return 0 }
                let values = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
                    let value = Double(value); return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
            }
            let a = luminance(lhs), b = luminance(rhs)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }
    // First-run plan §3.7. Open layout choices, pending the designer's review.
    public static let firstRunSize = CGSize(width:560,height:520)
    public static let firstRunWordmark = FontToken(28, .semibold)
    public static let firstRunStepTopInset:CGFloat = 36
    public static let firstRunSparseTextWidth:CGFloat = 400
    public static let firstRunStatusHeight:CGFloat = 36
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
